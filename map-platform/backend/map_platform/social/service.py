from __future__ import annotations

import base64
import hashlib
import json
import secrets
import time
import uuid
from sqlalchemy import and_, delete, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

from .database import (Database, accounts, blocks, content, devices, friendships, invites,
                       limits, links, media, members, messages, outbox, rides)
from .geometry import distance, route_progress, sanitize_track
from .media import sanitize_avatar


class SocialError(Exception):
    def __init__(self, code: str, status: int = 400):
        self.code, self.status = code, status
        super().__init__(code)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_json_key")
        result[key] = value
    return result


def identifier():
    return str(uuid.uuid4())


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def upsert(c, table, values, keys, changes=None):
    statement = (pg_insert if c.dialect.name == "postgresql" else sqlite_insert)(table).values(**values)
    if changes is None:
        statement = statement.on_conflict_do_nothing(index_elements=keys)
    else:
        statement = statement.on_conflict_do_update(index_elements=keys, set_=changes)
    c.execute(statement)


def row(c, table, condition):
    result = c.execute(select(table).where(condition)).mappings().first()
    if result is None:
        raise SocialError("not_found", 404)
    return dict(result)


class SocialService:
    def __init__(self, database, media_store, clock=time.time):
        self.db, self.media, self.now = database, media_store, clock

    def account(self, principal):
        def perform(c):
            condition = and_(accounts.c.project == principal.project, accounts.c.uid == principal.uid)
            account = c.execute(select(accounts).where(condition)).mappings().first()
            if account is None:
                upsert(c, accounts, {"id": identifier(), "project": principal.project,
                       "uid": principal.uid, "name": "Rider", "state": "active", "version": 1,
                       "privacy": {"zones": [], "requests": True, "invitations": True, "notifications": True},
                       "created": self.now()}, ["project", "uid"])
                account = row(c, accounts, condition)
            if account["state"] != "active":
                raise SocialError("account_unavailable", 403)
            return account["id"]
        return self.db.run(perform)

    def active(self, c, account):
        result = row(c, accounts, accounts.c.id == account)
        if result["state"] != "active":
            raise SocialError("account_unavailable", 403)
        return result

    def rate(self, account, category, maximum, seconds=3600):
        def perform(c):
            self.db.lock(c, account)
            self.active(c, account)
            key, window = f"{account}:{category}", int(self.now()//seconds)
            upsert(c, limits, {"key": key, "window": window, "count": 1, "expires": (window+2)*seconds}, ["key", "window"],
                   {"count": limits.c.count+1})
            return c.scalar(select(limits.c.count).where(and_(limits.c.key == key, limits.c.window == window)))
        if self.db.run(perform) > maximum:
            raise SocialError("rate_limited", 429)

    def blocked(self, c, a, b):
        return c.scalar(select(blocks.c.owner).where(or_(
            and_(blocks.c.owner == a, blocks.c.target == b),
            and_(blocks.c.owner == b, blocks.c.target == a)))) is not None

    def pair_allowed(self, c, a, b):
        self.active(c, a)
        self.active(c, b)
        if self.blocked(c, a, b):
            raise SocialError("not_found", 404)

    def friends(self, c, a, b):
        a, b = sorted((a, b))
        return c.scalar(select(friendships.c.id).where(and_(friendships.c.a == a,
            friendships.c.b == b, friendships.c.status == "accepted"))) is not None

    def profile(self, c, viewer, target, own=False):
        self.pair_allowed(c, viewer, target)
        account = self.active(c, target)
        result = {"id": target, "username": account["username"], "displayName": account["name"],
                  "avatarID": account["avatar"], "version": account["version"]}
        if own:
            from .models import Privacy
            result["privacy"] = Privacy.model_validate(account["privacy"]).model_dump()
        return result

    def edit_profile(self, c, actor, data):
        self.db.lock(c, actor)
        account = self.active(c, actor)
        if data.version != account["version"]:
            raise SocialError("version_conflict", 409)
        if c.scalar(select(accounts.c.id).where(and_(accounts.c.username == data.username,
                                                     accounts.c.id != actor))):
            raise SocialError("username_unavailable", 409)
        privacy = data.privacy.model_dump()
        if account["privacy"].get("zones", []) != privacy["zones"]:
            # No raw activity coordinates are retained. Require owner resubmission.
            c.execute(update(content).where(and_(content.c.owner == actor, content.c.kind == "activity"))
                      .values(visibility="private", body={"needsReprocessing": True}, revision=content.c.revision+1))
            c.execute(delete(links).where(links.c.owner == actor))
        c.execute(update(accounts).where(accounts.c.id == actor).values(
            username=data.username, name=data.displayName.strip(), privacy=privacy, version=account["version"]+1))
        return self.profile(c, actor, actor, True)

    def emit(self, c, owner, kind, body):
        c.execute(outbox.insert().values(id=identifier(), owner=owner, kind=kind, body=body,
                                        created=self.now(), attempts=0, next_attempt=0))

    def friend_request(self, c, actor, target):
        if actor == target:
            raise SocialError("self_request")
        self.db.lock(c, actor, target)
        self.pair_allowed(c, actor, target)
        if not self.active(c, target)["privacy"].get("requests", True):
            raise SocialError("requests_disabled", 403)
        a, b = sorted((actor, target))
        existing = c.execute(select(friendships).where(and_(friendships.c.a == a, friendships.c.b == b))).mappings().first()
        if existing and (existing["status"] == "accepted" or (existing["status"] == "pending" and self.now()-existing["updated"] <= 30*86400)):
            return dict(existing)
        if existing and self.now()-existing["updated"] < 86400:
            raise SocialError("request_cooldown", 429)
        values = {"id": existing["id"] if existing else identifier(), "a": a, "b": b,
                  "sender": actor, "status": "pending", "updated": self.now()}
        upsert(c, friendships, values, ["a", "b"], values)
        self.emit(c, target, "friend_request", {"requestID": values["id"]})
        return values

    def friend_action(self, c, actor, request_id, action):
        item = row(c, friendships, friendships.c.id == request_id)
        self.db.lock(c, item["a"], item["b"])
        item = row(c, friendships, friendships.c.id == request_id)
        if actor not in {item["a"], item["b"]}:
            raise SocialError("not_found", 404)
        self.pair_allowed(c, item["a"], item["b"])
        if item["sender"] == actor or item["status"] != "pending":
            raise SocialError("invalid_transition", 409)
        if self.now()-item["updated"] > 30*86400:
            raise SocialError("expired", 410)
        c.execute(update(friendships).where(friendships.c.id == request_id)
                  .values(status=action, updated=self.now()))
        return {"status": action}

    def remove_friend(self, c, actor, target, block=False):
        self.db.lock(c, actor, target)
        self.active(c, actor)
        self.active(c, target)
        a, b = sorted((actor, target))
        c.execute(update(friendships).where(and_(friendships.c.a == a, friendships.c.b == b))
                  .values(status="removed", updated=self.now()))
        c.execute(update(invites).where(and_(or_(
            and_(invites.c.sender == actor, invites.c.recipient == target),
            and_(invites.c.sender == target, invites.c.recipient == actor)), invites.c.status == "pending"))
                  .values(status="revoked"))
        if block:
            upsert(c, blocks, {"owner": actor, "target": target}, ["owner", "target"])
            shared = list(c.scalars(select(members.c.ride).where(and_(members.c.account == actor,
                                                               members.c.status == "accepted"))))
            for ride_id in shared:
                target_member = c.execute(select(members).where(and_(members.c.ride == ride_id,
                    members.c.account == target, members.c.status == "accepted"))).first()
                if target_member:
                    ride = row(c, rides, rides.c.id == ride_id)
                    removed = target if ride["owner"] == actor else actor
                    c.execute(update(members).where(and_(members.c.ride == ride_id, members.c.account == removed))
                              .values(status="removed", sharing=False, stats=False, live=None))
        return {"status": "blocked" if block else "removed"}

    def set_avatar(self, c, actor, raw, version):
        variants = sanitize_avatar(raw)
        self.db.lock(c, actor)
        account = self.active(c, actor)
        if version != account["version"]:
            raise SocialError("version_conflict", 409)
        asset, receipts = identifier(), {}
        for name, value in variants.items():
            key = f"avatars/{actor}/{asset}/{name}.png"
            # Record cleanup before external writes; callers reconcile object orphans.
            self.media.put(key, value)
            receipts[name] = {"key": key, "sha256": hashlib.sha256(value).hexdigest()}
        c.execute(media.insert().values(id=asset, owner=actor, variants=receipts, created=self.now()))
        if account["avatar"]:
            self.emit(c, actor, "delete_media", {"assetID": account["avatar"]})
        c.execute(update(accounts).where(accounts.c.id == actor).values(avatar=asset, version=version+1))
        return self.profile(c, actor, actor, True)

    def remove_avatar(self, c, actor):
        self.db.lock(c, actor)
        account = self.active(c, actor)
        if account["avatar"]:
            self.emit(c, actor, "delete_media", {"assetID": account["avatar"]})
        c.execute(update(accounts).where(accounts.c.id == actor).values(avatar=None, version=accounts.c.version+1))
        return self.profile(c, actor, actor, True)

    def content_read(self, c, actor, content_id, *, capability=False):
        item = row(c, content, content.c.id == content_id)
        self.active(c, item["owner"])
        if actor:
            self.pair_allowed(c, actor, item["owner"])
        if actor != item["owner"]:
            visible = (item["visibility"] == "friends" and actor and self.friends(c, actor, item["owner"]))
            if not visible and not (capability and item["visibility"] == "link"):
                raise SocialError("not_found", 404)
        return item

    def replay(self, c, actor, result):
        if "members" in result and "riders" in result:
            return self.ride_read(c, actor, result["id"])
        if "kind" in result and "body" in result:
            return {k:v for k,v in self.content_read(c, actor, result["id"]).items() if k != "source"}
        if "displayName" in result:
            return self.profile(c, actor, result["id"], result["id"] == actor)
        if "a" in result and "b" in result:
            self.pair_allowed(c, result["a"], result["b"])
            return row(c, friendships, friendships.c.id == result["id"])
        if "url" in result:
            row(c, links, and_(links.c.id == result["id"], links.c.owner == actor, links.c.expires > self.now()))
        return result

    def upload_route(self, c, actor, data):
        self.db.lock(c, actor)
        self.active(c, actor)
        try:
            archive = json.loads(data.archive, object_pairs_hook=unique_object, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
            payload = json.loads(data.hashPayload, object_pairs_hook=unique_object, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
            if (payload != {k: v for k, v in archive.items() if k != "contentHash"}
                    or digest(data.hashPayload) != archive.get("contentHash")):
                raise ValueError()
            from .route_archive import validate_archive
            validate_archive(archive)
            route = archive["route"]
            points = route["points"]
            from .models import Point
            if (archive["schemaVersion"] != 1 or len(points) < 2 or len(points) > 20000
                    or route["provider"] != {"providerID": "user.imported-gpx", "attribution": "User-provided GPX", "storageScope": "durable"}
                    or route.get("sourceReference") or archive.get("deleteAfter") is not None
                    or not isinstance(archive["contentHash"], str) or len(archive["contentHash"]) != 64):
                raise ValueError()
            for point in points:
                Point.model_validate(point)
            uuid.UUID(route["id"])
        except (ValueError, KeyError, TypeError, AttributeError, OverflowError):
            raise SocialError("route_not_redistributable") from None
        if c.scalar(select(func.count()).select_from(content).where(content.c.owner == actor)) >= 500:
            raise SocialError("content_quota", 429)
        item = {"id": identifier(), "owner": actor, "kind": "route", "title": data.title,
                "visibility": data.visibility, "revision": 1,
                "body": {"archive": data.archive, "sha256": digest(data.archive), "hashPayload": data.hashPayload, "distanceMeters": route["distanceMeters"]},
                "source": None, "created": self.now()}
        c.execute(content.insert().values(**item))
        return item

    def upload_activity(self, c, actor, data):
        self.db.lock(c, actor)
        account = self.active(c, actor)
        if data.movingSeconds > data.elapsedSeconds:
            raise SocialError("invalid_duration")
        try:
            result = sanitize_track([p.model_dump() for p in data.points], account["privacy"].get("zones", []))
        except ValueError:
            raise SocialError("invalid_track") from None
        if not result["segments"]:
            raise SocialError("track_hidden_by_privacy")
        # No full-track distance, endpoints, metadata, or raw track is persisted.
        result.update(movingSeconds=data.movingSeconds, elapsedSeconds=data.elapsedSeconds)
        existing = c.execute(select(content).where(and_(content.c.owner == actor,
            content.c.kind == "activity", content.c.source == data.sourceID))).mappings().first()
        if not existing and c.scalar(select(func.count()).select_from(content).where(content.c.owner == actor)) >= 500:
            raise SocialError("content_quota", 429)
        item = {"id": existing["id"] if existing else identifier(), "owner": actor, "kind": "activity",
                "title": data.title, "visibility": data.visibility,
                "revision": existing["revision"]+1 if existing else 1, "body": result,
                "source": data.sourceID, "created": self.now()}
        upsert(c, content, item, ["owner", "kind", "source"], item)
        return item

    def edit_content(self, c, actor, content_id, data):
        self.db.lock(c, actor)
        item = self.content_read(c, actor, content_id)
        if item["owner"] != actor:
            raise SocialError("not_found", 404)
        if data.revision != item["revision"]:
            raise SocialError("version_conflict", 409)
        if item["body"].get("needsReprocessing"):
            raise SocialError("privacy_reprocessing_required", 409)
        c.execute(update(content).where(content.c.id == content_id).values(title=data.title,
                  visibility=data.visibility, revision=item["revision"]+1))
        if data.visibility != "link":
            c.execute(delete(links).where(links.c.content == content_id))
        return self.content_read(c, actor, content_id)

    def delete_content(self, c, actor, content_id):
        self.db.lock(c, actor)
        item = row(c, content, content.c.id == content_id)
        if item["owner"] != actor:
            raise SocialError("not_found", 404)
        c.execute(delete(links).where(links.c.content == content_id))
        c.execute(delete(content).where(content.c.id == content_id))
        return {"deleted": True}

    def share(self, c, actor, data):
        self.db.lock(c, actor)
        item = self.content_read(c, actor, data.contentID)
        if item["owner"] != actor or item["visibility"] != "link":
            raise SocialError("link_visibility_required", 409)
        secret, link_id = secrets.token_urlsafe(32), identifier()
        c.execute(links.insert().values(id=link_id, owner=actor, content=item["id"], digest=digest(secret),
                                       expires=self.now()+data.expiresIn))
        return {"id": link_id, "url": f"https://bicino.com/social/shared/{secret}",
                "expiresAt": self.now()+data.expiresIn}

    def require_room_capacity(self, c, actor):
        count = c.scalar(select(func.count()).select_from(members.join(rides, members.c.ride == rides.c.id)).where(and_(
            members.c.account == actor, members.c.status == "accepted",
            rides.c.status.in_(["planned", "active"]), rides.c.expires > self.now())))
        if count >= 25:
            raise SocialError("active_ride_limit", 409)

    def create_ride(self, c, actor, data):
        self.db.lock(c, actor)
        self.require_room_capacity(c, actor)
        source = self.content_read(c, actor, data.routeID)
        if source["kind"] != "route":
            raise SocialError("route_required")
        code, ride_id = secrets.token_urlsafe(24), identifier()
        start = data.startsAt if data.startsAt is not None else self.now()
        if not self.now()-3600 <= start <= self.now()+30*86400:
            raise SocialError("invalid_start")
        c.execute(rides.insert().values(id=ride_id, owner=actor, title=data.title,
            route=source["body"], status="planned", starts=start, expires=start+86400,
            code=digest(code), created=self.now()))
        c.execute(members.insert().values(ride=ride_id, account=actor, status="accepted", sharing=False,
                  stats=False, sequence=-1, live=None, epoch=identifier()))
        return dict(self.ride_read(c, actor, ride_id), joinCode=code)

    def require_member(self, c, actor, ride_id):
        self.active(c, actor)
        ride = row(c, rides, rides.c.id == ride_id)
        if ride["status"] in {"ended", "expired"} or ride["expires"] <= self.now():
            raise SocialError("ride_ended", 410)
        self.pair_allowed(c, actor, ride["owner"])
        member = row(c, members, and_(members.c.ride == ride_id, members.c.account == actor))
        if member["status"] != "accepted":
            raise SocialError("membership_required", 403)
        return ride, member

    def ride_read(self, c, actor, ride_id):
        ride, me = self.require_member(c, actor, ride_id)
        roster, live = [], []
        for m in c.execute(select(members).where(and_(members.c.ride == ride_id,
                                                       members.c.status == "accepted"))).mappings():
            if self.blocked(c, actor, m["account"]):
                continue
            person = row(c, accounts, accounts.c.id == m["account"])
            if person["state"] != "active":
                continue
            profile = {"id": person["id"], "displayName": person["name"], "avatarID": person["avatar"]}
            roster.append(profile)
            if m["sharing"] and m["lease"] and m["lease"] > self.now() and m["live"] and m["received"] is not None and self.now()-m["received"] < 60:
                state = dict(m["live"])
                state.update(profile=profile, receivedAt=m["received"], age=max(0, self.now()-state["capturedAt"]))
                if state["age"] < 60:
                    live.append(state)
        return {"id": ride_id, "title": ride["title"], "owner": ride["owner"],
                "status": ride["status"], "expiresAt": ride["expires"], "route": ride["route"],
                "members": roster, "riders": live, "sharing": bool(me["sharing"] and me["lease"] and me["lease"] > self.now()), "stats": me["stats"],
                "epoch": me["epoch"], "serverTime": self.now()}

    def invite(self, c, actor, data):
        self.db.lock(c, actor, data.profileID)
        ride, _ = self.require_member(c, actor, data.rideID)
        self.pair_allowed(c, actor, data.profileID)
        if ride["owner"] != actor or not self.friends(c, actor, data.profileID):
            raise SocialError("friend_invitation_required", 403)
        if not self.active(c, data.profileID)["privacy"].get("invitations", True):
            raise SocialError("invitations_disabled", 403)
        item = {"id": identifier(), "ride": data.rideID, "sender": actor, "recipient": data.profileID,
                "status": "pending", "expires": ride["expires"]}
        upsert(c, invites, item, ["ride", "recipient"], item)
        self.emit(c, data.profileID, "ride_invite", {"rideID": data.rideID})
        return dict(row(c, invites, and_(invites.c.ride == data.rideID, invites.c.recipient == data.profileID)))

    def join(self, c, actor, ride_id, *, invited=False):
        ride = row(c, rides, rides.c.id == ride_id)
        self.db.lock(c, actor, ride["owner"])
        if ride["expires"] <= self.now() or ride["status"] not in {"planned", "active"}:
            raise SocialError("ride_closed", 410)
        self.pair_allowed(c, actor, ride["owner"])
        existing = c.execute(select(members).where(and_(members.c.ride == ride_id,
                                                        members.c.account == actor))).mappings().first()
        if existing and existing["status"] == "removed" and not invited:
            raise SocialError("new_invitation_required", 403)
        roster = list(c.scalars(select(members.c.account).where(and_(members.c.ride == ride_id,
                                                                    members.c.status == "accepted"))))
        if len(roster) >= 25 and actor not in roster:
            raise SocialError("ride_full", 409)
        if any(self.blocked(c, actor, other) for other in roster):
            raise SocialError("ride_unavailable", 403)
        if not existing or existing["status"] != "accepted":
            self.require_room_capacity(c, actor)
            values = {"ride": ride_id, "account": actor, "status": "accepted", "sharing": False,
                      "stats": False, "sequence": -1, "live": None, "received": None, "epoch": identifier()}
            upsert(c, members, values, ["ride", "account"], values)
        return self.ride_read(c, actor, ride_id)

    def consent(self, c, actor, ride_id, data):
        self.db.lock(c, actor)
        ride, _ = self.require_member(c, actor, ride_id)
        if data.location and ride["starts"] > self.now()+3600:
            raise SocialError("ride_not_started", 409)
        c.execute(update(members).where(and_(members.c.ride == ride_id, members.c.account == actor))
                  .values(sharing=data.location, stats=data.location and data.stats, live=None,
                          sequence=-1, epoch=identifier(), received=None, lease=self.now()+60 if data.location else None))
        if data.location:
            c.execute(update(rides).where(rides.c.id == ride_id).values(status="active"))
        return self.ride_read(c, actor, ride_id)

    def publish(self, c, actor, ride_id, data):
        self.db.lock(c, actor)
        ride, member = self.require_member(c, actor, ride_id)
        if not member["sharing"] or not member["lease"] or member["lease"] <= self.now() or data.epoch != member["epoch"]:
            raise SocialError("sharing_disabled", 403)
        if data.sequence <= member["sequence"] or not self.now()-30 <= data.capturedAt <= self.now()+5:
            raise SocialError("stale_state", 409)
        if member["received"] and self.now()-member["received"] < 2:
            raise SocialError("publish_rate", 429)
        payload = data.model_dump(exclude_none=True)
        route = json.loads(ride["route"]["archive"])["route"]
        previous = member["live"] or {}
        elapsed = data.capturedAt-previous.get("capturedAt", data.capturedAt)
        continuity = previous.get("routeProgressMeters") if 0 < elapsed <= 30 else None
        progress = route_progress(route["points"], payload, continuity, elapsed if continuity is not None else None)
        if progress is not None:
            payload["routeProgressMeters"] = progress
            payload["routeHash"] = ride["route"]["sha256"]
        if not member["stats"]:
            for key in ("speed", "distanceMeters", "movingSeconds", "elapsedSeconds", "elevationGainMeters"):
                payload.pop(key, None)
        c.execute(update(members).where(and_(members.c.ride == ride_id, members.c.account == actor))
                  .values(sequence=data.sequence, live=payload, received=self.now(), lease=self.now()+60))
        return {"accepted": data.sequence}

    def leave(self, c, actor, ride_id, end=False):
        self.db.lock(c, actor)
        ride = row(c, rides, rides.c.id == ride_id)
        if ride["owner"] == actor:
            end = True
        if end and ride["owner"] != actor:
            raise SocialError("owner_required", 403)
        condition = members.c.ride == ride_id
        if not end:
            condition = and_(condition, members.c.account == actor)
        c.execute(update(members).where(condition).values(status="left", sharing=False, stats=False, live=None))
        if end:
            c.execute(update(rides).where(rides.c.id == ride_id).values(status="ended"))
            c.execute(update(invites).where(invites.c.ride == ride_id).values(status="revoked"))
        return {"status": "ended" if end else "left"}

    def begin_deletion(self, c, actor):
        self.db.lock(c, actor)
        c.execute(update(accounts).where(accounts.c.id == actor).values(state="deleting", avatar=None,
                  username=None, name="Deleted rider", privacy={}, version=accounts.c.version+1))
        c.execute(update(members).where(members.c.account == actor).values(status="left", live=None, sharing=False))
        for ride_id in c.scalars(select(rides.c.id).where(rides.c.owner == actor)):
            self.leave(c, actor, ride_id, end=True)
        c.execute(delete(links).where(links.c.owner == actor))
        c.execute(update(invites).where(or_(invites.c.sender == actor, invites.c.recipient == actor)).values(status="revoked"))
        c.execute(delete(devices).where(devices.c.owner == actor))
        self.emit(c, actor, "delete_account", {})
        return {"status": "deleting"}
