#!/usr/bin/env python3

import configparser
import re
from pathlib import Path


project_dir = Path(__file__).resolve().parents[2]
repo_root = project_dir.parent
config = configparser.ConfigParser(interpolation=None)
config.read(project_dir / "platformio.ini")


def inherited_option(section: str, option: str) -> str:
    """Resolve the single-parent PlatformIO inheritance used by this file."""
    visited: set[str] = set()
    current = section
    while current:
        assert current not in visited, f"cyclic PlatformIO inheritance at {current}"
        visited.add(current)
        if config.has_option(current, option):
            return config.get(current, option)
        current = config.get(current, "extends", fallback="").strip()
    raise AssertionError(f"{section} does not resolve {option}")


prebuild_source = (project_dir / "prebuild.py").read_text()
main_source = (project_dir / "src/main.cpp").read_text()
assert "-DBUILD_PROFILE=" in prebuild_source
assert "OPEN_BIKE_EXPECTED_GIT_SHA" in prebuild_source
assert "SOURCE_DATE_EPOCH" in prebuild_source
assert "build_timestamp_from_source_date_epoch" in prebuild_source
assert 'git_sha = f"unverified-{detected_git_sha}"' in prebuild_source
assert "Waveshare firmware builds must use tools/build_firmware.py" in prebuild_source
assert 'env.subst("$PROJECT_LIBDEPS_DIR")' in prebuild_source
assert '".pio/libdeps/" + flavor' not in prebuild_source
assert "def record_link_start(target, source, env):" in prebuild_source
assert "def record_link_finish(target, source, env):" in prebuild_source
assert main_source.index("recoverInterruptedActivation()") < main_source.index(
    "ride_diagnostics::startWriter()"
)
assert main_source.index("std::fflush(stdout)") < main_source.index(
    'bleNavServer.init("BikeComputer")'
)
assert main_source.count("heap8=%lu/%lu dma=%lu/%lu") == 2

waveshare_sdkconfig = config.get("waveshare_amoled_common", "custom_sdkconfig")
assert "CONFIG_PM_ENABLE=y" in waveshare_sdkconfig
assert "CONFIG_PM_DFS_INIT_AUTO=n" in waveshare_sdkconfig
assert "CONFIG_PM_PROFILING=n" in waveshare_sdkconfig
assert "CONFIG_FREERTOS_USE_TICKLESS_IDLE=n" in waveshare_sdkconfig
assert "CONFIG_ARDUINO_LOOP_STACK_SIZE=16384" in waveshare_sdkconfig
assert "CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE=8192" in waveshare_sdkconfig
assert "CONFIG_SPIRAM_MALLOC_RESERVE_INTERNAL=32768" in waveshare_sdkconfig
assert "CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL" not in waveshare_sdkconfig
waveshare_unflags = config.get("waveshare_amoled_common", "build_unflags")
assert "-Wl,--wrap=log_printf" in waveshare_unflags
waveshare_flags = config.get("waveshare_amoled_common", "build_flags")
assert "-DDEBUG=1" not in waveshare_flags
assert "-DCORE_DEBUG_LEVEL=" not in waveshare_flags
assert "-DFIRMWARE_DIAGNOSTICS=" not in waveshare_flags
assert "-DARDUINO_USB_CDC_ON_BOOT=" not in waveshare_flags
assert "-DBLE_RADIO_CHARACTERIZATION=1" not in waveshare_flags
assert "-DBLE_TX_POWER_DBM=" not in waveshare_flags
assert "-DAUTOMATIC_LIGHT_SLEEP_EXPERIMENT=1" not in waveshare_flags
waveshare_dependencies = config.get("waveshare_amoled_common", "lib_deps")
assert waveshare_dependencies.count("https://github.com/jgauchia/NeoGPS.git") == 1
assert (
    "https://github.com/jgauchia/NeoGPS.git#"
    "43c47665f3f8a1b809d809d9f685b376edd40238"
) in waveshare_dependencies
assert "moononournation/GFX Library for Arduino @ 1.6.7" in waveshare_dependencies
assert "h2zero/NimBLE-Arduino@1.4.3" in waveshare_dependencies
assert "bblanchon/ArduinoJson@7.4.3" in waveshare_dependencies
assert "^" not in waveshare_dependencies

diagnostic_profiles = {
    "env:WAVESHARE_AMOLED_175": (
        "waveshare_amoled_175_base",
        "WAVESHARE_AMOLED_175",
    ),
    "env:WAVESHARE_AMOLED_206": (
        "waveshare_amoled_206_base",
        "WAVESHARE_AMOLED_206",
    ),
}
for environment, (base, board_define) in diagnostic_profiles.items():
    assert config.get(environment, "extends") == base
    assert inherited_option(environment, "custom_firmware_target") == board_define
    base_flags = config.get(base, "build_flags")
    assert f"-D{board_define}" in base_flags
    flags = config.get(environment, "build_flags")
    assert f"${{{base}.build_flags}}" in flags
    assert "-DCORE_DEBUG_LEVEL=2" in flags
    assert "-DFIRMWARE_DIAGNOSTICS=1" in flags
    assert "-DARDUINO_USB_CDC_ON_BOOT=1" in flags
    assert "-DRIDE_AUTOMATION_SHADOW=1" in flags
    assert "-DRIDE_AUTOMATION_INTERNAL_CONTROL=1" in flags
    assert "-DRIDE_AUTOMATION_AUTOMATIC_START=1" not in flags
    assert (
        inherited_option(environment, "board_build.partitions")
        == "partitions_remote_debug.csv"
    )

assert "-DWAVESHARE_206_FORCE_AXP_DISPLAY=1" in config.get(
    "waveshare_amoled_206_base", "build_flags"
)
assert "-DWAVESHARE_206_FORCE_AXP_DISPLAY" not in config.get(
    "waveshare_amoled_175_base", "build_flags"
)

expected_targets = {
    "env:WAVESHARE_AMOLED_175_PRODUCTION": "WAVESHARE_AMOLED_175",
    "env:WAVESHARE_AMOLED_206_PRODUCTION": "WAVESHARE_AMOLED_206",
}

for environment, target in expected_targets.items():
    assert inherited_option(environment, "custom_firmware_target") == target
    base = diagnostic_profiles[environment.replace("_PRODUCTION", "")][0]
    assert config.get(environment, "extends") == base
    flags = config.get(environment, "build_flags")
    assert f"${{{base}.build_flags}}" in flags
    assert "-DCORE_DEBUG_LEVEL=0" in flags
    assert "-DFIRMWARE_DIAGNOSTICS=0" in flags
    assert "-DARDUINO_USB_CDC_ON_BOOT=0" in flags
    assert "-DDEBUG=0" not in flags
    assert "-DCORE_DEBUG_LEVEL=2" not in flags
    assert "-DFIRMWARE_DIAGNOSTICS=1" not in flags
    assert "-DARDUINO_USB_CDC_ON_BOOT=1" not in flags
    assert "-DRIDE_AUTOMATION_SHADOW=1" not in flags
    assert "-DRIDE_AUTOMATION_INTERNAL_CONTROL=1" not in flags
    assert "-DRIDE_AUTOMATION_AUTOMATIC_START=1" not in flags
    unflags = config.get(environment, "build_unflags")
    assert "${waveshare_amoled_common.build_unflags}" in unflags
    assert "-DDEBUG=1" not in unflags
    assert "-DDEVICE_REMOTE_DEBUG=1" not in flags
    assert (
        inherited_option(environment, "board_build.partitions")
        == "partitions.csv"
    )

remote_debug_profiles = {
    "env:WAVESHARE_AMOLED_175_REMOTE_DEBUG": (
        "env:WAVESHARE_AMOLED_175",
        "WAVESHARE_AMOLED_175",
    ),
    "env:WAVESHARE_AMOLED_206_REMOTE_DEBUG": (
        "env:WAVESHARE_AMOLED_206",
        "WAVESHARE_AMOLED_206",
    ),
}
for environment, (base, target) in remote_debug_profiles.items():
    assert config.get(environment, "extends") == base
    assert inherited_option(environment, "custom_firmware_target") == target
    flags = config.get(environment, "build_flags")
    assert f"${{{base}.build_flags}}" in flags
    assert "-DDEVICE_REMOTE_DEBUG=1" in flags

large_diagnostic_profiles = (
    *remote_debug_profiles,
    "env:WAVESHARE_AMOLED_175_MAPIO_DIAGNOSTICS",
    "env:WAVESHARE_AMOLED_206_MAPIO_DIAGNOSTICS",
    "env:WAVESHARE_AMOLED_175_POWER_METRICS",
    "env:WAVESHARE_AMOLED_206_POWER_METRICS",
    "env:WAVESHARE_AMOLED_175_LIGHT_SLEEP",
    "env:WAVESHARE_AMOLED_206_LIGHT_SLEEP",
)
for environment in large_diagnostic_profiles:
    assert (
        inherited_option(environment, "board_build.partitions")
        == "partitions_remote_debug.csv"
    )

for partition_name in ("partitions.csv", "partitions_remote_debug.csv"):
    partition_rows = [
        [field.strip() for field in line.split(",")]
        for line in (project_dir / partition_name).read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    assert partition_rows[-2][0] == "ffat"
    assert partition_rows[-1][:5] == [
        "coredump",
        "data",
        "coredump",
        "",
        "0x0F0000",
    ]

light_sleep_profiles = {
    "env:WAVESHARE_AMOLED_175_LIGHT_SLEEP": (
        "env:WAVESHARE_AMOLED_175_POWER_METRICS",
        "WAVESHARE_AMOLED_175",
    ),
    "env:WAVESHARE_AMOLED_206_LIGHT_SLEEP": (
        "env:WAVESHARE_AMOLED_206_POWER_METRICS",
        "WAVESHARE_AMOLED_206",
    ),
}
for environment, (base, target) in light_sleep_profiles.items():
    assert config.get(environment, "extends") == base
    assert inherited_option(environment, "custom_firmware_target") == target
    sdkconfig = config.get(environment, "custom_sdkconfig")
    assert "CONFIG_PM_ENABLE=y" in sdkconfig
    assert "CONFIG_FREERTOS_USE_TICKLESS_IDLE=y" in sdkconfig
    assert "CONFIG_FREERTOS_USE_TICKLESS_IDLE=n" not in sdkconfig
    assert "CONFIG_PM_LIGHT_SLEEP_CALLBACKS=y" in sdkconfig
    assert "CONFIG_ARDUINO_LOOP_STACK_SIZE=16384" in sdkconfig
    assert "CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE=8192" in sdkconfig
    assert "CONFIG_SPIRAM_MALLOC_RESERVE_INTERNAL=32768" in sdkconfig
    assert "CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL" not in sdkconfig
    flags = config.get(environment, "build_flags")
    assert f"${{{base}.build_flags}}" in flags
    assert "-DAUTOMATIC_LIGHT_SLEEP_EXPERIMENT=1" in flags

assert "CONFIG_GPIO_CTRL_FUNC_IN_IRAM=y" not in config.get(
    "env:WAVESHARE_AMOLED_175_LIGHT_SLEEP", "custom_sdkconfig"
)
assert "CONFIG_GPIO_CTRL_FUNC_IN_IRAM=y" in config.get(
    "env:WAVESHARE_AMOLED_206_LIGHT_SLEEP", "custom_sdkconfig"
)

# Every board-named firmware profile reports the stable hardware/OTA target;
# BUILD_PROFILE remains the distinct PIO environment identity in boot logs.
for section in config.sections():
    profile = section.removeprefix("env:")
    if profile.startswith("WAVESHARE_AMOLED_175"):
        assert (
            inherited_option(section, "custom_firmware_target")
            == "WAVESHARE_AMOLED_175"
        )
    elif profile.startswith("WAVESHARE_AMOLED_206"):
        assert (
            inherited_option(section, "custom_firmware_target")
            == "WAVESHARE_AMOLED_206"
        )

ci_workflow = (repo_root / ".github/workflows/ci.yml").read_text()
firmware_routing = (
    repo_root / ".github/scripts/changed_components.py"
).read_text()
diagnostic_workflow = (
    repo_root / ".github/workflows/firmware-diagnostics.yml"
).read_text()
speaker_workflow = (
    repo_root / ".github/workflows/speaker-firmware.yml"
).read_text()
runtime_refresh_workflow = (
    repo_root / ".github/workflows/firmware-runtime-refresh.yml"
).read_text()
assert "env -u LD_LIBRARY_PATH python3 tools/build_firmware.py" in ci_workflow
assert "env -u LD_LIBRARY_PATH python3 tools/build_firmware.py" in diagnostic_workflow
assert "workflow_dispatch:" in diagnostic_workflow
assert "workflow_call:" in diagnostic_workflow
assert "schedule:" in diagnostic_workflow
assert "pull_request:" not in diagnostic_workflow
assert '      - "v*"' not in diagnostic_workflow
assert "branches:" not in diagnostic_workflow
assert "workflow_dispatch:" in speaker_workflow
assert "push:" not in speaker_workflow
assert "pull_request:" not in speaker_workflow
assert "env -u LD_LIBRARY_PATH python3 tools/build_firmware.py" in speaker_workflow
assert '.pio/open-bike-build/builds/$environment/current.json' in runtime_refresh_workflow
assert ".pio/open-bike-build/sdkconfig-defaults.json" not in runtime_refresh_workflow
for environment in light_sleep_profiles:
    profile = environment.removeprefix("env:")
    assert profile not in ci_workflow
    assert profile in diagnostic_workflow
for environment in remote_debug_profiles:
    profile = environment.removeprefix("env:")
    assert profile in firmware_routing
    assert profile in diagnostic_workflow

battery_validation = (
    repo_root / "docs/firmware-battery-life-hardware-validation.md"
).read_text()
assert "pio run -e WAVESHARE_AMOLED" not in battery_validation
assert "PLATFORMIO_BUILD_FLAGS=" not in battery_validation
assert "tools/build_firmware.py" in battery_validation

display_probe_profile = "env:WAVESHARE_AMOLED_206_DISPLAY_TEST"
assert config.get(display_probe_profile, "extends") == "env:WAVESHARE_AMOLED_206"
display_probe_flags = config.get(display_probe_profile, "build_flags")
assert "-DWAVESHARE_DISPLAY_PROBE=1" in display_probe_flags
display_probe = display_probe_profile.removeprefix("env:")
assert display_probe not in ci_workflow
assert display_probe in diagnostic_workflow

speaker_source = (project_dir / "speaker_honk_test.cpp").read_text()
speaker_implementation = (project_dir / "lib/speaker/speaker.cpp").read_text()
codec_data_i2s = (
    project_dir
    / "lib/esp_codec_dev/src/platform/audio_codec_data_i2s.c"
).read_text()
assert "SPEAKER_CYCLE schema=1" in speaker_source
assert "100 tracked playback cycles complete" in speaker_source
assert "gpio_get_level(GPIO_NUM_46)" in speaker_source
assert "heap_caps_get_free_size(MALLOC_CAP_DEFAULT)" in speaker_source
assert "heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT)" in speaker_source
for board in ("175", "206"):
    profile = f"env:WAVESHARE_AMOLED_{board}_SPEAKER_HONK"
    assert config.get(profile, "extends") == f"env:WAVESHARE_AMOLED_{board}"
    assert "+<../speaker_honk_test.cpp>" in config.get(profile, "build_src_filter")
    assert profile.removeprefix("env:") not in ci_workflow
    assert profile.removeprefix("env:") in speaker_workflow
assert speaker_source.index("boot_diagnostics::begin()") < speaker_source.index(
    "waveshare_board::i2c::configureBus()"
)
assert speaker_source.index(
    "waveshare_board::i2c::configureBus()"
) < speaker_source.index("waveshare_board::initializePowerManagement()")
assert "boot_diagnostics::safeModeActive()" in speaker_source
assert "boot_diagnostics::markReady()" in speaker_source
assert "waveshare_board::speaker::requestPlayTracked" in speaker_source
assert "waveshare_board::speaker::latestPlaybackCompletion" in speaker_source
assert "TrackedPlaybackResult::Succeeded" in speaker_source
assert "TrackedPlaybackResult::Failed" in speaker_source
assert "playbackSucceeded = playNow(sound)" in speaker_implementation
cleanup_call = speaker_implementation.index(
    "cleanupSucceeded = releaseCodecResources();"
)
completion_publish = speaker_implementation.index(
    "recordPlaybackCompletion(\n        request.requestId"
)
assert cleanup_call < completion_publish
assert "retrying retained cleanup state once" in speaker_implementation
assert "codecInterface->close" not in speaker_implementation
assert "dataInterface->close" not in speaker_implementation
assert "i2s_channel_enable(txChannel)" not in speaker_implementation
assert "_i2s_disable_for_reconfiguration" in codec_data_i2s
assert "if (*enabled == false)" in codec_data_i2s
assert codec_data_i2s.index("if (*enabled == false)") < codec_data_i2s.index(
    "_i2s_drv_enable(i2s_data, playback, false)"
)
format_setup = codec_data_i2s[
    codec_data_i2s.index("static int _i2s_data_set_fmt("):
    codec_data_i2s.index("static int _i2s_data_read(")
]
assert "_i2s_disable_for_reconfiguration(i2s_data, true)" in format_setup
assert "_i2s_disable_for_reconfiguration(i2s_data, false)" in format_setup
assert "_i2s_drv_enable(i2s_data, true, false);" not in format_setup
assert "_i2s_drv_enable(i2s_data, false, false);" not in format_setup
codec_open = speaker_implementation.index("esp_codec_dev_open(speakerDevice")
channel_enabled = speaker_implementation.index(
    "resourceState.channelEnabled = true;", codec_open
)
assert codec_open < channel_enabled
failed_init = speaker_implementation[
    speaker_implementation.index("bool failInitialization("):
    speaker_implementation.index("bool initializeCodec()")
]
assert "releaseCodecResources()" not in failed_init
assert "!codecReady || uxQueueMessagesWaiting(soundQueue) == 0" in (
    speaker_implementation
)
assert "cleanupSucceeded = releaseCodecResources();" in speaker_implementation
assert "(void)releaseCodecResources();" in speaker_implementation
assert "playbackRequestLifecycleSucceeded(" in speaker_implementation[
    completion_publish:
]
startup_ready_guard = speaker_source.index("if (startupSoundsCompleted ==")
assert startup_ready_guard < speaker_source.index("boot_diagnostics::markReady()")
assert startup_ready_guard < speaker_source.index(
    "boot_diagnostics::completeStage(boot_diagnostics::Stage::Speaker)"
)
assert "startupSoundsCompleted" in speaker_source
assert "if (!testInitialized)" in speaker_source

boot_policy_source = (
    project_dir / "lib/boot_diagnostics/boot_diagnostics_policy.hpp"
).read_text()
assert "kStructuredSerialTxBufferSize = 4096" in boot_policy_source
main_source = (project_dir / "src/main.cpp").read_text()
for source in (main_source, speaker_source):
    assert "Serial.setTxBufferSize(" in source
    assert "boot_diagnostics::kStructuredSerialTxBufferSize" in source

# Keep every raw I2C write transaction behind i2c_bus.cpp, where the AXP2101
# allowlist is enforced. Direct requestFrom() reads remain permitted.
i2c_boundary = (project_dir / "lib/waveshare_board/i2c_bus.cpp").resolve()
raw_write_pattern = re.compile(r"\bWire\s*\.\s*beginTransmission\s*\(")
raw_write_offenders: list[str] = []
source_paths = set(project_dir.glob("*.cpp")) | set(project_dir.glob("*.ino"))
for source_root in (project_dir / "src", project_dir / "lib"):
    for suffix in ("*.cpp", "*.hpp", "*.h", "*.ino"):
        source_paths.update(source_root.rglob(suffix))
for source_path in sorted(source_paths):
    if source_path.resolve() == i2c_boundary:
        continue
    if raw_write_pattern.search(source_path.read_text(errors="ignore")):
        raw_write_offenders.append(str(source_path.relative_to(project_dir)))
assert not raw_write_offenders, (
    "raw Wire.beginTransmission() bypasses the AXP2101 policy boundary: "
    + ", ".join(raw_write_offenders)
)

release_candidate_workflow = (
    repo_root / ".github/workflows/firmware-release-candidate.yml"
).read_text()
assert (
    "env -u LD_LIBRARY_PATH python3 tools/build_firmware.py"
    in release_candidate_workflow
)
for environment in remote_debug_profiles:
    assert environment.removeprefix("env:") not in release_candidate_workflow
for environment, target in expected_targets.items():
    profile = environment.removeprefix("env:")
    mapping = f"target: {target}\n            environment: {profile}"
    assert mapping in release_candidate_workflow

print("firmware production profile contracts passed")
