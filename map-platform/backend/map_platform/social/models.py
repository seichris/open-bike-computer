from __future__ import annotations

from typing import Literal
from pydantic import BaseModel, ConfigDict, Field, field_validator


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class Point(Input):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class Zone(Point):
    radius: float = Field(ge=200, le=20000)


class Privacy(Input):
    zones: list[Zone] = Field(default_factory=list, max_length=10)
    requests: bool = True
    invitations: bool = True
    notifications: bool = True
    friendNotifications: bool = True
    rideNotifications: bool = True


class ProfileEdit(Input):
    version: int = Field(ge=1)
    username: str = Field(pattern=r"^[a-z][a-z0-9_]{2,29}$")
    displayName: str = Field(min_length=1, max_length=80)
    privacy: Privacy = Field(default_factory=Privacy)

    @field_validator("username")
    @classmethod
    def reserved(cls, value):
        if value in {"admin", "support", "bicino", "account", "me", "api", "help"}:
            raise ValueError("Username is reserved")
        return value


class Target(Input):
    profileID: str = Field(min_length=36, max_length=36)


class RouteUpload(Input):
    title: str = Field(min_length=1, max_length=160)
    visibility: Literal["private", "friends", "link"] = "private"
    archive: str = Field(min_length=100, max_length=1_900_000)
    hashPayload: str = Field(min_length=100, max_length=1_900_000)
    sharingRightsConfirmed: Literal[True]


class ContentEdit(Input):
    revision: int = Field(ge=1)
    title: str = Field(min_length=1, max_length=160)
    visibility: Literal["private", "friends", "link"]


class ActivityUpload(Input):
    title: str = Field(min_length=1, max_length=160)
    visibility: Literal["private", "friends", "link"] = "private"
    sourceID: str = Field(min_length=1, max_length=128)
    points: list[Point] = Field(min_length=2, max_length=20000)
    movingSeconds: float = Field(ge=0, le=604800)
    elapsedSeconds: float = Field(ge=0, le=604800)
    uploadConsent: Literal[True]


class ShareInput(Input):
    contentID: str
    expiresIn: int = Field(default=604800, ge=60, le=2592000)


class RideCreate(Input):
    routeID: str
    title: str = Field(min_length=1, max_length=160)
    startsAt: float | None = None


class RideInvitation(Input):
    rideID: str
    profileID: str


class Join(Input):
    code: str = Field(min_length=20, max_length=100)


class Consent(Input):
    location: bool
    stats: bool


class LiveState(Point):
    sequence: int = Field(ge=0, le=2**53-1)
    capturedAt: float
    horizontalAccuracy: float = Field(ge=0, le=100)
    course: float | None = Field(default=None, ge=0, lt=360)
    speed: float | None = Field(default=None, ge=0, le=60)
    distanceMeters: float | None = Field(default=None, ge=0, le=5_000_000)
    movingSeconds: float | None = Field(default=None, ge=0, le=604800)
    elapsedSeconds: float | None = Field(default=None, ge=0, le=604800)
    elevationGainMeters: float | None = Field(default=None, ge=0, le=100000)
    epoch: str = Field(min_length=36, max_length=36)


class QuickMessage(Input):
    status: Literal["waiting", "mechanical", "turned_around", "regroup", "meet_at_stop"]


class DeviceBinding(Input):
    token: str = Field(pattern=r"^[0-9a-f]{64,200}$")
    environment: Literal["development", "production"]


class Deletion(Input):
    expectedProfileID: str
    appleAuthorizationCode: str | None = Field(default=None, max_length=4096)


class WebsiteDeletion(Input):
    uid: str = Field(min_length=1, max_length=128)
    project: str = Field(min_length=1, max_length=128)
    authTime: int
    issuedAt: int
    nonce: str = Field(pattern=r"^[0-9a-f-]{36}$")
