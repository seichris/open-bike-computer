"""Public, view-only invitation cards; never expose a join code or live state."""
from __future__ import annotations

import hashlib
from io import BytesIO
import warnings
from PIL import Image, ImageOps
from sqlalchemy import select, update

from .database import media, rides
from .service import SocialError, identifier, row


def sanitize_preview(raw: bytes) -> bytes:
    if not raw or len(raw) > 5 * 1024 * 1024:
        raise ValueError("preview_size")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(BytesIO(raw)) as source:
                if (source.format not in {"PNG", "JPEG"} or getattr(source, "n_frames", 1) != 1
                        or source.size != (1200, 630)):
                    raise ValueError("preview_format")
                source.load()
                image = ImageOps.exif_transpose(source).convert("RGB")
                if image.size != (1200, 630):
                    raise ValueError("preview_dimensions")
                clean = Image.frombytes("RGB", image.size, image.tobytes()).quantize(colors=256)
                output = BytesIO()
                clean.save(output, format="PNG", optimize=True)
                data = output.getvalue()
                if len(data) > 512000:
                    raise ValueError("preview_size")
                return data
    except (Image.DecompressionBombWarning, Image.DecompressionBombError):
        raise ValueError("preview_dimensions") from None


class InvitePreviews:
    def __init__(self, service):
        self.service = service

    def owner(self, c, actor, ride_id):
        ride, _ = self.service.require_member(c, actor, ride_id)
        if ride["owner"] != actor:
            raise SocialError("owner_required", 403)
        return ride

    def prepare(self, actor, ride_id, raw):
        data = sanitize_preview(raw)
        asset = identifier()
        receipt = {"key": f"ride-previews/{actor}/{asset}/invite.png",
                   "sha256": hashlib.sha256(data).hexdigest(), "rideID": ride_id}
        self.service.media.put(receipt["key"], data)
        return asset, receipt

    def attach(self, c, actor, ride_id, prepared):
        self.service.db.lock(c, actor)
        # Serialize against expiry maintenance as well as owner mutations.
        c.execute(select(rides.c.id).where(rides.c.id == ride_id).with_for_update()).first()
        ride = self.owner(c, actor, ride_id)
        asset, receipt = prepared
        c.execute(media.insert().values(id=asset, owner=actor, variants={"invite": receipt}, created=self.service.now()))
        route = dict(ride["route"])
        previous = route.get("invitePreviewAssetID")
        route["invitePreviewAssetID"] = asset
        c.execute(update(rides).where(rides.c.id == ride_id).values(route=route))
        if previous:
            self.service.emit(c, actor, "delete_media", {"assetID": previous})
        return {"previewID": asset}

    def locate(self, c, asset_id):
        asset = row(c, media, media.c.id == asset_id)
        receipt = asset["variants"].get("invite")
        if not receipt:
            raise SocialError("not_found", 404)
        self.service.active(c, asset["owner"])
        ride = row(c, rides, rides.c.id == receipt["rideID"])
        if (ride["owner"] != asset["owner"] or ride["status"] not in {"planned", "active"}
                or ride["expires"] <= self.service.now() or ride["route"].get("invitePreviewAssetID") != asset_id):
            raise SocialError("not_found", 404)
        return ride, receipt

    def metadata(self, c, asset_id):
        ride, receipt = self.locate(c, asset_id)
        # A fixed allowlist: no route coordinates/archive, account, roster,
        # storage keys, invitation capability, or live positions cross this boundary.
        return {"previewID": asset_id, "title": ride["title"],
                "distanceMeters": ride["route"].get("distanceMeters", 0),
                "imageSHA256": receipt["sha256"], "expiresAt": ride["expires"]}
