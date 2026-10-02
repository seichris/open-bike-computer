from __future__ import annotations

import json
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from map_platform.admission import AdmissionCapacityError, QueueAdmissionPolicy
from map_platform.jobs import JobStore, MapJobService
from map_platform.models import (
    Bounds,
    GeometryMode,
    JobStatus,
    MapJob,
    NormalizedGeometry,
    SourceRegion,
)
from map_platform.sources import SourceIndex


def source() -> SourceRegion:
    return SourceRegion(
        id="test-region",
        provider="test",
        name="Test Region",
        url="https://example.invalid/test.osm.pbf",
        bounds=Bounds(100.0, 0.0, 110.0, 10.0),
    )


def job(
    job_id: str,
    *,
    cost: int,
    status: JobStatus = JobStatus.QUEUED,
    installation_id: str = "installation_alpha",
    partition: str = "public",
    created_at: str | None = None,
) -> MapJob:
    request = {
        "mode": "custom_bbox",
        "bbox": [103.8, 1.2, 103.9, 1.3],
        "clientInstallationId": installation_id,
        "clientRequestId": f"request_{job_id}",
    }
    return MapJob(
        job_id=job_id,
        status=status,
        request=request,
        geometry=NormalizedGeometry(
            mode=GeometryMode.CUSTOM_BBOX,
            bounds=Bounds(103.8, 1.2, 103.9, 1.3),
            area_km2=100.0,
            vertex_count=4,
        ),
        source_region=source(),
        client_installation_id=installation_id,
        client_request_id=f"request_{job_id}",
        created_at=created_at or datetime.now(timezone.utc).isoformat(),
        admission_cost=cost,
        admission_policy_version="map-cost-v1",
        admission_cost_inputs={"fixture": True},
        admission_partition=partition,
    )


class QueueAdmissionTests(unittest.TestCase):
    def test_development_has_no_cost_or_rolling_budget(self):
        policy = QueueAdmissionPolicy.from_environment("development")
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp, admission_policy=policy)
            service = MapJobService(SourceIndex([source()]), store)
            for index in range(6):
                created = service.create_job({
                    "mode": "custom_bbox",
                    "bbox": [103.8, 1.2, 103.9, 1.3],
                    "clientInstallationId": "installation_alpha",
                    "clientRequestId": f"dev_request_{index}",
                })
                self.assertIsNone(created.admission_cost)
                self.assertEqual(store.queue_position(created.job_id), index + 1)

    def test_production_bounds_pending_work_but_not_completed_history(self):
        policy = QueueAdmissionPolicy(
            max_pending_jobs=4,
            max_pending_per_installation=2,
            operator_reserved_pending_jobs=1,
        )
        own = job("own", cost=999)
        other = job("other", cost=999, installation_id="installation_beta")
        complete = job("complete", cost=999, status=JobStatus.READY)
        policy.validate_create(job("next", cost=999), [own, other, complete])
        with self.assertRaises(AdmissionCapacityError) as raised:
            policy.validate_create(job("own-full", cost=999), [own, job("second-own", cost=999)])
        self.assertEqual(raised.exception.code, "installation_queue_full")
        with self.assertRaises(AdmissionCapacityError) as raised:
            policy.validate_create(
                job("public-full", cost=999, installation_id="installation_gamma"),
                [own, other, job("next", cost=999)],
            )
        self.assertEqual(raised.exception.code, "map_queue_full")
        policy.validate_create(
            job("operator", cost=999, partition="operator"),
            [own, other, job("next", cost=999)],
        )

    def test_one_running_job_and_dynamic_waiting_position(self):
        policy = QueueAdmissionPolicy(0, 0)
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp, admission_policy=policy)
            store.save(job("first", cost=1, created_at="2026-09-27T00:00:00+00:00"))
            store.save(job("second", cost=1, created_at="2026-09-27T00:00:01+00:00"))
            self.assertEqual(store.queue_position("second"), 2)
            self.assertEqual(store.claim_next("worker-one").job_id, "first")
            self.assertEqual(store.queue_position("second"), 1)
            self.assertIsNone(store.claim_next("worker-two"))
            store.update_status("first", JobStatus.READY, worker_id="worker-one", finished=True)
            self.assertEqual(store.claim_next("worker-two").job_id, "second")
            self.assertIsNone(store.queue_position("second"))

    def test_idempotent_creation_uses_one_pending_place(self):
        policy = QueueAdmissionPolicy(2, 1)
        request = {
            "mode": "custom_bbox",
            "bbox": [103.8, 1.2, 103.9, 1.3],
            "clientInstallationId": "installation_alpha",
            "clientRequestId": "request_replayed",
        }
        with tempfile.TemporaryDirectory() as tmp:
            service = MapJobService(
                SourceIndex([source()]), JobStore(tmp, admission_policy=policy)
            )
            with ThreadPoolExecutor(max_workers=6) as executor:
                created = list(executor.map(lambda _: service.create_job(dict(request)), range(6)))
            self.assertEqual(len({entry.job_id for entry in created}), 1)
            with self.assertRaises(AdmissionCapacityError) as raised:
                service.create_job({**request, "clientRequestId": "request_second"})
            self.assertEqual(raised.exception.code, "installation_queue_full")

    def test_corrupt_active_record_fails_closed(self):
        policy = QueueAdmissionPolicy(2, 1)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root, admission_policy=policy)
            service = MapJobService(SourceIndex([source()]), store)
            active = job("active", cost=100)
            store.save(active)
            (root / "active.json").write_text("not json")
            with self.assertRaises(AdmissionCapacityError) as raised:
                service.create_job({
                    "mode": "custom_bbox",
                    "bbox": [103.8, 1.2, 103.9, 1.3],
                    "clientInstallationId": "installation_beta",
                    "clientRequestId": "request_corrupt",
                })
            self.assertEqual(raised.exception.code, "admission_state_unavailable")

    def test_historical_terminal_record_does_not_block_new_queue_entry(self):
        policy = QueueAdmissionPolicy(2, 1)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root, admission_policy=policy)
            store.save(job("old", cost=100, status=JobStatus.READY))
            (root / "old.json").write_text("not json")
            service = MapJobService(SourceIndex([source()]), store)
            created = service.create_job({
                "mode": "custom_bbox",
                "bbox": [103.8, 1.2, 103.9, 1.3],
                "clientInstallationId": "installation_alpha",
                "clientRequestId": "request_new_entry",
            })
            self.assertEqual(created.status, JobStatus.QUEUED)

    def test_historical_cost_metadata_remains_readable(self):
        historical = job("historical", cost=17, status=JobStatus.READY)
        restored = MapJob.from_dict(json.loads(json.dumps(historical.to_dict(include_internal=True))))
        self.assertEqual(restored.admission_cost, 17)
        self.assertNotIn("admission", restored.to_dict())


if __name__ == "__main__":
    unittest.main()
