from pathlib import Path
import tempfile
import unittest

from map_platform.building_operations import building_plan_alerts
from map_platform.building_tasks import BuildingTaskSpec, BuildingTaskStore


class Clock:
    def __init__(self):
        self.value = 100.0

    def __call__(self):
        return self.value


class BuildingOperationsTests(unittest.TestCase):
    def test_alerts_are_read_only_and_cover_lease_memory_and_failure_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            clock = Clock()
            store = BuildingTaskStore(Path(directory) / "tasks.sqlite3", clock=clock)
            store.create_plan(
                parent_job_id="job-alerts",
                global_plan_sha256="a" * 64,
                input_identity={},
                expected_output_block_count=1,
                policy_version=1,
                resource_model_version="v1",
            )
            store.add_tasks(
                [
                    BuildingTaskSpec(
                        task_id="task-alerts",
                        parent_job_id="job-alerts",
                        kind="building_chunk",
                        blocks=((1, 1),),
                        chunk_plan_sha256="a" * 64,
                        predicted_resource={"estimatedPeakMemoryBytes": 80},
                    )
                ]
            )
            claimed = store.claim_next(
                worker_id="worker-a",
                lease_seconds=10,
                worker_capability={
                    "memoryLimitBytes": 100,
                    "cpuCount": 1,
                    "resourcePool": "test",
                    "maxConcurrentTasks": 1,
                },
            )
            self.assertIsNotNone(claimed)
            assert claimed is not None
            clock.value = 200.0
            report = building_plan_alerts(store, "job-alerts", now=clock.value)
            codes = {alert["code"] for alert in report["alerts"]}
            self.assertIn("stale_lease", codes)
            self.assertIn("stale_heartbeat", codes)
            self.assertEqual(store.get_task("task-alerts").state, "leased")

            reclaimed = store.claim_next(
                worker_id="worker-a",
                lease_seconds=10,
                worker_capability={
                    "memoryLimitBytes": 100,
                    "cpuCount": 1,
                    "resourcePool": "test",
                    "maxConcurrentTasks": 1,
                },
            )
            assert reclaimed is not None
            store.fail(
                "task-alerts",
                worker_id="worker-a",
                lease_token=reclaimed.lease_token,
                typed_failure="building_worker_oom",
                transient=False,
                now=clock.value,
            )
            store.set_plan_stage("job-alerts", stage="failed", state="failed", now=clock.value)
            report = building_plan_alerts(store, "job-alerts", now=clock.value)
            codes = {alert["code"] for alert in report["alerts"]}
            self.assertIn("plan_failed", codes)
            self.assertIn("task_failed", codes)
            self.assertIn("worker_oom", codes)

    def test_memory_headroom_alert_uses_attempt_capability(self):
        with tempfile.TemporaryDirectory() as directory:
            store = BuildingTaskStore(Path(directory) / "tasks.sqlite3")
            store.create_plan(
                parent_job_id="job-memory",
                global_plan_sha256="a" * 64,
                input_identity={},
                expected_output_block_count=1,
                policy_version=1,
                resource_model_version="v1",
            )
            store.add_tasks(
                [
                    BuildingTaskSpec(
                        task_id="task-memory",
                        parent_job_id="job-memory",
                        kind="building_chunk",
                        blocks=((1, 1),),
                        chunk_plan_sha256="a" * 64,
                        predicted_resource={"estimatedPeakMemoryBytes": 80},
                    )
                ]
            )
            claimed = store.claim_next(
                worker_id="worker-a",
                worker_capability={
                    "memoryLimitBytes": 100,
                    "cpuCount": 1,
                    "resourcePool": "test",
                    "maxConcurrentTasks": 1,
                },
            )
            assert claimed is not None
            store.publish_receipt(
                "task-memory",
                worker_id="worker-a",
                lease_token=claimed.lease_token,
                block=(1, 1),
                cache_identity_sha256="a" * 64,
                content_sha256="b" * 64,
                producer_identity={},
                validation={},
            )
            store.mark_ready(
                "task-memory",
                worker_id="worker-a",
                lease_token=claimed.lease_token,
                peak_rss_bytes=90,
            )
            report = building_plan_alerts(store, "job-memory")
            alert = next(item for item in report["alerts"] if item["code"] == "memory_headroom")
            self.assertEqual(alert["detail"]["memoryLimitBytes"], 100)
            self.assertEqual(alert["severity"], "warning")

    def test_memory_headroom_alert_uses_smallest_effective_cap(self):
        with tempfile.TemporaryDirectory() as directory:
            store = BuildingTaskStore(Path(directory) / "tasks.sqlite3")
            store.create_plan(
                parent_job_id="job-memory-cap",
                global_plan_sha256="a" * 64,
                input_identity={},
                expected_output_block_count=1,
                policy_version=1,
                resource_model_version="v1",
            )
            store.add_tasks(
                [
                    BuildingTaskSpec(
                        task_id="task-memory-cap",
                        parent_job_id="job-memory-cap",
                        kind="building_chunk",
                        blocks=((1, 1),),
                        chunk_plan_sha256="a" * 64,
                        predicted_resource={"estimatedPeakMemoryBytes": 80},
                    )
                ]
            )
            claimed = store.claim_next(
                worker_id="worker-a",
                worker_capability={
                    "memoryLimitBytes": 12_000,
                    "configuredMemoryLimitBytes": 12_000,
                    "cgroupMemoryLimitBytes": 4_000,
                    "cpuCount": 1,
                    "resourcePool": "test",
                    "maxConcurrentTasks": 1,
                },
            )
            assert claimed is not None
            store.publish_receipt(
                "task-memory-cap",
                worker_id="worker-a",
                lease_token=claimed.lease_token,
                block=(1, 1),
                cache_identity_sha256="a" * 64,
                content_sha256="b" * 64,
                producer_identity={},
                validation={},
            )
            store.mark_ready(
                "task-memory-cap",
                worker_id="worker-a",
                lease_token=claimed.lease_token,
                peak_rss_bytes=3_600,
            )

            report = building_plan_alerts(store, "job-memory-cap")
            alert = next(
                item for item in report["alerts"] if item["code"] == "memory_headroom"
            )
            self.assertEqual(alert["detail"]["memoryLimitBytes"], 4_000)
            self.assertEqual(alert["severity"], "warning")


if __name__ == "__main__":
    unittest.main()
