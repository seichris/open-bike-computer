"""Explicit migrations and retryable social cleanup/notification worker."""
from __future__ import annotations

import argparse
import os
import time
import uuid
from sqlalchemy import and_, delete, or_, select, update
from sqlalchemy.exc import OperationalError
from ..user_auth import FirebaseIdentity
from .features import SocialFeatures
from .database import (Database, accounts, blocks, content, deletion_receipts, devices, exposures,
                       friendships, friend_shares, invites, limits, links, media, members, messages, outbox,
                       replays, rides)
from .media import S3Media, reconcile_orphans

# Long enough for an app to come back online and confirm an accepted deletion.
DELETION_RECEIPT_RETENTION_SECONDS = 30 * 86400


class APNs:
    def __init__(self, *, clock=time.time, client=None):
        self.clock, self.client = clock, client
        self.token, self.issued = None, 0

    def close(self):
        if self.client is not None:
            self.client.close()

    def send(self, binding, kind, event_id):
        import httpx
        import jwt
        # Missing config leaves the event pending instead of claiming delivery.
        if self.token is None or not 0 <= self.clock()-self.issued < 3000:
            self.issued = self.clock()
            self.token = jwt.encode({"iss": os.environ["BICINO_APNS_TEAM_ID"], "iat": int(self.issued)},
                os.environ["BICINO_APNS_PRIVATE_KEY"].replace("\\n", "\n"), algorithm="ES256",
                headers={"kid": os.environ["BICINO_APNS_KEY_ID"]})
        environment = binding["environment"]
        expected = os.environ.get("BICINO_SOCIAL_ENVIRONMENT", "development")
        if environment != expected:
            raise ValueError("APNs environment mismatch")
        host = "api.push.apple.com" if environment == "production" else "api.sandbox.push.apple.com"
        topic = "LetItRide.BikeComputer" if environment == "production" else "LetItRide.BikeComputer.dev"
        copy = "You have a new friend request." if kind == "friend_request" else "You have a ride invitation."
        if self.client is None:
            self.client = httpx.Client(http2=True, timeout=10)
        response = self.client.post(f"https://{host}/3/device/{binding['token']}",
                headers={"authorization": f"bearer {self.token}", "apns-topic": topic,
                         "apns-push-type": "alert", "apns-collapse-id": event_id},
                json={"aps": {"alert": {"title": "Bicino", "body": copy}}, "category": kind})
        if response.status_code == 410:
            return False
        response.raise_for_status()
        return True


def cleanup_account(c, actor, identity, media_store):
    account = c.execute(select(accounts).where(accounts.c.id == actor)).mappings().one()
    if account["state"] == "deleted":
        return
    if account["project"] != identity.project:
        raise ValueError("Firebase project mismatch")
    identity.delete(account["uid"])
    for item in c.execute(select(media).where(media.c.owner == actor)).mappings():
        for variant in item["variants"].values():
            media_store.delete(variant["key"])
    c.execute(delete(media).where(media.c.owner == actor))
    c.execute(delete(links).where(links.c.owner == actor))
    c.execute(delete(content).where(content.c.owner == actor))
    c.execute(delete(friend_shares).where(or_(friend_shares.c.owner == actor, friend_shares.c.recipient == actor)))
    c.execute(delete(friendships).where(or_(friendships.c.a == actor, friendships.c.b == actor)))
    c.execute(delete(blocks).where(or_(blocks.c.owner == actor, blocks.c.target == actor)))
    c.execute(delete(invites).where(or_(invites.c.sender == actor, invites.c.recipient == actor)))
    c.execute(delete(messages).where(messages.c.sender == actor))
    c.execute(delete(replays).where(replays.c.owner == actor))
    # Routes this rider received are no longer relevant. Records of copies that
    # others received from this rider keep restricting their republication.
    # The deletion receipt deliberately survives cleanup for confirmation.
    c.execute(delete(exposures).where(exposures.c.viewer == actor))
    c.execute(delete(devices).where(devices.c.owner == actor))
    # Route snapshots in organized sessions are no longer authorized after deletion.
    c.execute(update(rides).where(rides.c.owner == actor).values(route={}, title="Deleted ride", status="ended"))
    from .service import digest
    c.execute(update(accounts).where(accounts.c.id == actor).values(uid="deleted:"+digest(account["uid"]),
              state="deleted", username=None, name="Deleted rider", privacy={}, avatar=None))


def run_once(database, identity, media_store, notifications, now=None, features=None):
    now = time.time() if now is None else now
    features = features if features is not None else SocialFeatures.from_environment()
    # Each event is independently committed. Remote operations are idempotent;
    # a crash between delivery and commit may redeliver the same collapse ID.
    def process_event(c):
        event = c.execute(select(outbox).where(outbox.c.next_attempt <= now)
            .order_by(outbox.c.created).with_for_update(skip_locked=True).limit(1)).mappings().first()
        if event is None:
            return False
        if event["kind"] == "ride_invite" and not features.document()["groups"]:
            # Keep pending invitations for re-enable, without delaying cleanup.
            c.execute(update(outbox).where(outbox.c.id == event["id"]).values(next_attempt=now+60))
            return True
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
        except Exception as error:
            if isinstance(error, OperationalError) and getattr(error.orig, "sqlstate", None) in {"40001", "40P01"}:
                raise  # A serialization failure invalidates the whole transaction.
            __import__("logging").warning("Social outbox retry: kind=%s attempt=%d", event["kind"], event["attempts"]+1)
            # No exception payload: providers can include identifiers/tokens.
            c.execute(update(outbox).where(outbox.c.id == event["id"]).values(
                attempts=event["attempts"]+1, next_attempt=now+min(3600, 2**min(12, event["attempts"]+4))))
        return True

    for _ in range(100):
        if not database.run(process_event):
            break
    def maintain(c):
        c.execute(update(friend_shares).where(friend_shares.c.received < now-60).values(live=None))
        c.execute(update(friend_shares).where(friend_shares.c.lease <= now).values(live=None, lease=None, stats=False))
        # Coverage gaps hide positions, without silently revoking bounded consent.
        c.execute(update(members).where(and_(members.c.live.is_not(None),
            members.c.received < now-60)).values(live=None))
        active = or_(members.c.sharing.is_(True), members.c.stats.is_(True), members.c.live.is_not(None))
        c.execute(update(members).where(and_(active, members.c.lease <= now))
                  .values(live=None, sharing=False, stats=False))
        expired = select(rides.c.id).where(and_(rides.c.expires <= now, rides.c.status != "expired"))
        for expired_ride in c.execute(select(rides).where(rides.c.id.in_(expired)).with_for_update()).mappings():
            if asset := expired_ride["route"].get("invitePreviewAssetID"):
                c.execute(outbox.insert().values(id=str(uuid.uuid4()), owner=expired_ride["owner"],
                    kind="delete_media", body={"assetID": asset}, created=now, attempts=0, next_attempt=now))
        c.execute(update(members).where(and_(active, members.c.ride.in_(expired)))
                  .values(live=None, sharing=False, stats=False))
        c.execute(update(rides).where(and_(rides.c.expires <= now, rides.c.status != "expired"))
                  .values(status="expired", route={}))
        c.execute(delete(messages).where(messages.c.created < now-86400))
        c.execute(delete(links).where(links.c.expires <= now))
        c.execute(delete(invites).where(invites.c.expires < now-30*86400))
        c.execute(delete(replays).where(replays.c.created < now-86400))
        c.execute(delete(limits).where(limits.c.expires < now))
        c.execute(delete(deletion_receipts).where(deletion_receipts.c.created < now-DELETION_RECEIPT_RETENTION_SECONDS))

    database.run(maintain)

RECONCILE_BATCH_SIZE = 100
# A batch that reports more external deletions than this changes nothing until
# an operator reviews it (see `reconcile-review` and `reconcile-resolve`).
RECONCILE_MAX_UNREVIEWED_DELETIONS = 3


class ReconciliationRefused(ValueError):
    """An operator recovery request that does not match the reviewed batch."""


def _reconciliation_batch(database, identity, cursor, batch_size):
    """The next accounts of the configured project only, with their provider status."""
    with database.transaction() as c:
        batch = list(c.execute(select(accounts).where(and_(accounts.c.id > cursor,
            accounts.c.project == identity.project,
            accounts.c.state.in_(["active", "disabled"]))).order_by(accounts.c.id).limit(batch_size)).mappings())
    checked = []
    for account in batch:
        try:
            status = identity.status(account["uid"])
        except Exception:
            continue  # Provider outage is not evidence of account deletion.
        checked.append((account, status))
    return batch, checked


def _breaker_trips(deleted, checked):
    return (deleted > RECONCILE_MAX_UNREVIEWED_DELETIONS
            or (checked >= 4 and deleted > checked/4))


def _next_cursor(batch, batch_size):
    return batch[-1]["id"] if len(batch) == batch_size else ""


def reconcile_accounts(database, identity, media_store, cursor="", *, batch_size=RECONCILE_BATCH_SIZE):
    """Bounded external-identity reconciliation; cursor advances across batches."""
    from .service import SocialService
    service = SocialService(database, media_store)
    batch, checked = _reconciliation_batch(database, identity, cursor, batch_size)
    missing = sum(status == "deleted" for _, status in checked)
    if _breaker_trips(missing, len(checked)):
        __import__("logging").error("Social identity reconciliation circuit breaker; no accounts changed. "
                                    "Investigate, then run `bicino-social reconcile-review`.")
        return cursor
    _apply_reconciliation(database, identity, service, checked)
    return _next_cursor(batch, batch_size)


def _apply_reconciliation(database, identity, service, checked):
    """Apply only the provider snapshot whose deletion set was just validated."""
    for account, status in checked:
        def apply(c):
            database.lock(c, account["id"])
            current = c.execute(select(accounts).where(accounts.c.id == account["id"])).mappings().one()
            if current["state"] not in {"active", "disabled"} or current["project"] != identity.project:
                return
            if status == "deleted":
                service.begin_deletion(c, account["id"])
            elif status == "disabled":
                c.execute(delete(friend_shares).where(or_(friend_shares.c.owner == account["id"], friend_shares.c.recipient == account["id"])))
                c.execute(update(accounts).where(accounts.c.id == account["id"]).values(state="disabled"))
                c.execute(update(members).where(members.c.account == account["id"]).values(live=None, sharing=False, stats=False))
                c.execute(update(invites).where(and_(invites.c.status == "pending", or_(
                    invites.c.sender == account["id"], invites.c.recipient == account["id"]))).values(status="revoked"))
            elif status == "active" and current["state"] == "disabled":
                c.execute(update(accounts).where(accounts.c.id == account["id"]).values(state="active"))
        database.run(apply)


def review_reconciliation(database, identity, cursor="", *, max_batches=50,
                          batch_size=RECONCILE_BATCH_SIZE):
    """Read-only walk to the first batch the circuit breaker would hold.

    Changes nothing. Reports internal account IDs (never provider UIDs) that the
    provider currently reports deleted in that batch, with the batch cursor an
    operator passes to `resolve_reconciliation` after investigating them.
    """
    for _ in range(max_batches):
        batch, checked = _reconciliation_batch(database, identity, cursor, batch_size)
        deleted = sorted(account["id"] for account, status in checked if status == "deleted")
        if _breaker_trips(len(deleted), len(checked)):
            return {"held": True, "cursor": cursor, "deleted": deleted,
                    "checked": len(checked), "batch": len(batch)}
        cursor = _next_cursor(batch, batch_size)
        if not cursor:
            return {"held": False, "complete": True}
    return {"held": False, "complete": False, "next": cursor}


def resolve_reconciliation(database, identity, media_store, cursor, account_ids, *, confirm=False,
                           batch_size=RECONCILE_BATCH_SIZE):
    """Operator recovery for one held batch after investigation.

    Every deletion the provider reports in the batch at `cursor` must be listed,
    and each listed account must belong to that batch and be confirmed deleted
    again now. Anything else refuses without changes. Without `confirm` this only
    validates. The configured project scope and per-account checks still apply;
    later batches resume normal circuit-breaker protection.
    """
    reviewed = frozenset(account_ids)
    if not reviewed or len(reviewed) != len(account_ids) or len(reviewed) > batch_size:
        raise ReconciliationRefused("list each reviewed account once, at most one batch")
    batch, checked = _reconciliation_batch(database, identity, cursor, batch_size)
    if len(checked) != len(batch):
        raise ReconciliationRefused("provider status is unavailable for part of the held batch")
    members_of_batch = {account["id"] for account in batch}
    if not reviewed <= members_of_batch:
        raise ReconciliationRefused("reviewed accounts are not all in the held batch")
    status = {account["id"]: value for account, value in checked}
    if any(status.get(account) != "deleted" for account in reviewed):
        raise ReconciliationRefused("a reviewed account is not currently reported deleted")
    if {account for account, value in status.items() if value == "deleted"} - reviewed:
        raise ReconciliationRefused("the held batch has deletions that were not reviewed")
    if not confirm:
        return {"applied": False, "cursor": cursor, "reviewed": len(reviewed)}
    from .service import SocialService
    _apply_reconciliation(database, identity, SocialService(database, media_store), checked)
    return {"applied": True, "cursor": _next_cursor(batch, batch_size), "reviewed": len(reviewed)}


def _parser():
    parser = argparse.ArgumentParser(prog="bicino-social")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("migrate", "once", "worker"):
        commands.add_parser(name)
    review = commands.add_parser("reconcile-review", help="Read-only report of a held reconciliation batch")
    review.add_argument("--cursor", default="")
    review.add_argument("--max-batches", type=int, default=50)
    resolve = commands.add_parser("reconcile-resolve", help="Apply one reviewed, held reconciliation batch")
    resolve.add_argument("--cursor", required=True)
    resolve.add_argument("--account", action="append", required=True, dest="accounts")
    resolve.add_argument("--confirm", action="store_true")
    return parser


def main(argv=None):
    import json
    args = _parser().parse_args(argv)
    database = Database(os.environ["BICINO_SOCIAL_DATABASE_URL"])
    if args.command == "migrate":
        database.migrate()
        return
    database.check_schema()
    identity = FirebaseIdentity(os.environ["BICINO_FIREBASE_PROJECT_ID"])
    if args.command == "reconcile-review":
        if not 1 <= args.max_batches <= 1000:
            raise SystemExit("--max-batches must be between 1 and 1000")
        print(json.dumps(review_reconciliation(database, identity, args.cursor, max_batches=args.max_batches)))
        return
    if args.command == "reconcile-resolve":
        try:
            result = resolve_reconciliation(database, identity, S3Media(), args.cursor, args.accounts,
                                            confirm=args.confirm)
        except ReconciliationRefused as error:
            raise SystemExit(f"refused: {error}") from None
        print(json.dumps(result))
        return
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
