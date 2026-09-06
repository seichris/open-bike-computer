"""Production-side scheduling only; the existing promotion CLI validates/signs.

No generation code or production credentials are sent to development workers.
The catalog lease is the cross-host concurrency authority; this durable local
queue supplies fairness and retry backoff, not authorization.
"""
from __future__ import annotations

import fcntl
import json
import logging
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import threading
import time
import uuid

from .catalog import CatalogClient

LOG = logging.getLogger(__name__)
MAP_ID = re.compile(r"map_v1_[A-Za-z0-9_-]{43}")
PAGE_SIZE = 50
JOB_TIMEOUT = 1800
MAX_BACKOFF = 21600


def run_promotion(map_id: str) -> None:
    # Never log CLI output: failures may contain credential-bearing download URLs.
    subprocess.run(
        ["map-platform", "promote-catalog-map", map_id],
        check=True, timeout=JOB_TIMEOUT,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


class PromotionQueue:
    def __init__(self, path: Path, catalog: CatalogClient, runner=run_promotion):
        if catalog.channel != "production":
            raise ValueError("automatic promotion requires production catalog credentials")
        self.catalog = catalog
        self.runner = runner
        self.db = sqlite3.connect(path)
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt REAL NOT NULL DEFAULT 0, last_error TEXT);
            CREATE INDEX IF NOT EXISTS jobs_due ON jobs(next_attempt, id);
            CREATE TABLE IF NOT EXISTS scan (singleton INTEGER PRIMARY KEY CHECK(singleton=1), cursor TEXT);
            INSERT OR IGNORE INTO scan VALUES (1, NULL);
        """)

    def close(self):
        self.db.close()

    def discover(self) -> int:
        cursor = self.db.execute("SELECT cursor FROM scan WHERE singleton=1").fetchone()[0]
        page = self.catalog._request(
            "/v1/internal/promotions/candidates", {"cursor": cursor, "limit": PAGE_SIZE},
            idempotency_key=f"auto-promotion:{uuid.uuid4().hex}",
        )
        ids, following = page.get("mapEntryIds"), page.get("nextCursor")
        if (not isinstance(ids, list) or len(ids) > PAGE_SIZE
                or any(not isinstance(x, str) or not MAP_ID.fullmatch(x) for x in ids)
                or ids != sorted(set(ids)) or any(x <= (cursor or "") for x in ids)
                or (following is not None and (len(ids) != PAGE_SIZE or following != ids[-1]))):
            raise ValueError("invalid promotion discovery response")
        with self.db:
            # Rediscovery must not erase failed attempts or their backoff.
            self.db.executemany("INSERT OR IGNORE INTO jobs(id) VALUES (?)", [(x,) for x in ids])
            self.db.execute("UPDATE scan SET cursor=? WHERE singleton=1", (following,))
        return len(ids)

    def process_one(self, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        row = self.db.execute(
            "SELECT id, attempts FROM jobs WHERE next_attempt <= ? ORDER BY next_attempt, id LIMIT 1", (now,),
        ).fetchone()
        if row is None:
            return False
        map_id, previous = row
        attempt = previous + 1
        started = time.monotonic()
        # Reserve before running: restarts cannot create an immediate retry loop.
        with self.db:
            self.db.execute("UPDATE jobs SET attempts=?, next_attempt=? WHERE id=?",
                            (attempt, now + JOB_TIMEOUT + 60, map_id))
        try:
            self.runner(map_id)
        except Exception as error:
            code = "timeout" if isinstance(error, subprocess.TimeoutExpired) else "promotion_failed"
            delay = min(MAX_BACKOFF, 60 * 2 ** min(attempt - 1, 9))
            with self.db:
                self.db.execute("UPDATE jobs SET next_attempt=?, last_error=? WHERE id=?",
                                (now + time.monotonic() - started + delay, code, map_id))
            LOG.warning("promotion_retry map=%s attempt=%d code=%s", map_id, attempt, code)
        else:
            with self.db:
                self.db.execute("DELETE FROM jobs WHERE id=?", (map_id,))
            LOG.info("promotion_complete map=%s attempt=%d", map_id, attempt)
        return True


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    if os.environ.get("MAP_PLATFORM_AUTO_PROMOTION_ENABLED") != "1":
        raise SystemExit("automatic promotion must be explicitly enabled")
    catalog = CatalogClient.from_environment()
    if catalog is None or catalog.channel != "production":
        raise SystemExit("production catalog configuration is required")
    from .map_signing import load_map_artifact_signer_from_environment
    if load_map_artifact_signer_from_environment() is None:
        raise SystemExit("production map signing configuration is required")
    root = Path(os.environ.get("MAP_PLATFORM_DATA_ROOT", "/data")) / "automatic-promotion"
    root.mkdir(parents=True, exist_ok=True)
    stopped = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopped.set())
    # Hold the descriptor throughout execution. Other hosts use catalog leases.
    with (root / "worker.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        queue = PromotionQueue(root / "queue.sqlite3", catalog)
        try:
            while not stopped.is_set():
                try:
                    queue.discover()
                except Exception:
                    LOG.warning("promotion_discovery_failed")
                queue.process_one()
                (root / "heartbeat.json").write_text(json.dumps({"timestamp": time.time()}))
                stopped.wait(30)
        finally:
            queue.close()


if __name__ == "__main__":
    main()
