from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "select_worker_promotion.py"
SPEC = importlib.util.spec_from_file_location("select_worker_promotion", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
select_worker_promotion = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = select_worker_promotion
SPEC.loader.exec_module(select_worker_promotion)


class SelectWorkerPromotionTests(unittest.TestCase):
    def decide(self, **overrides: object):
        values: dict[str, object] = {
            "event_name": "push",
            "requested_policy": "",
            "pending_available": False,
            "pending_moves_worker": False,
            "pending_worker_changed": False,
            "adjacent_changed": False,
            "accumulated_changed": False,
        }
        values.update(overrides)
        return select_worker_promotion.select_worker_promotion(**values)

    def test_accumulated_worker_change_survives_cancelled_prior_run(self) -> None:
        decision = self.decide(
            adjacent_changed=False,
            accumulated_changed=True,
        )

        self.assertTrue(decision.worker_changed)
        self.assertEqual(decision.worker_selection, "candidate")

    def test_control_only_push_cannot_silently_carry_pending_worker(self) -> None:
        with self.assertRaisesRegex(ValueError, "cannot implicitly carry or discard"):
            self.decide(
                pending_available=True,
                pending_moves_worker=True,
                adjacent_changed=False,
                accumulated_changed=True,
            )

    def test_manual_dispatch_must_resolve_pending_worker_intent(self) -> None:
        with self.assertRaisesRegex(ValueError, "choose preserve-pending"):
            self.decide(
                event_name="workflow_dispatch",
                requested_policy="auto",
                pending_available=True,
                pending_moves_worker=True,
                accumulated_changed=True,
            )

        preserved = self.decide(
            event_name="workflow_dispatch",
            requested_policy="preserve-pending",
            pending_available=True,
            pending_moves_worker=True,
            accumulated_changed=True,
        )
        self.assertFalse(preserved.worker_changed)
        self.assertTrue(preserved.preserve_pending)
        self.assertEqual(preserved.worker_selection, "preserved-pending")

        candidate = self.decide(
            event_name="workflow_dispatch",
            requested_policy="promote-candidate",
            pending_available=True,
            pending_moves_worker=True,
            accumulated_changed=True,
        )
        self.assertTrue(candidate.worker_changed)
        self.assertFalse(candidate.preserve_pending)
        self.assertEqual(candidate.worker_selection, "candidate")

    def test_pending_worker_cannot_cross_later_worker_changes(self) -> None:
        with self.assertRaisesRegex(ValueError, "incompatible with later worker inputs"):
            self.decide(
                event_name="workflow_dispatch",
                requested_policy="preserve-pending",
                pending_available=True,
                pending_moves_worker=True,
                pending_worker_changed=True,
                adjacent_changed=True,
                accumulated_changed=True,
            )

    def test_manual_auto_promotes_same_source_rebuild(self) -> None:
        decision = self.decide(
            event_name="workflow_dispatch",
            requested_policy="auto",
            accumulated_changed=False,
        )

        self.assertTrue(decision.worker_changed)
        self.assertEqual(decision.worker_selection, "candidate")

    def test_worker_changing_push_replaces_pending_candidate(self) -> None:
        decision = self.decide(
            pending_available=True,
            pending_moves_worker=True,
            adjacent_changed=True,
            accumulated_changed=True,
        )

        self.assertTrue(decision.worker_changed)
        self.assertFalse(decision.preserve_pending)


if __name__ == "__main__":
    unittest.main()
