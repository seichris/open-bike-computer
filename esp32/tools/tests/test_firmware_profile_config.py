#!/usr/bin/env python3

import configparser
from pathlib import Path


project_dir = Path(__file__).resolve().parents[2]
repo_root = project_dir.parent
config = configparser.ConfigParser(interpolation=None)
config.read(project_dir / "platformio.ini")

waveshare_sdkconfig = config.get("waveshare_amoled_common", "custom_sdkconfig")
assert "CONFIG_PM_ENABLE=y" in waveshare_sdkconfig
assert "CONFIG_PM_DFS_INIT_AUTO=n" in waveshare_sdkconfig
assert "CONFIG_PM_PROFILING=n" in waveshare_sdkconfig
assert "CONFIG_FREERTOS_USE_TICKLESS_IDLE=n" in waveshare_sdkconfig
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
    base_flags = config.get(base, "build_flags")
    assert f"-D{board_define}" in base_flags
    flags = config.get(environment, "build_flags")
    assert f"${{{base}.build_flags}}" in flags
    assert "-DCORE_DEBUG_LEVEL=2" in flags
    assert "-DFIRMWARE_DIAGNOSTICS=1" in flags
    assert "-DARDUINO_USB_CDC_ON_BOOT=1" in flags

expected_targets = {
    "env:WAVESHARE_AMOLED_175_PRODUCTION": "WAVESHARE_AMOLED_175",
    "env:WAVESHARE_AMOLED_206_PRODUCTION": "WAVESHARE_AMOLED_206",
}

for environment, target in expected_targets.items():
    assert config.get(environment, "custom_firmware_target") == target
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
    unflags = config.get(environment, "build_unflags")
    assert "${waveshare_amoled_common.build_unflags}" in unflags
    assert "-DDEBUG=1" not in unflags

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
    assert config.get(environment, "custom_firmware_target") == target
    sdkconfig = config.get(environment, "custom_sdkconfig")
    assert "CONFIG_PM_ENABLE=y" in sdkconfig
    assert "CONFIG_FREERTOS_USE_TICKLESS_IDLE=y" in sdkconfig
    assert "CONFIG_FREERTOS_USE_TICKLESS_IDLE=n" not in sdkconfig
    assert "CONFIG_PM_LIGHT_SLEEP_CALLBACKS=y" in sdkconfig
    assert "CONFIG_GPIO_CTRL_FUNC_IN_IRAM=y" in sdkconfig
    flags = config.get(environment, "build_flags")
    assert f"${{{base}.build_flags}}" in flags
    assert "-DAUTOMATIC_LIGHT_SLEEP_EXPERIMENT=1" in flags

ci_workflow = (repo_root / ".github/workflows/ci.yml").read_text()
for environment in light_sleep_profiles:
    assert environment.removeprefix("env:") in ci_workflow

release_workflow = (repo_root / ".github/workflows/firmware-release.yml").read_text()
for environment, target in expected_targets.items():
    profile = environment.removeprefix("env:")
    mapping = f"target: {target}\n            environment: {profile}"
    assert mapping in release_workflow

print("firmware production profile contracts passed")
