from __future__ import annotations

import time
from contextlib import contextmanager
from sqlalchemy import (BigInteger, Boolean, Column, Float, ForeignKey, Integer,
                        JSON, MetaData, String, Table, UniqueConstraint, and_, create_engine,
                        delete, inspect, null, or_, select, text, update)
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

SCHEMA_VERSION = 4
RETRYABLE_SQLSTATES = frozenset({"40001", "40P01"})

metadata = MetaData()

accounts = Table("social_accounts", metadata,
    Column("id", String(36), primary_key=True),
    Column("project", String(128), nullable=False),
    Column("uid", String(128), nullable=False),
    Column("username", String(32), unique=True),
    Column("name", String(80), nullable=False),
    Column("state", String(16), nullable=False, default="active"),
    Column("version", Integer, nullable=False, default=1),
    Column("avatar", String(36)),
    Column("privacy", JSON, nullable=False, default=dict),
    Column("created", Float, nullable=False),
    UniqueConstraint("project", "uid"))

friendships = Table("social_friendships", metadata,
    Column("id", String(36), primary_key=True),
    Column("a", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("b", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("sender", String(36), nullable=False),
    Column("status", String(16), nullable=False),
    Column("updated", Float, nullable=False),
    UniqueConstraint("a", "b"))

blocks = Table("social_blocks", metadata,
    Column("owner", String(36), ForeignKey(accounts.c.id), primary_key=True),
    Column("target", String(36), ForeignKey(accounts.c.id), primary_key=True))

content = Table("social_content", metadata,
    Column("id", String(36), primary_key=True),
    Column("owner", String(36), ForeignKey(accounts.c.id), nullable=False, index=True),
    Column("kind", String(16), nullable=False),
    Column("title", String(160), nullable=False),
    Column("visibility", String(16), nullable=False),
    Column("revision", Integer, nullable=False),
    Column("body", JSON, nullable=False),
    Column("source", String(128)),
    Column("created", Float, nullable=False),
    # Direction-insensitive route geometry digest; activities have none.
    Column("fingerprint", String(64), index=True),
    UniqueConstraint("owner", "kind", "source"))

links = Table("social_links", metadata,
    Column("id", String(36), primary_key=True),
    Column("owner", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("content", String(36), ForeignKey(content.c.id), nullable=False),
    Column("digest", String(64), unique=True, nullable=False),
    Column("expires", Float, nullable=False))

media = Table("social_media", metadata,
    Column("id", String(36), primary_key=True),
    Column("owner", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("variants", JSON, nullable=False),
    Column("created", Float, nullable=False))

rides = Table("social_rides", metadata,
    Column("id", String(36), primary_key=True),
    Column("owner", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("title", String(160), nullable=False),
    Column("route", JSON, nullable=False),
    Column("status", String(16), nullable=False),
    Column("starts", Float),
    Column("expires", Float, nullable=False),
    Column("code", String(64), unique=True, nullable=False),
    Column("created", Float, nullable=False),
    Column("fingerprint", String(64)))

members = Table("social_members", metadata,
    Column("ride", String(36), ForeignKey(rides.c.id), primary_key=True),
    Column("account", String(36), ForeignKey(accounts.c.id), primary_key=True),
    Column("status", String(16), nullable=False),
    Column("sharing", Boolean, nullable=False, default=False),
    Column("stats", Boolean, nullable=False, default=False),
    Column("sequence", BigInteger, nullable=False, default=-1),
    Column("live", JSON(none_as_null=True)),
    Column("received", Float),
    Column("lease", Float),
    Column("epoch", String(36), nullable=False))

# Directional, bounded consent: Alice enabling Bob never enables Bob -> Alice.
# Epochs fence stale publishers and every consent change clears the last fix.
friend_shares = Table("social_friend_shares", metadata,
    Column("owner", String(36), ForeignKey(accounts.c.id), primary_key=True),
    Column("recipient", String(36), ForeignKey(accounts.c.id), primary_key=True, index=True),
    Column("epoch", String(36), nullable=False),
    Column("lease", Float),
    Column("stats", Boolean, nullable=False, default=False),
    Column("sequence", BigInteger, nullable=False, default=-1),
    Column("live", JSON(none_as_null=True)),
    Column("received", Float))

invites = Table("social_invites", metadata,
    Column("id", String(36), primary_key=True),
    Column("ride", String(36), ForeignKey(rides.c.id), nullable=False),
    Column("sender", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("recipient", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("status", String(16), nullable=False),
    Column("expires", Float, nullable=False),
    # Last time this recipient was alerted for this room; bounds repeated pushes.
    Column("notified", Float),
    UniqueConstraint("ride", "recipient"))

messages = Table("social_messages", metadata,
    Column("id", String(36), primary_key=True),
    Column("ride", String(36), ForeignKey(rides.c.id), nullable=False, index=True),
    Column("sender", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("status", String(32), nullable=False),
    Column("created", Float, nullable=False))

outbox = Table("social_outbox", metadata,
    Column("id", String(36), primary_key=True),
    Column("owner", String(36), nullable=False, index=True),
    Column("kind", String(32), nullable=False),
    Column("body", JSON, nullable=False),
    Column("created", Float, nullable=False),
    Column("attempts", Integer, nullable=False, default=0),
    Column("next_attempt", Float, nullable=False, default=0))

# One row per app installation. The id is the installation identifier and
# secret_digest is SHA-256 of an installation secret that only the app keeps.
devices = Table("social_notification_devices", metadata,
    Column("id", String(36), primary_key=True),
    Column("owner", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("token", String(256), unique=True, nullable=False),
    Column("environment", String(16), nullable=False),
    Column("secret_digest", String(64), nullable=False))

# Route geometry another account received from Bicino (friend view, link,
# preview or membership). It cannot be republished by that viewer.
exposures = Table("social_route_exposures", metadata,
    Column("viewer", String(36), ForeignKey(accounts.c.id), primary_key=True),
    Column("fingerprint", String(64), primary_key=True),
    Column("owner", String(36), ForeignKey(accounts.c.id), primary_key=True),
    Column("created", Float, nullable=False))

# Digest of a client-held deletion receipt. Lets the app confirm an accepted
# deletion after lost responses, restart or identity cleanup without signing in.
deletion_receipts = Table("social_deletion_receipts", metadata,
    Column("digest", String(64), primary_key=True),
    Column("account", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("created", Float, nullable=False))

limits = Table("social_limits", metadata,
    Column("key", String(180), primary_key=True),
    Column("window", BigInteger, primary_key=True),
    Column("count", Integer, nullable=False),
    Column("expires", Float, nullable=False))

replays = Table("social_replays", metadata,
    Column("owner", String(36), primary_key=True),
    Column("key", String(128), primary_key=True),
    Column("digest", String(64), nullable=False),
    Column("response", JSON, nullable=False),
    Column("created", Float, nullable=False))

versions = Table("social_schema", metadata, Column("version", Integer, primary_key=True))


class Database:
    def __init__(self, url: str, *, testing: bool = False):
        if not testing and not url.startswith("postgresql+psycopg://"):
            raise ValueError("Social storage requires PostgreSQL with psycopg")
        kwargs = {"pool_pre_ping": True}
        if url.startswith("postgresql"):
            kwargs["isolation_level"] = "SERIALIZABLE"
        if testing and url == "sqlite://":
            from sqlalchemy.pool import StaticPool
            kwargs.update(poolclass=StaticPool, connect_args={"check_same_thread": False})
        self.engine = create_engine(url, **kwargs)

    def migrate(self):
        # Explicit operator command, never implicit DDL in a request/startup.
        with self.engine.begin() as connection:
            if connection.dialect.name == "postgresql":
                connection.execute(text("SELECT pg_advisory_xact_lock(380001)"))
            metadata.create_all(connection)
            current = connection.scalar(select(versions.c.version))
            if current is None:
                connection.execute(versions.insert().values(version=SCHEMA_VERSION))
                return
            if current == 1:
                _retire_v1(connection)
                current = 2
            if current == 2:
                _upgrade_v2(connection, time.time())
                current = 3
            if current == 3:
                # create_all above adds the empty table. Never infer consent from
                # existing friendships or Group Ride membership.
                current = 4
            if current != SCHEMA_VERSION:
                raise ValueError("Unsupported social schema")
            connection.execute(update(versions).values(version=SCHEMA_VERSION))

    def check_schema(self):
        with self.engine.connect() as c:
            if c.scalar(select(versions.c.version)) != SCHEMA_VERSION:
                raise ValueError("Run social migration before enabling the service")

    @contextmanager
    def transaction(self):
        with self.engine.begin() as c:
            yield c

    def run(self, callback, *, attempts: int = 5):
        """Run a complete transaction, retrying serialization and deadlock aborts."""
        from sqlalchemy.exc import OperationalError
        for attempt in range(attempts):
            try:
                with self.transaction() as c:
                    return callback(c)
            except OperationalError as error:
                if getattr(error.orig, "sqlstate", None) not in RETRYABLE_SQLSTATES or attempt == attempts-1:
                    raise
                time.sleep(0.02 * (attempt + 1))

    @staticmethod
    def lock(c, *ids):
        # Deterministic ordering prevents pair-operation deadlocks.
        list(c.execute(select(accounts.c.id).where(accounts.c.id.in_(sorted(set(ids))))
                       .order_by(accounts.c.id).with_for_update()))


def insert_ignore(c, table, rows, keys):
    """Insert rows whose primary key may already exist, without failing the transaction."""
    if not rows:
        return
    statement = (pg_insert if c.dialect.name == "postgresql" else sqlite_insert)(table).values(rows)
    c.execute(statement.on_conflict_do_nothing(index_elements=keys))


def _retire_v1(connection):
    # Old replay payloads contain capabilities and route snapshots.
    # Retire those receipts before serving the upgraded API.
    connection.execute(delete(replays))
    # V1 snapshots lack source ownership provenance. Retire those
    # development rooms instead of keeping potentially redistributed
    # routes or resuming old consent under the new lease contract.
    connection.execute(update(rides).values(status="ended", route={}))
    connection.execute(update(members).values(live=null(), sharing=False, stats=False, status="left"))
    connection.execute(update(invites).values(status="revoked"))


def _add_column(connection, table, name, ddl):
    if name not in {column["name"] for column in inspect(connection).get_columns(table)}:
        connection.execute(text(f"ALTER TABLE {table} ADD COLUMN {name} {ddl}"))


def _upgrade_v2(connection, now):
    from .route_archive import archive_fingerprint
    postgresql = connection.dialect.name == "postgresql"
    _add_column(connection, "social_notification_devices", "secret_digest", "VARCHAR(64)")
    _add_column(connection, "social_content", "fingerprint", "VARCHAR(64)")
    _add_column(connection, "social_rides", "fingerprint", "VARCHAR(64)")
    _add_column(connection, "social_invites", "notified", "DOUBLE PRECISION" if postgresql else "FLOAT")
    # V2 bindings never proved possession of an installation secret, so a stale
    # or squatted row cannot be safely handed off. Retire them; the app binds its
    # installation again with a proof on its next launch or sign-in.
    connection.execute(delete(devices).where(devices.c.secret_digest.is_(None)))
    if postgresql:
        connection.execute(text("ALTER TABLE social_notification_devices ALTER COLUMN secret_digest SET NOT NULL"))
    connection.execute(text("CREATE INDEX IF NOT EXISTS ix_social_content_fingerprint ON social_content (fingerprint)"))
    # Existing pending invitations were already alerted once.
    connection.execute(update(invites).where(and_(invites.c.status == "pending", invites.c.notified.is_(None)))
                       .values(notified=now))
    for item in connection.execute(select(content.c.id, content.c.body).where(and_(
            content.c.kind == "route", content.c.fingerprint.is_(None)))).mappings().all():
        fingerprint = archive_fingerprint(item["body"])
        if fingerprint:
            connection.execute(update(content).where(content.c.id == item["id"]).values(fingerprint=fingerprint))
    for ride in connection.execute(select(rides.c.id, rides.c.route).where(rides.c.fingerprint.is_(None))).mappings().all():
        fingerprint = archive_fingerprint(ride["route"])
        if fingerprint:
            connection.execute(update(rides).where(rides.c.id == ride["id"]).values(fingerprint=fingerprint))
    # Exposure tracking is new. Conservatively record every account that could
    # already have received a route: accepted friends of friends-visible routes,
    # and members or invitees of rooms that still hold a snapshot.
    rows = {}
    def exposed(viewer, fingerprint, owner):
        if viewer != owner:
            rows[(viewer, fingerprint, owner)] = {"viewer": viewer, "fingerprint": fingerprint,
                                                  "owner": owner, "created": now}
    for owner, fingerprint in connection.execute(select(content.c.owner, content.c.fingerprint).where(and_(
            content.c.kind == "route", content.c.visibility == "friends", content.c.fingerprint.is_not(None)))).all():
        for a, b in connection.execute(select(friendships.c.a, friendships.c.b).where(and_(
                friendships.c.status == "accepted", or_(friendships.c.a == owner, friendships.c.b == owner)))).all():
            exposed(b if a == owner else a, fingerprint, owner)
    for ride_id, owner, fingerprint in connection.execute(select(rides.c.id, rides.c.owner, rides.c.fingerprint)
                                                          .where(rides.c.fingerprint.is_not(None))).all():
        for viewer in connection.scalars(select(members.c.account).where(members.c.ride == ride_id)).all():
            exposed(viewer, fingerprint, owner)
        for viewer in connection.scalars(select(invites.c.recipient).where(invites.c.ride == ride_id)).all():
            exposed(viewer, fingerprint, owner)
    insert_ignore(connection, exposures, list(rows.values()), ["viewer", "fingerprint", "owner"])
