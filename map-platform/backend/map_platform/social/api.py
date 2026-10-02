from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import time
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from sqlalchemy import and_, delete, or_, select, text, update
from sqlalchemy.exc import IntegrityError, OperationalError
from starlette.concurrency import run_in_threadpool

from ..request_limits import RequestBodyLimitMiddleware
from ..user_auth import FirebaseIdentity
from .database import (Database, accounts, blocks, content, devices, friendships, invites,
                       links, media, members, messages, replays, rides)
from .media import S3Media
from .models import (ActivityUpload, Consent, ContentEdit, Deletion, DeviceBinding, Join,
                     LiveState, ProfileEdit, QuickMessage, RideCreate, RideInvitation,
                     RouteUpload, ShareInput, Target, WebsiteDeletion)
from .service import SocialError, SocialService, digest, identifier, row, upsert


def public_content(item):
    return {k: v for k, v in item.items() if k != "source"}


def create_app(*, service=None, identity=None):
    if service is None:
        db = Database(os.environ["BICINO_SOCIAL_DATABASE_URL"])
        db.check_schema()
        service = SocialService(db, S3Media())
    if identity is None:
        identity = FirebaseIdentity(os.environ["BICINO_FIREBASE_PROJECT_ID"])
    app = FastAPI(title="Bicino social", version="1")
    app.state.service = service
    app.add_middleware(RequestBodyLimitMiddleware, max_body_bytes=5*1024*1024)

    @app.exception_handler(SocialError)
    async def error_handler(request, error):
        return JSONResponse({"code": error.code}, status_code=error.status,
                            headers={"Cache-Control": "no-store"})

    @app.exception_handler(IntegrityError)
    async def conflict_handler(request, error):
        return JSONResponse({"code": "conflict"}, status_code=409)

    @app.middleware("http")
    async def private_responses(request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    def authenticate(authorization: str | None = Header(default=None)):
        if not authorization or not authorization.startswith("Bearer "):
            raise SocialError("authentication_required", 401)
        try:
            principal = identity.verify(authorization[7:])
        except Exception:
            raise SocialError("authentication_required", 401) from None
        actor = service.account(principal)
        service.rate(actor, "requests", 600, 60)
        return actor, principal

    async def operation(request, auth, callback):
        actor, _ = auth
        key = request.headers.get("Idempotency-Key", "")
        if not 8 <= len(key) <= 128:
            raise SocialError("idempotency_key_required")
        raw = await request.body()
        fingerprint = hashlib.sha256(request.method.encode()+request.url.path.encode()+request.url.query.encode()+raw).hexdigest()
        def execute():
            with service.db.transaction() as c:
                if c.dialect.name == "postgresql":
                    # Serialize only this actor's replay ledger. Pair row locks
                    # are acquired later in canonical order by domain operations.
                    lock_id = int.from_bytes(hashlib.sha256(actor.encode()).digest()[:8], "big", signed=True)
                    c.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": lock_id})
                service.active(c, actor)
                old = c.execute(select(replays).where(and_(replays.c.owner == actor, replays.c.key == key))).mappings().first()
                if old:
                    if old["digest"] != fingerprint:
                        raise SocialError("idempotency_conflict", 409)
                    return service.replay(c, actor, old["response"])
                result = callback(c, actor)
                retained = dict(result)
                if "riders" in retained:
                    retained["riders"] = []  # Live locations must never enter the replay ledger.
                c.execute(replays.insert().values(owner=actor, key=key, digest=fingerprint,
                                                 response=retained, created=service.now()))
                return result
        for attempt in range(4):
            try:
                return await run_in_threadpool(execute)
            except OperationalError as error:
                if getattr(error.orig, "sqlstate", None) not in {"40001", "40P01"}:
                    raise
                if attempt == 3:
                    raise SocialError("concurrent_update_retry", 409) from None
                await asyncio.sleep(0.02 * (attempt + 1))

    @app.post("/internal/account-deletion")
    async def website_deletion(data: WebsiteDeletion, request: Request):
        secret = os.environ.get("BICINO_SOCIAL_DELETION_SECRET", "")
        signature = request.headers.get("X-Bicino-Deletion-Signature", "")
        raw = await request.body()
        if len(secret) < 32 or not hmac.compare_digest(signature, hmac.new(secret.encode(), raw, "sha256").hexdigest()):
            raise SocialError("authentication_required", 401)
        if (data.project != os.environ.get("BICINO_FIREBASE_PROJECT_ID")
                or abs(service.now()-data.issuedAt) > 60
                or not 0 <= service.now()-data.authTime <= 300):
            raise SocialError("authentication_required", 401)
        def perform():
            with service.db.transaction() as c:
                account = c.execute(select(accounts).where(and_(accounts.c.uid == data.uid,
                    accounts.c.project == data.project))).mappings().first()
                if account and account["state"] == "active":
                    service.begin_deletion(c, account["id"])
            # A duplicate proof can only continue the same verified deletion.
            return {"status": "deleting"}
        return await run_in_threadpool(perform)

    @app.get("/healthz")
    def health():
        service.db.check_schema()
        return {"status": "ok"}

    @app.get("/me")
    def me(auth=Depends(authenticate)):
        with service.db.transaction() as c:
            return service.profile(c, auth[0], auth[0], True)

    @app.patch("/me")
    async def edit_me(data: ProfileEdit, request: Request, auth=Depends(authenticate)):
        return await operation(request, auth, lambda c, a: service.edit_profile(c, a, data))

    @app.put("/me/avatar")
    async def avatar(request: Request, version: int = Query(ge=1), auth=Depends(authenticate)):
        service.rate(auth[0], "avatar", 10)
        raw = await request.body()
        try:
            return await operation(request, auth, lambda c, a: service.set_avatar(c, a, raw, version))
        except (ValueError, OSError):
            raise SocialError("invalid_image") from None

    @app.delete("/me/avatar")
    async def remove_avatar(request: Request, auth=Depends(authenticate)):
        return await operation(request, auth, service.remove_avatar)

    @app.get("/media/{asset_id}/{variant}")
    def get_media(asset_id: str, variant: str, auth=Depends(authenticate)):
        with service.db.transaction() as c:
            asset = row(c, media, media.c.id == asset_id)
            service.pair_allowed(c, auth[0], asset["owner"])
            if service.active(c, asset["owner"])["avatar"] != asset_id or variant not in asset["variants"]:
                raise SocialError("not_found", 404)
            receipt = asset["variants"][variant]
            data = service.media.get(receipt["key"])
            if hashlib.sha256(data).hexdigest() != receipt["sha256"]:
                raise SocialError("media_unavailable", 503)
            return Response(data, media_type="image/png")

    @app.get("/profiles/by-username/{username}")
    def lookup(username: str, auth=Depends(authenticate)):
        service.rate(auth[0], "lookup", 60)
        with service.db.transaction() as c:
            target = row(c, accounts, accounts.c.username == username.lower())["id"]
            return service.profile(c, auth[0], target)

    @app.get("/profiles/{profile_id}")
    def profile(profile_id: str, auth=Depends(authenticate)):
        with service.db.transaction() as c:
            return service.profile(c, auth[0], profile_id)

    @app.get("/friends")
    def friends(after: str = "", auth=Depends(authenticate)):
        with service.db.transaction() as c:
            actor = auth[0]
            records = list(c.execute(select(friendships).where(and_(
                or_(friendships.c.a == actor, friendships.c.b == actor),
                friendships.c.status == "accepted", friendships.c.id > after))
                .order_by(friendships.c.id).limit(50)).mappings())
            result = []
            for item in records:
                other = item["b"] if item["a"] == actor else item["a"]
                try:
                    result.append(service.profile(c, actor, other))
                except SocialError:
                    continue
            return {"items": result, "cursor": records[-1]["id"] if len(records) == 50 else None}

    @app.get("/friend-requests")
    def requests(after: str = "", auth=Depends(authenticate)):
        with service.db.transaction() as c:
            actor = auth[0]
            values = list(c.execute(select(friendships).where(and_(or_(friendships.c.a == actor,
                friendships.c.b == actor), friendships.c.status == "pending", friendships.c.id > after,
                friendships.c.updated > service.now()-30*86400)).order_by(friendships.c.id).limit(50)).mappings())
            return {"items": [dict(v) for v in values], "cursor": values[-1]["id"] if len(values) == 50 else None}

    @app.post("/friend-requests")
    async def send_request(data: Target, request: Request, auth=Depends(authenticate)):
        service.rate(auth[0], "friend_requests", 20)
        return await operation(request, auth, lambda c, a: service.friend_request(c, a, data.profileID))

    @app.delete("/friend-requests/{request_id}")
    async def cancel_request(request_id: str, request: Request, auth=Depends(authenticate)):
        def perform(c, actor):
            item = row(c, friendships, friendships.c.id == request_id)
            service.db.lock(c, item["a"], item["b"])
            if item["sender"] != actor or item["status"] != "pending":
                raise SocialError("not_found", 404)
            c.execute(update(friendships).where(friendships.c.id == request_id).values(status="cancelled", updated=service.now()))
            return {"status": "cancelled"}
        return await operation(request, auth, perform)

    @app.get("/blocks")
    def blocked_profiles(auth=Depends(authenticate)):
        with service.db.transaction() as c:
            values = c.execute(select(accounts.c.id, accounts.c.name).join(blocks, blocks.c.target == accounts.c.id)
                .where(blocks.c.owner == auth[0]).order_by(accounts.c.name)).mappings()
            return {"items": [{"id": v["id"], "displayName": v["name"]} for v in values]}

    @app.post("/friend-requests/{request_id}/{action}")
    async def respond(request_id: str, action: str, request: Request, auth=Depends(authenticate)):
        if action not in {"accept", "decline"}:
            raise SocialError("not_found", 404)
        return await operation(request, auth, lambda c, a: service.friend_action(c, a, request_id,
            "accepted" if action == "accept" else "declined"))

    @app.delete("/friends/{profile_id}")
    async def remove_friend(profile_id: str, request: Request, auth=Depends(authenticate)):
        return await operation(request, auth, lambda c, a: service.remove_friend(c, a, profile_id))

    @app.put("/blocks/{profile_id}")
    async def block(profile_id: str, request: Request, auth=Depends(authenticate)):
        return await operation(request, auth, lambda c, a: service.remove_friend(c, a, profile_id, True))

    @app.delete("/blocks/{profile_id}")
    async def unblock(profile_id: str, request: Request, auth=Depends(authenticate)):
        def perform(c, actor):
            service.db.lock(c, actor, profile_id)
            c.execute(delete(blocks).where(and_(blocks.c.owner == actor, blocks.c.target == profile_id)))
            return {"status": "unrelated"}
        return await operation(request, auth, perform)

    @app.get("/routes")
    @app.get("/activities")
    def list_content(request: Request, owner: str | None = None, after: str = "", auth=Depends(authenticate)):
        kind = "route" if request.url.path.endswith("/routes") else "activity"
        with service.db.transaction() as c:
            owner = owner or auth[0]
            service.pair_allowed(c, auth[0], owner)
            condition = and_(content.c.owner == owner, content.c.kind == kind, content.c.id > after)
            if owner != auth[0]:
                if not service.friends(c, auth[0], owner):
                    raise SocialError("not_found", 404)
                condition = and_(condition, content.c.visibility == "friends")
            values = list(c.execute(select(content).where(condition).order_by(content.c.id).limit(20)).mappings())
            return {"items": [dict(public_content(dict(v)), body={}) for v in values],
                    "cursor": values[-1]["id"] if len(values) == 20 else None}

    @app.post("/routes")
    async def upload_route(data: RouteUpload, request: Request, auth=Depends(authenticate)):
        service.rate(auth[0], "publication", 30)
        return await operation(request, auth, lambda c, a: public_content(service.upload_route(c, a, data)))

    @app.post("/activities")
    async def upload_activity(data: ActivityUpload, request: Request, auth=Depends(authenticate)):
        service.rate(auth[0], "publication", 30)
        return await operation(request, auth, lambda c, a: public_content(service.upload_activity(c, a, data)))

    @app.get("/routes/{content_id}")
    @app.get("/activities/{content_id}")
    def read_content(content_id: str, auth=Depends(authenticate)):
        with service.db.transaction() as c:
            return public_content(service.content_read(c, auth[0], content_id))

    @app.patch("/routes/{content_id}")
    @app.patch("/activities/{content_id}")
    async def edit_content(content_id: str, data: ContentEdit, request: Request, auth=Depends(authenticate)):
        return await operation(request, auth, lambda c, a: public_content(service.edit_content(c, a, content_id, data)))

    @app.delete("/routes/{content_id}")
    @app.delete("/activities/{content_id}")
    async def delete_content(content_id: str, request: Request, auth=Depends(authenticate)):
        return await operation(request, auth, lambda c, a: service.delete_content(c, a, content_id))

    @app.post("/share-links")
    async def share(data: ShareInput, request: Request, auth=Depends(authenticate)):
        return await operation(request, auth, lambda c, a: service.share(c, a, data))

    @app.delete("/share-links/{link_id}")
    async def revoke_link(link_id: str, request: Request, auth=Depends(authenticate)):
        def perform(c, actor):
            c.execute(delete(links).where(and_(links.c.owner == actor, links.c.id == link_id)))
            return {"revoked": True}
        return await operation(request, auth, perform)

    @app.get("/shared/{secret}")
    def shared(secret: str, authorization: str | None = Header(default=None)):
        actor = authenticate(authorization)[0] if authorization else None
        with service.db.transaction() as c:
            link = row(c, links, and_(links.c.digest == digest(secret), links.c.expires > service.now()))
            return public_content(service.content_read(c, actor, link["content"], capability=True))

    @app.post("/group-rides")
    async def create_ride(data: RideCreate, request: Request, auth=Depends(authenticate)):
        service.rate(auth[0], "create_ride", 10)
        return await operation(request, auth, lambda c, a: service.create_ride(c, a, data))

    @app.get("/group-rides")
    def my_rides(auth=Depends(authenticate)):
        with service.db.transaction() as c:
            ids = c.scalars(select(members.c.ride).join(rides, members.c.ride == rides.c.id).where(and_(
                members.c.account == auth[0], members.c.status == "accepted", rides.c.expires > service.now(),
                rides.c.status.in_(["planned", "active"]))).limit(25))
            result = []
            for ride in ids:
                try:
                    result.append(dict(service.ride_read(c, auth[0], ride), route={}, members=[], riders=[]))
                except SocialError:
                    continue
            return {"items": result}

    @app.post("/group-rides/join")
    async def join(data: Join, request: Request, auth=Depends(authenticate)):
        service.rate(auth[0], "join", 20)
        def perform(c, actor):
            ride_id = row(c, rides, rides.c.code == digest(data.code))["id"]
            return service.join(c, actor, ride_id)
        return await operation(request, auth, perform)

    @app.get("/group-rides/preview/{code}")
    def preview_ride(code: str, auth=Depends(authenticate)):
        service.rate(auth[0], "join", 20)
        with service.db.transaction() as c:
            ride = row(c, rides, and_(rides.c.code == digest(code), rides.c.expires > service.now(),
                                      rides.c.status.in_(["planned", "active"])))
            service.pair_allowed(c, auth[0], ride["owner"])
            prior = c.execute(select(members.c.status).where(and_(members.c.ride == ride["id"], members.c.account == auth[0]))).scalar()
            if prior == "removed":
                raise SocialError("new_invitation_required", 403)
            return {"title": ride["title"], "route": ride["route"], "expiresAt": ride["expires"]}

    @app.delete("/group-rides/{ride_id}/members/{member_id}")
    async def remove_member(ride_id: str, member_id: str, request: Request, auth=Depends(authenticate)):
        def perform(c, actor):
            service.db.lock(c, actor, member_id)
            ride, _ = service.require_member(c, actor, ride_id)
            if ride["owner"] != actor or actor == member_id:
                raise SocialError("owner_required", 403)
            c.execute(update(members).where(and_(members.c.ride == ride_id, members.c.account == member_id))
                      .values(status="removed", sharing=False, stats=False, live=None))
            c.execute(update(invites).where(and_(invites.c.ride == ride_id, invites.c.recipient == member_id))
                      .values(status="revoked"))
            return {"status": "removed"}
        return await operation(request, auth, perform)

    @app.get("/group-rides/{ride_id}")
    def get_ride(ride_id: str, auth=Depends(authenticate)):
        with service.db.transaction() as c:
            return service.ride_read(c, auth[0], ride_id)

    @app.post("/group-rides/{ride_id}/consent")
    async def consent(ride_id: str, data: Consent, request: Request, auth=Depends(authenticate)):
        return await operation(request, auth, lambda c, a: service.consent(c, a, ride_id, data))

    @app.post("/group-rides/{ride_id}/state")
    def state(ride_id: str, data: LiveState, auth=Depends(authenticate)):
        return service.db.run(lambda c: service.publish(c, auth[0], ride_id, data))

    @app.post("/group-rides/{ride_id}/leave")
    async def leave(ride_id: str, request: Request, auth=Depends(authenticate)):
        return await operation(request, auth, lambda c, a: service.leave(c, a, ride_id))

    @app.post("/group-rides/{ride_id}/end")
    async def end(ride_id: str, request: Request, auth=Depends(authenticate)):
        return await operation(request, auth, lambda c, a: service.leave(c, a, ride_id, True))

    @app.post("/group-rides/{ride_id}/rotate-code")
    async def rotate(ride_id: str, request: Request, auth=Depends(authenticate)):
        def perform(c, actor):
            service.db.lock(c, actor)
            ride, _ = service.require_member(c, actor, ride_id)
            if ride["owner"] != actor:
                raise SocialError("owner_required", 403)
            code = __import__("secrets").token_urlsafe(24)
            c.execute(update(rides).where(rides.c.id == ride_id).values(code=digest(code)))
            return {"joinCode": code}
        return await operation(request, auth, perform)

    @app.get("/ride-invites")
    def invitations(sent: bool = False, auth=Depends(authenticate)):
        with service.db.transaction() as c:
            audience = invites.c.sender if sent else invites.c.recipient
            values = c.execute(select(invites).where(and_(audience == auth[0],
                invites.c.status == "pending", invites.c.expires > service.now())).limit(50)).mappings()
            items = []
            for v in values:
                service.pair_allowed(c, auth[0], v["sender"])
                ride = row(c, rides, rides.c.id == v["ride"])
                items.append(dict(v, title=ride["title"], startsAt=ride["starts"]))
            return {"items": items}

    @app.delete("/ride-invites/{invite_id}")
    async def cancel_invitation(invite_id: str, request: Request, auth=Depends(authenticate)):
        def perform(c, actor):
            invitation = row(c, invites, and_(invites.c.id == invite_id, invites.c.sender == actor))
            service.db.lock(c, actor, invitation["recipient"])
            c.execute(update(invites).where(invites.c.id == invite_id).values(status="revoked"))
            return {"revoked": True}
        return await operation(request, auth, perform)

    @app.get("/ride-invites/{invite_id}")
    def invitation_preview(invite_id: str, auth=Depends(authenticate)):
        with service.db.transaction() as c:
            invitation = row(c, invites, and_(invites.c.id == invite_id, invites.c.recipient == auth[0],
                invites.c.status == "pending", invites.c.expires > service.now()))
            service.pair_allowed(c, auth[0], invitation["sender"])
            ride = row(c, rides, and_(rides.c.id == invitation["ride"], rides.c.status.in_(["planned", "active"])))
            return dict(invitation, title=ride["title"], route=ride["route"], startsAt=ride["starts"])

    @app.post("/ride-invites")
    async def invite(data: RideInvitation, request: Request, auth=Depends(authenticate)):
        service.rate(auth[0], "invites", 30)
        return await operation(request, auth, lambda c, a: service.invite(c, a, data))

    @app.post("/ride-invites/{invite_id}/{action}")
    async def answer(invite_id: str, action: str, request: Request, auth=Depends(authenticate)):
        if action not in {"accept", "decline"}:
            raise SocialError("not_found", 404)
        def perform(c, actor):
            invite = row(c, invites, and_(invites.c.id == invite_id, invites.c.recipient == actor))
            service.db.lock(c, actor, invite["sender"])
            invite = row(c, invites, invites.c.id == invite_id)
            service.pair_allowed(c, actor, invite["sender"])
            if invite["status"] != "pending" or invite["expires"] <= service.now():
                raise SocialError("invite_expired", 410)
            result = service.join(c, actor, invite["ride"], invited=True) if action == "accept" else {"status": "declined"}
            c.execute(update(invites).where(invites.c.id == invite_id).values(status="accepted" if action == "accept" else "declined"))
            return result
        return await operation(request, auth, perform)

    @app.post("/group-rides/{ride_id}/messages")
    async def send_message(ride_id: str, data: QuickMessage, request: Request, auth=Depends(authenticate)):
        service.rate(auth[0], "messages", 10, 60)
        def perform(c, actor):
            service.require_member(c, actor, ride_id)
            item = {"id": identifier(), "ride": ride_id, "sender": actor,
                    "status": data.status, "created": service.now()}
            c.execute(messages.insert().values(**item))
            return item
        return await operation(request, auth, perform)

    @app.get("/group-rides/{ride_id}/messages")
    def get_messages(ride_id: str, auth=Depends(authenticate)):
        with service.db.transaction() as c:
            service.require_member(c, auth[0], ride_id)
            values = c.execute(select(messages).where(messages.c.ride == ride_id)
                               .order_by(messages.c.created.desc()).limit(50)).mappings()
            return {"items": [dict(v) for v in values if not service.blocked(c, auth[0], v["sender"])]}

    @app.put("/notification-devices/{binding_id}")
    async def bind(binding_id: str, data: DeviceBinding, request: Request, auth=Depends(authenticate)):
        if data.environment != os.environ.get("BICINO_SOCIAL_ENVIRONMENT", "development"):
            raise SocialError("notification_environment_mismatch", 400)
        if len(binding_id) > 64:
            raise SocialError("invalid_binding")
        def perform(c, actor):
            service.db.lock(c, actor)
            c.execute(delete(devices).where(and_(devices.c.owner == actor, devices.c.id == binding_id)))
            # Rebinding a token replaces its old account association on this app install.
            c.execute(delete(devices).where(devices.c.token == data.token))
            c.execute(devices.insert().values(id=binding_id, owner=actor, token=data.token, environment=data.environment))
            return {"registered": True, "id": binding_id}
        return await operation(request, auth, perform)

    @app.delete("/notification-devices/{binding_id}")
    async def unbind(binding_id: str, request: Request, auth=Depends(authenticate)):
        def perform(c, actor):
            c.execute(delete(devices).where(and_(devices.c.owner == actor, devices.c.id == binding_id)))
            return {"deleted": True}
        return await operation(request, auth, perform)

    @app.post("/me/deletion")
    async def deletion(data: Deletion, request: Request, auth=Depends(authenticate)):
        actor, principal = auth
        if data.expectedProfileID != actor:
            raise SocialError("account_changed", 409)
        try:
            principal.require_recent(service.now())
        except ValueError:
            raise SocialError("reauthentication_required", 401) from None
        await run_in_threadpool(identity.revoke_apple, principal.uid, data.appleAuthorizationCode)
        return await operation(request, auth, lambda c, a: service.begin_deletion(c, a))

    @app.websocket("/group-rides/{ride_id}/live")
    async def live(websocket: WebSocket, ride_id: str):
        # Native URLSession sends Authorization at the handshake. No URL tokens.
        header = websocket.headers.get("authorization", "")
        await websocket.accept()
        try:
            auth = await run_in_threadpool(authenticate, header)
            actor = auth[0]
            service.rate(actor, "sockets", 20, 60)
            started = time.monotonic()
            last_identity_check = started
            # Database-backed snapshots make revocation consistent across API
            # processes. A two-second bounded read interval avoids process-local
            # broadcast authority and reconnect resumes from the latest state.
            while time.monotonic()-started < 300:
                loop_start = time.monotonic()
                if loop_start-last_identity_check >= 30:
                    try:
                        await run_in_threadpool(identity.verify, header[7:])
                    except Exception:
                        raise SocialError("authentication_required", 401) from None
                    last_identity_check = loop_start
                def snapshot():
                    with service.db.transaction() as c:
                        value = service.ride_read(c, actor, ride_id)
                        value.pop("route", None)
                        return value
                value = await run_in_threadpool(snapshot)
                await asyncio.wait_for(websocket.send_json(value), timeout=10)
                try:
                    message = await asyncio.wait_for(websocket.receive_text(), timeout=2)
                    if message != "ping":
                        raise SocialError("invalid_socket_message")
                except asyncio.TimeoutError:
                    pass
                await asyncio.sleep(max(0, 2-(time.monotonic()-loop_start)))
            await websocket.close(code=4001, reason="reauthenticate")
        except (SocialError, WebSocketDisconnect, asyncio.TimeoutError):
            try:
                await websocket.close(code=4003, reason="session_unavailable")
            except RuntimeError:
                pass
    return app
