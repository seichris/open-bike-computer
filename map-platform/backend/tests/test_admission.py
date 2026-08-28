from __future__ import annotations

import json
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

from map_platform.admission import AdmissionCapacityError, AdmissionPolicy
from map_platform.jobs import JobClaimError, JobStore, MapJobService
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


class AdmissionPolicyTests(unittest.TestCase):
    def test_estimate_is_deterministic_and_weights_building_renderer(self):
        policy = AdmissionPolicy()
        geometry = job("estimate", cost=1).geometry
        legacy = policy.estimate({}, geometry, source())
        buildings = policy.estimate(
            {"target": {"rendererFormatVersion": 3}},
            geometry,
            source(),
        )

        self.assertEqual(legacy, policy.estimate({}, geometry, source()))
        self.assertGreater(buildings.units, legacy.units)
        self.assertEqual(buildings.inputs["rendererWeight"], 4)

    def test_public_capacity_cannot_consume_operator_reserve(self):
        policy = AdmissionPolicy(
            max_queued_cost=100,
            max_running_cost=50,
            operator_reserved_queued_cost=20,
            operator_reserved_running_cost=10,
            max_installation_cost_per_window=1_000,
        )
        existing = job("existing", cost=75)
        public_candidate = job("public", cost=6, installation_id="installation_beta")
        with self.assertRaisesRegex(
            AdmissionCapacityError,
            "public queued map capacity",
        ):
            policy.validate_create(public_candidate, [existing])

        operator_candidate = job(
            "operator",
            cost=20,
            partition="operator",
            installation_id="installation_operator",
        )
        policy.validate_create(operator_candidate, [existing])

    def test_terminal_jobs_release_global_capacity_but_remain_in_rolling_budget(self):
        policy = AdmissionPolicy(
            max_queued_cost=20,
            max_running_cost=20,
            operator_reserved_queued_cost=1,
            operator_reserved_running_cost=1,
            max_installation_cost_per_window=10,
        )
        completed = job("completed", cost=7, status=JobStatus.READY)
        candidate = job("candidate", cost=4)
        self.assertEqual(policy.snapshot([completed]).queued_cost, 0)
        with self.assertRaises(AdmissionCapacityError) as raised:
            policy.validate_create(candidate, [completed])
        self.assertEqual(raised.exception.status_code, 429)

        completed.created_at = (
            datetime.now(timezone.utc) - timedelta(days=2)
        ).isoformat()
        policy.validate_create(candidate, [completed])


class AdmissionStoreTests(unittest.TestCase):
    def test_running_capacity_is_atomic_and_released_on_terminal_state(self):
        policy = AdmissionPolicy(
            max_queued_cost=30,
            max_running_cost=10,
            operator_reserved_queued_cost=2,
            operator_reserved_running_cost=2,
            max_installation_cost_per_window=100,
        )
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp, admission_policy=policy)
            store.save(job("one", cost=7))
            store.save(job("two", cost=2, installation_id="installation_beta"))

            first = store.claim_next("worker-one")
            self.assertEqual(first.job_id, "one")
            second = store.claim_next("worker-two")
            self.assertIsNone(second)
            with self.assertRaisesRegex(JobClaimError, "capacity"):
                store.claim("two", "worker-two")

            store.update_status(
                "one",
                JobStatus.READY,
                worker_id="worker-one",
                finished=True,
            )
            second = store.claim_next("worker-two")
            self.assertEqual(second.job_id, "two")

    def test_idempotent_race_creates_one_cost_reservation(self):
        policy = AdmissionPolicy(
            max_queued_cost=100,
            max_running_cost=50,
            operator_reserved_queued_cost=10,
            operator_reserved_running_cost=5,
            max_installation_cost_per_window=100,
        )
        request = {
            "mode": "custom_bbox",
            "bbox": [103.80, 1.20, 103.81, 1.21],
            "clientInstallationId": "installation_alpha",
            "clientRequestId": "request_idempotent",
        }
        with tempfile.TemporaryDirectory() as tmp:
            store = JobStore(tmp, admission_policy=policy)
            service = MapJobService(SourceIndex([source()]), store)
            with ThreadPoolExecutor(max_workers=8) as executor:
                created = list(
                    executor.map(
                        lambda _: service.create_job(dict(request)),
                        range(8),
                    )
                )
            self.assertEqual(len({value.job_id for value in created}), 1)
            persisted = store.list_for_installation("installation_alpha")
            self.assertEqual(len(persisted), 1)
            self.assertGreater(persisted[0].admission_cost or 0, 0)

    def test_corrupt_active_record_fails_closed_but_unrelated_terminal_history_does_not(self):
        policy = AdmissionPolicy(
            max_queued_cost=100,
            max_running_cost=50,
            operator_reserved_queued_cost=10,
            operator_reserved_running_cost=5,
            max_installation_cost_per_window=100,
        )
        request = {
            "mode": "custom_bbox",
            "bbox": [103.80, 1.20, 103.81, 1.21],
            "clientInstallationId": "installation_alpha",
            "clientRequestId": "request_new_job",
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = JobStore(root, admission_policy=policy)
            unrelated = job(
                "terminal",
                cost=5,
                status=JobStatus.READY,
                installation_id="installation_other",
            )
            store.save(unrelated)
            (root / "terminal.json").write_text("not json")
            service = MapJobService(SourceIndex([source()]), store)
            self.assertEqual(service.create_job(dict(request)).status, JobStatus.QUEUED)

            active_path = root / next(
                value.name
                for value in root.glob("*.json")
                if value.name != "terminal.json"
            )
            active_path.write_text("not json")
            changed = dict(request)
            changed["clientRequestId"] = "request_second_job"
            with self.assertRaises(AdmissionCapacityError):
                service.create_job(changed)

    def test_admission_metadata_round_trips_only_in_internal_record(self):
        value = job("roundtrip", cost=17)
        internal = value.to_dict(include_internal=True)
        self.assertEqual(internal["admission"]["cost"], 17)
        self.assertNotIn("admission", value.to_dict())
        restored = MapJob.from_dict(json.loads(json.dumps(internal)))
        self.assertEqual(restored.admission_cost, 17)
        self.assertEqual(restored.admission_partition, "public")


if __name__ == "__main__":
    unittest.main()
