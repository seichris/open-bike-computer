from __future__ import annotations

from contextlib import contextmanager
from sqlalchemy import (BigInteger, Boolean, Column, Float, ForeignKey, Integer,
                        JSON, MetaData, String, Table, UniqueConstraint, create_engine,
                        select, text)

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
    Column("created", Float, nullable=False))

members = Table("social_members", metadata,
    Column("ride", String(36), ForeignKey(rides.c.id), primary_key=True),
    Column("account", String(36), ForeignKey(accounts.c.id), primary_key=True),
    Column("status", String(16), nullable=False),
    Column("sharing", Boolean, nullable=False, default=False),
    Column("stats", Boolean, nullable=False, default=False),
    Column("sequence", BigInteger, nullable=False, default=-1),
    Column("live", JSON),
    Column("received", Float),
    Column("lease", Float),
    Column("epoch", String(36), nullable=False))

invites = Table("social_invites", metadata,
    Column("id", String(36), primary_key=True),
    Column("ride", String(36), ForeignKey(rides.c.id), nullable=False),
    Column("sender", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("recipient", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("status", String(16), nullable=False),
    Column("expires", Float, nullable=False),
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

devices = Table("social_notification_devices", metadata,
    Column("id", String(36), primary_key=True),
    Column("owner", String(36), ForeignKey(accounts.c.id), nullable=False),
    Column("token", String(256), unique=True, nullable=False),
    Column("environment", String(16), nullable=False))

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
                connection.execute(versions.insert().values(version=1))
            elif current != 1:
                raise ValueError("Unsupported social schema")

    def check_schema(self):
        with self.engine.connect() as c:
            if c.scalar(select(versions.c.version)) != 1:
                raise ValueError("Run social migration before enabling the service")

    @contextmanager
    def transaction(self):
        with self.engine.begin() as c:
            yield c

    def run(self, callback):
        import time
        from sqlalchemy.exc import OperationalError
        for attempt in range(5):
            try:
                with self.transaction() as c:
                    return callback(c)
            except OperationalError as error:
                if getattr(error.orig, "sqlstate", None) not in {"40001", "40P01"} or attempt == 4:
                    raise
                time.sleep(0.02 * (attempt + 1))

    @staticmethod
    def lock(c, *ids):
        # Deterministic ordering prevents pair-operation deadlocks.
        list(c.execute(select(accounts.c.id).where(accounts.c.id.in_(sorted(set(ids))))
                       .order_by(accounts.c.id).with_for_update()))
