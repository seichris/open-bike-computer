import os
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from map_platform.resource_report import (
    WorkerCapabilityError,
    validate_worker_capability,
    worker_capability_snapshot,
    worker_resource_report,
)


class ResourceReportTests(unittest.TestCase):
    def test_reads_cgroup_v2_and_proc_memory_without_mutating_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "memory.max").write_text("max")
            (root / "memory.current").write_text("1234")
            (root / "memory.peak").write_text("5678")
            proc = root / "proc"
            (proc / "self").mkdir(parents=True)
            (proc / "self" / "status").write_text("VmRSS: 12 kB\nVmHWM: 34 kB\n")
            (proc / "meminfo").write_text("MemTotal: 100 kB\nMemAvailable: 40 kB\n")
            with patch.dict(os.environ, {"MAP_PLATFORM_WORKER_MEMORY_LIMIT_BYTES": "8192"}, clear=False):
                report = worker_resource_report(cgroup_root=root, proc_root=proc)
        self.assertEqual(report["cgroupMemory"]["version"], 2)
        self.assertIsNone(report["cgroupMemory"]["limitBytes"])
        self.assertEqual(report["cgroupMemory"]["currentBytes"], 1234)
        self.assertEqual(report["cgroupMemory"]["peakBytes"], 5678)
        self.assertEqual(report["cgroupMemory"]["configuredLimitBytes"], 8192)
        self.assertEqual(report["processMemory"]["rssBytes"], 12 * 1024)
        self.assertEqual(report["processMemory"]["peakRssBytes"], 34 * 1024)
        self.assertEqual(report["hostMemory"]["totalBytes"], 100 * 1024)
        capability = report["capability"]
        self.assertEqual(capability["memoryLimitBytes"], 8192)
        self.assertEqual(capability["cgroupMemoryLimitBytes"], None)
        self.assertEqual(capability["maxConcurrentTasks"], 1)
        expected_identity = hashlib.sha256(
            json.dumps(
                {
                    key: capability[key]
                    for key in capability
                    if key != "identitySha256"
                },
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
        ).hexdigest()
        self.assertEqual(capability["identitySha256"], expected_identity)

    def test_invalid_configured_limit_fails_closed(self):
        with patch.dict(os.environ, {"MAP_PLATFORM_WORKER_MEMORY_LIMIT_BYTES": "nope"}, clear=False):
            with self.assertRaisesRegex(
                WorkerCapabilityError,
                "MEMORY_LIMIT_BYTES must be a positive integer",
            ):
                worker_resource_report(cgroup_root="/missing", proc_root="/missing")

    def test_executable_capability_rejects_missing_limit_and_identity_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "memory.max").write_text("8192")
            report = worker_resource_report(
                cgroup_root=root,
                proc_root=root / "missing-proc",
            )
        capability = report["capability"]
        self.assertEqual(
            validate_worker_capability(capability)["memoryLimitBytes"],
            8192,
        )
        with self.assertRaisesRegex(WorkerCapabilityError, "memoryLimitBytes"):
            validate_worker_capability({**capability, "memoryLimitBytes": None})
        with self.assertRaisesRegex(WorkerCapabilityError, "identity"):
            validate_worker_capability({**capability, "resourcePool": "other"})

    def test_effective_memory_limit_uses_smaller_configured_or_cgroup_cap(self):
        cases = (
            (8_192, 4_096, 4_096),
            (4_096, 8_192, 4_096),
        )
        for configured, cgroup_limit, expected in cases:
            with self.subTest(
                configured=configured,
                cgroup_limit=cgroup_limit,
            ), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "memory.max").write_text(str(cgroup_limit))
                with patch.dict(
                    os.environ,
                    {"MAP_PLATFORM_WORKER_MEMORY_LIMIT_BYTES": str(configured)},
                    clear=False,
                ):
                    report = worker_resource_report(
                        cgroup_root=root,
                        proc_root=root / "missing-proc",
                    )

            capability = report["capability"]
            self.assertEqual(capability["memoryLimitBytes"], expected)
            self.assertEqual(
                capability["configuredMemoryLimitBytes"], configured
            )
            self.assertEqual(capability["cgroupMemoryLimitBytes"], cgroup_limit)

    def test_cgroup_v1_unlimited_sentinel_cannot_claim_a_memory_limit(self):
        for sentinel in (9223372036854771712, 9223372036854775807):
            with self.subTest(
                sentinel=sentinel
            ), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                memory = root / "memory"
                memory.mkdir()
                (memory / "memory.limit_in_bytes").write_text(str(sentinel))
                with patch.dict(os.environ, {}, clear=True):
                    report = worker_resource_report(
                        cgroup_root=root,
                        proc_root=root / "missing-proc",
                    )

                self.assertEqual(report["cgroupMemory"]["version"], 1)
                self.assertIsNone(report["cgroupMemory"]["limitBytes"])
                capability = report["capability"]
                self.assertIsNone(capability["cgroupMemoryLimitBytes"])
                self.assertIsNone(capability["memoryLimitBytes"])
                with self.assertRaisesRegex(
                    WorkerCapabilityError,
                    "memoryLimitBytes",
                ):
                    validate_worker_capability(capability)
                with patch(
                    "map_platform.resource_report.worker_resource_report",
                    return_value=report,
                ), self.assertRaisesRegex(
                    WorkerCapabilityError,
                    "memoryLimitBytes",
                ):
                    worker_capability_snapshot()

    def test_cgroup_v1_unlimited_uses_real_configured_cap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            memory = root / "memory"
            memory.mkdir()
            (memory / "memory.limit_in_bytes").write_text(
                "9223372036854771712"
            )
            configured = 12 * 1024**3
            with patch.dict(
                os.environ,
                {"MAP_PLATFORM_WORKER_MEMORY_LIMIT_BYTES": str(configured)},
                clear=True,
            ):
                report = worker_resource_report(
                    cgroup_root=root,
                    proc_root=root / "missing-proc",
                )

        capability = validate_worker_capability(report["capability"])
        self.assertIsNone(capability["cgroupMemoryLimitBytes"])
        self.assertEqual(capability["configuredMemoryLimitBytes"], configured)
        self.assertEqual(capability["memoryLimitBytes"], configured)

    def test_cgroup_v1_large_finite_limit_remains_a_real_cap(self):
        finite_limit = 8 * 1024**4
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            memory = root / "memory"
            memory.mkdir()
            (memory / "memory.limit_in_bytes").write_text(str(finite_limit))
            with patch.dict(os.environ, {}, clear=True):
                report = worker_resource_report(
                    cgroup_root=root,
                    proc_root=root / "missing-proc",
                )

        capability = validate_worker_capability(report["capability"])
        self.assertEqual(report["cgroupMemory"]["limitBytes"], finite_limit)
        self.assertEqual(capability["cgroupMemoryLimitBytes"], finite_limit)
        self.assertEqual(capability["memoryLimitBytes"], finite_limit)


if __name__ == "__main__":
    unittest.main()
