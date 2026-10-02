"""Explicit migrations and retryable social cleanup/notification worker."""
from __future__ import annotations

import argparse
import os
import time
from sqlalchemy import and_, delete, or_, select, update
from ..user_auth import FirebaseIdentity
from .database import (Database, accounts, blocks, content, devices, friendships, invites,
                       limits, links, media, members, messages, outbox, replays, rides)
from .media import S3Media, reconcile_orphans


class APNs:
    def send(self, binding, kind, event_id):
        import httpx
        import jwt
        # Missing config leaves the event pending instead of claiming delivery.
        token = jwt.encode({"iss": os.environ["BICINO_APNS_TEAM_ID"], "iat": int(time.time())},
            os.environ["BICINO_APNS_PRIVATE_KEY"].replace("\\n", "\n"), algorithm="ES256",
            headers={"kid": os.environ["BICINO_APNS_KEY_ID"]})
        environment = binding["environment"]
        expected = os.environ.get("BICINO_SOCIAL_ENVIRONMENT", "development")
        if environment != expected:
            raise ValueError("APNs environment mismatch")
        host = "api.push.apple.com" if environment == "production" else "api.sandbox.push.apple.com"
        topic = "LetItRide.BikeComputer" if environment == "production" else "LetItRide.BikeComputer.dev"
        copy = "You have a new friend request." if kind == "friend_request" else "You have a ride invitation."
        with httpx.Client(http2=True, timeout=10) as client:
            response = client.post(f"https://{host}/3/device/{binding['token']}",
                headers={"authorization": f"bearer {token}", "apns-topic": topic,
                         "apns-push-type": "alert", "apns-collapse-id": event_id},
                json={"aps": {"alert": {"title": "Bicino", "body": copy}}, "category": kind})
        if response.status_code == 410:
            return False
        response.raise_for_status()
        return True


def cleanup_account(c, actor, identity, media_store):
    account = c.execute(select(accounts).where(accounts.c.id == actor)).mappings().one()
    identity.delete(account["uid"])
    for item in c.execute(select(media).where(media.c.owner == actor)).mappings():
        for variant in item["variants"].values():
            media_store.delete(variant["key"])
    c.execute(delete(media).where(media.c.owner == actor))
    c.execute(delete(links).where(links.c.owner == actor))
    c.execute(delete(content).where(content.c.owner == actor))
    c.execute(delete(friendships).where(or_(friendships.c.a == actor, friendships.c.b == actor)))
    c.execute(delete(blocks).where(or_(blocks.c.owner == actor, blocks.c.target == actor)))
    c.execute(delete(invites).where(or_(invites.c.sender == actor, invites.c.recipient == actor)))
    c.execute(delete(messages).where(messages.c.sender == actor))
    c.execute(delete(replays).where(replays.c.owner == actor))
    # Route snapshots in organized sessions are no longer authorized after deletion.
    c.execute(update(rides).where(rides.c.owner == actor).values(route={}, title="Deleted ride", status="ended"))
    c.execute(update(accounts).where(accounts.c.id == actor).values(uid="deleted:"+actor,
              project="deleted", state="deleted", username=None, name="Deleted rider", privacy={}, avatar=None))


def run_once(database, identity, media_store, notifications, now=None):
    now = time.time() if now is None else now
    # Each event is independently committed. Remote operations are idempotent;
    # a crash between delivery and commit may redeliver the same collapse ID.
    for _ in range(100):
        with database.transaction() as c:
            event = c.execute(select(outbox).where(outbox.c.next_attempt <= now)
                .order_by(outbox.c.created).with_for_update(skip_locked=True).limit(1)).mappings().first()
            if event is None:
                break
            try:
                with c.begin_nested():
                    if event["kind"] == "delete_account":
                        cleanup_account(c, event["owner"], identity, media_store)
                    elif event["kind"] == "delete_media":
                        asset = c.execute(select(media).where(media.c.id == event["body"]["assetID"])).mappings().first()
                        if asset:
                            for variant in asset["variants"].values():
                                media_store.delete(variant["key"])
                            c.execute(delete(media).where(media.c.id == asset["id"]))
                    else:
                        account = c.execute(select(accounts).where(accounts.c.id == event["owner"])).mappings().first()
                        valid = False
                        if event["kind"] == "friend_request":
                            valid = c.scalar(select(friendships.c.id).where(and_(
                                friendships.c.id == event["body"]["requestID"], friendships.c.status == "pending"))) is not None
                        elif event["kind"] == "ride_invite":
                            valid = c.scalar(select(invites.c.id).where(and_(invites.c.ride == event["body"]["rideID"],
                                invites.c.recipient == event["owner"], invites.c.status == "pending", invites.c.expires > now))) is not None
                        category = "friendNotifications" if event["kind"] == "friend_request" else "rideNotifications"
                        if valid and account and account["state"] == "active" and account["privacy"].get("notifications", True) and account["privacy"].get(category, True):
                            for binding in c.execute(select(devices).where(devices.c.owner == event["owner"])).mappings():
                                if not notifications.send(binding, event["kind"], event["id"]):
                                    c.execute(delete(devices).where(devices.c.id == binding["id"]))
                    c.execute(delete(outbox).where(outbox.c.id == event["id"]))
            except Exception:
                __import__("logging").warning("Social outbox retry: kind=%s attempt=%d", event["kind"], event["attempts"]+1)
                # No exception payload: providers can include identifiers/tokens.
                c.execute(update(outbox).where(outbox.c.id == event["id"]).values(
                    attempts=event["attempts"]+1, next_attempt=now+min(3600, 2**min(12, event["attempts"]+4))))
    with database.transaction() as c:
        c.execute(update(members).where(or_(members.c.received < now-60, members.c.lease <= now)).values(live=None, sharing=False, stats=False))
        expired = select(rides.c.id).where(rides.c.expires <= now)
        c.execute(update(members).where(members.c.ride.in_(expired)).values(live=None, sharing=False, stats=False))
        c.execute(update(rides).where(rides.c.expires <= now).values(status="expired", route={}))
        c.execute(delete(messages).where(messages.c.created < now-86400))
        c.execute(delete(links).where(links.c.expires <= now))
        c.execute(delete(invites).where(invites.c.expires < now-30*86400))
        c.execute(delete(replays).where(replays.c.created < now-86400))
        c.execute(delete(limits).where(limits.c.expires < now))


def reconcile_accounts(database, identity, media_store, cursor=""):
    """Bounded external-identity reconciliation; cursor advances across batches."""
    from .service import SocialService
    service = SocialService(database, media_store)
    with database.transaction() as c:
        batch = list(c.execute(select(accounts).where(and_(accounts.c.id > cursor,
            accounts.c.state.in_(["active", "disabled"]))).order_by(accounts.c.id).limit(100)).mappings())
    for account in batch:
        try:
            status = identity.status(account["uid"])
        except Exception:
            continue  # Provider outage is not evidence of account deletion.
        def apply(c):
            database.lock(c, account["id"])
            current = c.execute(select(accounts).where(accounts.c.id == account["id"])).mappings().one()
            if current["state"] not in {"active", "disabled"}:
                return
            if status == "deleted":
                service.begin_deletion(c, account["id"])
            elif status == "disabled":
                c.execute(update(accounts).where(accounts.c.id == account["id"]).values(state="disabled"))
                c.execute(update(members).where(members.c.account == account["id"]).values(live=None, sharing=False, stats=False))
            elif status == "active" and current["state"] == "disabled":
                c.execute(update(accounts).where(accounts.c.id == account["id"]).values(state="active"))
        database.run(apply)
    return batch[-1]["id"] if len(batch) == 100 else ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["migrate", "once", "worker"])
    args = parser.parse_args()
    database = Database(os.environ["BICINO_SOCIAL_DATABASE_URL"])
    if args.command == "migrate":
        database.migrate()
        return
    database.check_schema()
    identity = FirebaseIdentity(os.environ["BICINO_FIREBASE_PROJECT_ID"])
    media_store, notifications = S3Media(), APNs()
    last_reconciled = 0
    last_identity_reconciliation = 0
    identity_cursor = ""
    while True:
        if time.time()-last_reconciled > 3600:
            try:
                reconcile_orphans(database, media_store, time.time())
                last_reconciled = time.time()
            except Exception:
                __import__("logging").warning("Social media reconciliation unavailable")
                last_reconciled = time.time()-3540
        run_once(database, identity, media_store, notifications)
        if time.time()-last_identity_reconciliation >= 60:
            identity_cursor = reconcile_accounts(database, identity, media_store, identity_cursor)
            last_identity_reconciliation = time.time()
        if args.command == "once":
            return
        time.sleep(10)


if __name__ == "__main__":
    main()
