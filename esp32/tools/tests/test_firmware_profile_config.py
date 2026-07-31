#!/usr/bin/env python3

import configparser
from pathlib import Path


project_dir = Path(__file__).resolve().parents[2]
repo_root = project_dir.parent
config = configparser.ConfigParser(interpolation=None)
config.read(project_dir / "platformio.ini")

expected_targets = {
    "env:WAVESHARE_AMOLED_175_PRODUCTION": "WAVESHARE_AMOLED_175",
    "env:WAVESHARE_AMOLED_206_PRODUCTION": "WAVESHARE_AMOLED_206",
}

for environment, target in expected_targets.items():
    assert config.get(environment, "custom_firmware_target") == target
    flags = config.get(environment, "build_flags")
    unflags = config.get(environment, "build_unflags")
    assert "-DCORE_DEBUG_LEVEL=0" in flags
    assert "-DFIRMWARE_DIAGNOSTICS=0" in flags
    assert "-DARDUINO_USB_CDC_ON_BOOT=0" in flags
    assert "-DDEBUG=0" not in flags
    assert "-DDEBUG=1" in unflags

release_workflow = (repo_root / ".github/workflows/firmware-release.yml").read_text()
for environment, target in expected_targets.items():
    profile = environment.removeprefix("env:")
    mapping = f"target: {target}\n            environment: {profile}"
    assert mapping in release_workflow

print("firmware production profile contracts passed")
