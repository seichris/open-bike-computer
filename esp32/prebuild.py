# CanAirIO Project
# Author: @hpsaturn
# pre-build script, setting up build environment

import os.path
from platformio import util
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from SCons.Script import DefaultEnvironment

env = DefaultEnvironment()
TOOLS_DIR = Path(env.get("PROJECT_DIR")).resolve() / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from firmware_build_identity import firmware_git_identity
from pioarduino_custom_core import correct_sections_text


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
build_timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
git_sha = firmware_git_identity(Path(env.get("PROJECT_DIR")).resolve().parent)

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

# NeoGps Config files
config_path = "lib/gps/GPSfix_cfg.h"
output_path =  ".pio/libdeps/" + flavor + "/NeoGPS/src" 
target_path = output_path + "/GPSfix_cfg.h"
os.makedirs(output_path, 0o755, True)
shutil.copy(config_path , target_path)

config_path = "lib/gps/NeoGPS_cfg.h"
output_path =  ".pio/libdeps/" + flavor + "/NeoGPS/src" 
target_path = output_path + "/NeoGPS_cfg.h"
os.makedirs(output_path, 0o755, True)
shutil.copy(config_path , target_path)

config_path = "lib/gps/NMEAGPS_cfg.h"
output_path =  ".pio/libdeps/" + flavor + "/NeoGPS/src" 
target_path = output_path + "/NMEAGPS_cfg.h"
os.makedirs(output_path, 0o755, True)
shutil.copy(config_path , target_path)
