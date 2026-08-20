import os
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from map_platform.resource_report import worker_resource_report


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

    def test_invalid_configured_limit_is_reported_as_unset(self):
        with patch.dict(os.environ, {"MAP_PLATFORM_WORKER_MEMORY_LIMIT_BYTES": "nope"}, clear=False):
            report = worker_resource_report(cgroup_root="/missing", proc_root="/missing")
        self.assertIsNone(report["configuredMemoryLimitBytes"])
        self.assertIsNone(report["cgroupMemory"]["version"])

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


if __name__ == "__main__":
    unittest.main()
