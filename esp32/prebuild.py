# CanAirIO Project
# Author: @hpsaturn
# pre-build script, setting up build environment

import json
import os.path
from platformio import util
import shutil
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from SCons.Script import DefaultEnvironment

env = DefaultEnvironment()
TOOLS_DIR = Path(env.get("PROJECT_DIR")).resolve() / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from firmware_build_identity import (
    build_timestamp_from_source_date_epoch,
    firmware_git_identity,
)
from generated_sdkconfig import recognized_generated_sdkconfigs
from pioarduino_custom_core import (
    correct_espidf_text,
    correct_penv_setup_text,
    correct_sections_text,
    pioarduino_transform_source_sha256,
    verified_transform_marker_matches,
)


def ensure_custom_core_generated_source_alias():
    """Work around pioarduino custom-core generated-source path nesting.

    The pinned platform passes some CMake-generated assembly sources back to
    SCons as project-relative paths. SCons then resolves those paths relative
    to the environment build directory a second time. A build-local alias
    makes the doubled path resolve to the actual generated source without
    patching the installed PlatformIO package.
    """
    custom_sdkconfig = env.GetProjectOption("custom_sdkconfig", "").strip()
    if not custom_sdkconfig:
        return

    project_pio_dir = Path(env.get("PROJECT_DIR")).resolve() / ".pio"
    environment_build_dir = Path(env.subst("$BUILD_DIR")).resolve()
    generated_source_alias = environment_build_dir / ".pio"
    environment_build_dir.mkdir(parents=True, exist_ok=True)

    if generated_source_alias.is_symlink():
        if generated_source_alias.resolve() != project_pio_dir:
            generated_source_alias.unlink()
    elif generated_source_alias.exists():
        raise RuntimeError(
            "custom-core generated-source alias collides with an existing path: "
            f"{generated_source_alias}"
        )

    if not generated_source_alias.exists():
        generated_source_alias.symlink_to(project_pio_dir, target_is_directory=True)

    # These sources belong to optional Arduino registry components that are not
    # linked by this firmware. CMake owns their final contents, but pioarduino
    # asks SCons to resolve the source nodes before CMake's generators run. The
    # placeholders keep graph construction deterministic; CMake may replace
    # them with the real embedded-certificate assembly later in the build.
    for generated_name in (
        "https_server.crt.S",
        "rmaker_mqtt_server.crt.S",
        "rmaker_claim_service_server.crt.S",
        "rmaker_ota_server.crt.S",
    ):
        generated_source = environment_build_dir / generated_name
        if not generated_source.exists():
            generated_source.write_text(
                "/* pioarduino custom-core generated-source placeholder */\n",
                encoding="utf-8",
            )

    # pioarduino copies custom-compiled archives and memory.ld back into its
    # framework package, but it does not copy the matching sections.ld. With
    # CONFIG_PM_ENABLE the generated script adds the esp_pm_configure literal;
    # without it, sufficiently large variants can fail with an Xtensa
    # "literal placed after use" relocation. Keep the installed package
    # immutable and put a corrected script in the environment build directory,
    # which is first on the linker's script search path.
    framework_libs_package = env.PioPlatform().get_package_dir(
        "framework-arduinoespressif32-libs"
    )
    if not framework_libs_package:
        raise RuntimeError("pioarduino framework-libs package is unavailable")
    framework_libs_dir = Path(framework_libs_package)
    board = env.BoardConfig()
    mcu = board.get("build.mcu", "esp32")
    memory_type = board.get(
        "build.arduino.memory_type",
        f"{board.get('build.flash_mode', 'dio')}_qspi",
    )
    installed_sections = framework_libs_dir / mcu / memory_type / "sections.ld"
    if not installed_sections.is_file():
        raise RuntimeError(
            "pioarduino custom-core linker script is missing: "
            f"{installed_sections}"
        )

    sections_text = installed_sections.read_text(encoding="utf-8")
    try:
        sections_text = correct_sections_text(sections_text)
    except ValueError as error:
        raise RuntimeError(str(error)) from error

    (environment_build_dir / "sections.ld").write_text(
        sections_text,
        encoding="utf-8",
    )


ensure_custom_core_generated_source_alias()


def ensure_verified_nested_build_config():
    """Keep pioarduino's recursive custom-core build on verified local inputs."""
    if os.environ.get("OPEN_BIKE_DETERMINISTIC_BUILD") != "1":
        return
    verified_config = os.environ.get("OPEN_BIKE_VERIFIED_PROJECT_CONFIG")
    if not verified_config:
        raise RuntimeError("verified nested PlatformIO config is missing")
    config_path = Path(verified_config)
    if config_path.is_symlink() or not config_path.is_file():
        raise RuntimeError(
            f"verified nested PlatformIO config is unsafe: {config_path}"
        )

    platform_dir = Path(env.PioPlatform().get_dir())
    marker_path = platform_dir / ".open-bike-runtime-transform.json"
    if marker_path.is_symlink() or not marker_path.is_file():
        raise RuntimeError("pre-execution pioarduino transform marker is missing")
    try:
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
        runtime_provenance = json.loads(
            os.environ["OPEN_BIKE_FIRMWARE_RUNTIME_PROVENANCE"]
        )
        transform_sha256 = pioarduino_transform_source_sha256()
    except (
        KeyError,
        OSError,
        UnicodeError,
        ValueError,
        json.JSONDecodeError,
    ) as error:
        raise RuntimeError("pre-execution pioarduino transform marker is invalid") from error
    if not verified_transform_marker_matches(
        marker,
        os.environ.get("OPEN_BIKE_PLATFORM_ARCHIVE_SHA256", ""),
        runtime_provenance,
        transform_sha256,
    ):
        raise RuntimeError("pre-execution pioarduino transform identity changed")
    patches = (
        (
            platform_dir / "builder/frameworks/espidf.py",
            correct_espidf_text,
            "nested-build and ESP-IDF resolver",
        ),
        (
            platform_dir / "builder/penv_setup.py",
            correct_penv_setup_text,
            "Python resolver",
        ),
    )
    for installed_path, transform, label in patches:
        if installed_path.is_symlink() or not installed_path.is_file():
            raise RuntimeError(
                f"pioarduino {label} script is unsafe: {installed_path}"
            )
        source = installed_path.read_text(encoding="utf-8")
        try:
            corrected = transform(source)
        except ValueError as error:
            raise RuntimeError(str(error)) from error
        if corrected != source:
            raise RuntimeError(
                f"pioarduino {label} script was not transformed before execution"
            )


ensure_verified_nested_build_config()

try:
    import configparser
except ImportError:
    import ConfigParser as configparser

# get platformio environment variables
config = configparser.ConfigParser()
config.read("platformio.ini")

# get platformio source path
srcdir = env.get("PROJECTSRC_DIR")
flavor = env.get("PIOENV")
firmware_target = env.GetProjectOption("custom_firmware_target", flavor)
revision = config.get("common","revision")
version = config.get("common", "version")
project_dir = Path(env.get("PROJECT_DIR")).resolve()
allowed_generated_paths = ()
deterministic_build = os.environ.get("OPEN_BIKE_DETERMINISTIC_BUILD") == "1"
if firmware_target.startswith("WAVESHARE_AMOLED_") and not deterministic_build:
    raise RuntimeError(
        "Waveshare firmware builds must use tools/build_firmware.py so generated "
        "inputs and the flashed source identity are verified"
    )
if deterministic_build:
    source_date_epoch = os.environ.get("SOURCE_DATE_EPOCH", "")
    try:
        build_timestamp = build_timestamp_from_source_date_epoch(
            source_date_epoch
        )
    except ValueError as error:
        raise RuntimeError(
            f"invalid deterministic firmware build clock: {error}"
        ) from error
    expected_build_timestamp = os.environ.get("OPEN_BIKE_BUILD_TIMESTAMP")
    if expected_build_timestamp != build_timestamp:
        raise RuntimeError(
            "deterministic firmware build timestamp changed before prebuild: "
            f"expected {expected_build_timestamp or 'missing'}, got {build_timestamp}"
        )
else:
    build_timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
if deterministic_build:
    allowed_generated_paths = recognized_generated_sdkconfigs(project_dir, flavor)
detected_git_sha = firmware_git_identity(
    project_dir.parent,
    allowed_untracked_paths=allowed_generated_paths,
)
if deterministic_build:
    expected_git_sha = os.environ.get("OPEN_BIKE_EXPECTED_GIT_SHA")
    if not expected_git_sha or detected_git_sha != expected_git_sha:
        raise RuntimeError(
            "deterministic firmware source identity changed before prebuild: "
            f"expected {expected_git_sha or 'missing'}, got {detected_git_sha}"
        )
    git_sha = detected_git_sha
else:
    # Raw PlatformIO invocations can inherit source/build overrides that are
    # outside the tracked repository. Never let those images claim an exact
    # clean Git SHA in BOOT_META.
    git_sha = f"unverified-{detected_git_sha}"


link_started_ns = None


def record_link_start(target, source, env):
    """Start the separately observable final-link phase."""
    del target, source, env
    global link_started_ns
    link_started_ns = time.monotonic_ns()


def record_link_finish(target, source, env):
    """Atomically publish the link duration for the verified wrapper."""
    del target, source, env
    if link_started_ns is None:
        raise RuntimeError("firmware link timing started from an invalid state")
    elapsed_ms = max(0, round((time.monotonic_ns() - link_started_ns) / 1_000_000))
    output = (
        project_dir
        / ".pio/open-bike-build/phase-timings"
        / f"{flavor}-link.json"
    )
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if output.parent.is_symlink() or not output.parent.is_dir():
        raise RuntimeError("firmware link timing directory is unsafe")
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=output.parent,
            prefix=f".{output.name}.",
            delete=False,
        ) as stream:
            temporary_name = stream.name
            json.dump(
                {"schema": 1, "environment": flavor, "linkMs": elapsed_ms},
                stream,
                sort_keys=True,
                separators=(",", ":"),
            )
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, output)
        temporary_name = None
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except OSError:
                pass


if deterministic_build and firmware_target.startswith("WAVESHARE_AMOLED_"):
    link_target = "$BUILD_DIR/${PROGNAME}.elf"
    # SCons caches the ELF but not the linker's firmware.map side output.
    # Always link this target so TLS verification and link timing describe
    # this build; object files and libraries remain cacheable.
    env.NoCache(link_target)
    env.AddPreAction(link_target, record_link_start)
    env.AddPostAction(link_target, record_link_finish)

dfl_lat = os.environ.get('ICENAV3_LAT')
dfl_lon = os.environ.get('ICENAV3_LON')

# print ("environment:")
# print (env.Dump())

# get runtime credentials and put them to compiler directive
env.Append(BUILD_FLAGS=[
    u'-DREVISION=' + revision + '',
    u'-DVERSION=\\"' + version + '\\"',
    u'-DFLAVOR=\\"' + firmware_target + '\\"',
    u'-DBUILD_PROFILE=\\"' + flavor + '\\"',
    u'-DGIT_SHA=\\"' + git_sha + '\\"',
    u'-DBUILD_TIMESTAMP=\\"' + build_timestamp + '\\"',
    u'-D'+ flavor + '=1'
    ])

if dfl_lat != None and dfl_lon != None:
    print ("default lat: "+dfl_lat)
    print ("default lon: "+dfl_lon)
    env.Append(BUILD_FLAGS=[
        u'-DDEFAULT_LAT=' + dfl_lat + '',
        u'-DDEFAULT_LON=' + dfl_lon + ''
        ])

# NeoGPS configuration must follow PlatformIO's effective dependency store.
# The verified Waveshare helper isolates that store per profile; a hard-coded
# .pio/libdeps path would edit a different tree and silently compile NeoGPS with
# its packaged defaults.
neogps_source_dir = (
    Path(env.subst("$PROJECT_LIBDEPS_DIR")).resolve() / flavor / "NeoGPS" / "src"
)
neogps_source_dir.mkdir(mode=0o755, parents=True, exist_ok=True)
for config_name in ("GPSfix_cfg.h", "NeoGPS_cfg.h", "NMEAGPS_cfg.h"):
    shutil.copy(
        project_dir / "lib" / "gps" / config_name,
        neogps_source_dir / config_name,
    )
