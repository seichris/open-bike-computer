from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
from typing import Any

from .strict_json import loads_strict_json


DEPLOYMENT_CHANNELS = frozenset({"development", "production"})
PROFILE_ID_PATTERN = re.compile(r"[a-z][a-z0-9-]{2,63}")


@dataclass(frozen=True)
class GenerationProfile:
    profile_id: str
    renderer_format_version: int
    features: tuple[str, ...]

    def public_dict(self) -> dict[str, Any]:
        return {
            "id": self.profile_id,
            "rendererFormatVersion": self.renderer_format_version,
            "features": list(self.features),
        }


@dataclass(frozen=True)
class ChannelPolicy:
    global_profile_ids: tuple[str, ...]
    canary_profile_ids: tuple[str, ...]


@dataclass(frozen=True)
class GenerationProfilePolicy:
    profiles_by_id: dict[str, GenerationProfile]
    channels: dict[str, ChannelPolicy]
    sha256: str

    @classmethod
    def load(cls, path: Path) -> GenerationProfilePolicy:
        try:
            raw = path.read_bytes()
        except OSError as exc:
            raise ValueError("generation profile policy is invalid") from exc
        payload = loads_strict_json(raw, description="generation profile policy")
        if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
            raise ValueError("generation profile policy schemaVersion must be 1")
        if set(payload) != {"schemaVersion", "profiles", "channels"}:
            raise ValueError("generation profile policy fields are invalid")

        raw_profiles = payload.get("profiles")
        if not isinstance(raw_profiles, list) or not raw_profiles:
            raise ValueError("generation profile policy requires profiles")
        profiles: dict[str, GenerationProfile] = {}
        formats: set[int] = set()
        for value in raw_profiles:
            if not isinstance(value, dict) or set(value) != {
                "id",
                "rendererFormatVersion",
                "features",
            }:
                raise ValueError("generation profile entry is invalid")
            profile_id = value.get("id")
            renderer_format = value.get("rendererFormatVersion")
            features = value.get("features")
            if (
                not isinstance(profile_id, str)
                or PROFILE_ID_PATTERN.fullmatch(profile_id) is None
                or isinstance(renderer_format, bool)
                or not isinstance(renderer_format, int)
                or renderer_format <= 0
                or not isinstance(features, list)
                or any(not isinstance(feature, str) or not feature for feature in features)
                or len(features) != len(set(features))
                or profile_id in profiles
                or renderer_format in formats
            ):
                raise ValueError("generation profile entry is invalid")
            profiles[profile_id] = GenerationProfile(
                profile_id,
                renderer_format,
                tuple(features),
            )
            formats.add(renderer_format)
        if formats != {1, 2, 3}:
            raise ValueError(
                "generation profile policy schemaVersion 1 requires renderer formats 1, 2, and 3"
            )

        raw_channels = payload.get("channels")
        if not isinstance(raw_channels, dict) or set(raw_channels) != DEPLOYMENT_CHANNELS:
            raise ValueError("generation profile policy must define development and production")
        channels: dict[str, ChannelPolicy] = {}
        for channel_name, value in raw_channels.items():
            if not isinstance(value, dict) or set(value) != {
                "globalProfiles",
                "canaryProfiles",
            }:
                raise ValueError(f"generation profile channel {channel_name} is invalid")
            global_ids = value["globalProfiles"]
            canary_ids = value["canaryProfiles"]
            if (
                not isinstance(global_ids, list)
                or not isinstance(canary_ids, list)
                or any(not isinstance(item, str) for item in global_ids + canary_ids)
                or len(global_ids) != len(set(global_ids))
                or len(canary_ids) != len(set(canary_ids))
                or set(global_ids) & set(canary_ids)
                or set(global_ids + canary_ids) != set(profiles)
            ):
                raise ValueError(f"generation profile channel {channel_name} is invalid")
            legacy_profiles = [
                profile
                for profile in profiles.values()
                if profile.renderer_format_version == 1
            ]
            if len(legacy_profiles) != 1:
                raise ValueError("generation profile policy requires renderer format 1")
            legacy_profile = legacy_profiles[0]
            if legacy_profile.profile_id not in global_ids:
                raise ValueError(f"generation profile channel {channel_name} must enable format 1")
            channels[channel_name] = ChannelPolicy(tuple(global_ids), tuple(canary_ids))

        return cls(profiles, channels, hashlib.sha256(raw).hexdigest())

    def available_profiles(
        self,
        channel: str,
        *,
        canary_profile_ids: frozenset[str] = frozenset(),
    ) -> tuple[GenerationProfile, ...]:
        try:
            policy = self.channels[channel]
        except KeyError as exc:
            raise ValueError(f"unsupported deployment channel: {channel}") from exc
        enabled_ids = set(policy.global_profile_ids)
        enabled_ids.update(set(policy.canary_profile_ids) & canary_profile_ids)
        return tuple(
            sorted(
                (self.profiles_by_id[profile_id] for profile_id in enabled_ids),
                key=lambda profile: profile.renderer_format_version,
                reverse=True,
            )
        )

    def profile_id_for_renderer_format(self, renderer_format_version: int) -> str:
        for profile in self.profiles_by_id.values():
            if profile.renderer_format_version == renderer_format_version:
                return profile.profile_id
        raise ValueError(
            f"generation profile policy does not define renderer format "
            f"{renderer_format_version}"
        )


def configured_deployment_channel() -> str:
    value = os.environ.get("MAP_PLATFORM_DEPLOYMENT_CHANNEL", "production").strip().lower()
    if value not in DEPLOYMENT_CHANNELS:
        raise ValueError(
            "MAP_PLATFORM_DEPLOYMENT_CHANNEL must be development or production"
        )
    return value


def load_generation_profile_policy(repo_root: Path) -> GenerationProfilePolicy:
    path = Path(
        os.environ.get(
            "MAP_PLATFORM_GENERATION_PROFILE_POLICY",
            repo_root / "map-platform" / "config" / "generation-profile-policy-v1.json",
        )
    )
    return GenerationProfilePolicy.load(path)
