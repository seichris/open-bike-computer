from __future__ import annotations

import os
import re
from typing import Any


MAX_PREFERRED_LANGUAGES = 3
MAX_LANGUAGE_TAG_BYTES = 35
LABEL_PROFILE_VERSION = 1
LEGACY_RENDERER_FORMAT_VERSION = 1
LABEL_RENDERER_FORMAT_VERSION = 2

_LANGUAGE_TAG_RE = re.compile(r"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8}){0,3}$")


def label_target2_generation_enabled() -> bool:
    value = os.environ.get(
        "MAP_PLATFORM_LABEL_TARGET2_ENABLED",
        "0",
    ).strip().lower()
    if value in {"1", "true", "yes"}:
        return True
    if value in {"0", "false", "no"}:
        return False
    raise ValueError("MAP_PLATFORM_LABEL_TARGET2_ENABLED must be a boolean")


def normalize_language_tag(value: Any) -> str:
    if not isinstance(value, str):
        raise ValueError("label language must be a string")
    raw = value.strip().replace("_", "-")
    try:
        encoded = raw.encode("ascii")
    except UnicodeEncodeError as exc:
        raise ValueError("label language is not a supported BCP-47 tag") from exc
    if (
        not raw
        or len(encoded) > MAX_LANGUAGE_TAG_BYTES
        or _LANGUAGE_TAG_RE.fullmatch(raw) is None
    ):
        raise ValueError("label language is not a supported BCP-47 tag")
    parts = raw.split("-")
    normalized = [parts[0].lower()]
    for part in parts[1:]:
        if len(part) == 4 and part.isalpha():
            normalized.append(part.title())
        elif len(part) == 2 and part.isalpha():
            normalized.append(part.upper())
        else:
            normalized.append(part.lower())
    return "-".join(normalized)


def renderer_format_version(request: dict[str, Any]) -> int:
    target = request.get("target")
    if not isinstance(target, dict):
        return LEGACY_RENDERER_FORMAT_VERSION
    value = target.get("rendererFormatVersion", LEGACY_RENDERER_FORMAT_VERSION)
    return value if isinstance(value, int) and not isinstance(value, bool) else -1
