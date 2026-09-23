"""Fail-closed renderer-4 rollout controls.

Source qualification and client compatibility remain independent gates. This
allowlist only permits a development installation to request an otherwise
configured canary profile; it never enables production or approves a source.
"""
from __future__ import annotations

import os
import re

INSTALLATION_ID = re.compile(r"[A-Za-z0-9._:-]{1,128}")


def topography_target4_generation_allowlist() -> frozenset[str]:
    raw = os.environ.get("MAP_PLATFORM_TOPOGRAPHY_TARGET4_ALLOWLIST", "")
    values = [value.strip() for value in raw.split(",") if value.strip()]
    if len(values) != len(set(values)):
        raise ValueError("topography target 4 allowlist contains duplicates")
    if any(INSTALLATION_ID.fullmatch(value) is None for value in values):
        raise ValueError("topography target 4 allowlist contains an invalid installation ID")
    return frozenset(values)
