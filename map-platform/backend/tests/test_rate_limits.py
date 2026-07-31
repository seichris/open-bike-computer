import sqlite3
import tempfile
import unittest
from pathlib import Path

from map_platform.rate_limits import (
    ClientAddressResolver,
    PersistentRateLimiter,
    RateLimitExceeded,
    RateLimitPolicy,
    purge_expired_rate_limits,
)


class PersistentRateLimiterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "rate-limits.sqlite3"
        self.now = 1_700_000_020
        self.limiter = PersistentRateLimiter(
            self.path,
            "test-rate-limit-secret-at-least-32-bytes",
            clock=lambda: self.now,
        )

    def tearDown(self):
        self.tmp.cleanup()

    def test_limit_is_persistent_and_raw_subject_is_not_stored(self):
        policy = RateLimitPolicy("map-create-ip", 2, 60)
        self.limiter.consume(policy, "203.0.113.8")
        restarted = PersistentRateLimiter(
            self.path,
            "test-rate-limit-secret-at-least-32-bytes",
            clock=lambda: self.now,
        )
        restarted.consume(policy, "203.0.113.8")
        with self.assertRaises(RateLimitExceeded) as context:
            restarted.consume(policy, "203.0.113.8")
        self.assertEqual(context.exception.retry_after_seconds, 20)

        with sqlite3.connect(self.path) as connection:
            stored = connection.execute(
                "SELECT subject_hash FROM rate_limits"
            ).fetchone()[0]
        self.assertNotIn("203.0.113.8", stored)
        self.assertEqual(len(stored), 64)

    def test_multi_limit_check_is_atomic_when_one_rule_is_exhausted(self):
        first = RateLimitPolicy("installation", 2, 60)
        blocked = RateLimitPolicy("ip", 1, 60)
        self.limiter.consume(blocked, "203.0.113.9")
        with self.assertRaises(RateLimitExceeded):
            self.limiter.consume_many(
                ((first, "installation-a"), (blocked, "203.0.113.9"))
            )

        self.limiter.consume(first, "installation-a")
        self.limiter.consume(first, "installation-a")
        with self.assertRaises(RateLimitExceeded):
            self.limiter.consume(first, "installation-a")

    def test_scheduled_cleanup_removes_expired_rows_without_later_traffic(self):
        policy = RateLimitPolicy("daily-ip", 3, 86_400)
        self.limiter.consume(policy, "203.0.113.10")
        self.now += 172_800

        with sqlite3.connect(self.path) as connection:
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM rate_limits").fetchone()[0],
                1,
            )

        self.assertEqual(purge_expired_rate_limits(self.path, now=self.now), 1)
        with sqlite3.connect(self.path) as connection:
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM rate_limits").fetchone()[0],
                0,
            )

    def test_startup_purges_expired_rows_and_missing_database_is_safe(self):
        policy = RateLimitPolicy("daily-ip", 3, 86_400)
        self.limiter.consume(policy, "203.0.113.11")
        self.now += 172_800

        PersistentRateLimiter(
            self.path,
            "test-rate-limit-secret-at-least-32-bytes",
            clock=lambda: self.now,
        )
        with sqlite3.connect(self.path) as connection:
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM rate_limits").fetchone()[0],
                0,
            )
        self.assertEqual(
            purge_expired_rate_limits(Path(self.tmp.name) / "missing.sqlite3"),
            0,
        )


class ClientAddressResolverTests(unittest.TestCase):
    def test_forwarded_header_is_ignored_from_untrusted_peer(self):
        resolver = ClientAddressResolver(["10.0.0.0/8"])
        self.assertEqual(
            resolver.resolve("198.51.100.20", "203.0.113.8"),
            "198.51.100.20",
        )

    def test_rightmost_untrusted_address_wins_through_trusted_proxies(self):
        resolver = ClientAddressResolver(["10.0.0.0/8", "192.168.0.0/16"])
        self.assertEqual(
            resolver.resolve(
                "10.0.0.4",
                "198.51.100.99, 203.0.113.8, 192.168.4.2",
            ),
            "203.0.113.8",
        )

    def test_invalid_forwarded_chain_fails_closed_to_peer(self):
        resolver = ClientAddressResolver(["10.0.0.0/8"])
        self.assertEqual(
            resolver.resolve("10.0.0.4", "spoofed, 203.0.113.8"),
            "10.0.0.4",
        )

    def test_ipv6_privacy_addresses_share_a_64_bit_subject(self):
        resolver = ClientAddressResolver()
        first = resolver.resolve("2001:db8:1234:5678::1", None)
        rotated = resolver.resolve("2001:db8:1234:5678:ffff::2", None)
        mapped = resolver.resolve("::ffff:203.0.113.8", None)

        self.assertEqual(first, "2001:db8:1234:5678::/64")
        self.assertEqual(rotated, first)
        self.assertEqual(mapped, "203.0.113.8")


if __name__ == "__main__":
    unittest.main()
