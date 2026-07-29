#!/usr/bin/env python3
"""Select an explicit worker policy for a production image promotion."""

from __future__ import annotations

import argparse
from dataclasses import dataclass


@dataclass(frozen=True)
class WorkerPromotionDecision:
    worker_changed: bool
    preserve_pending: bool
    worker_selection: str


def select_worker_promotion(
    *,
    event_name: str,
    requested_policy: str,
    pending_available: bool,
    pending_moves_worker: bool,
    pending_worker_changed: bool,
    adjacent_changed: bool,
    accumulated_changed: bool,
) -> WorkerPromotionDecision:
    if event_name == "workflow_dispatch":
        if requested_policy == "preserve-pending":
            if not pending_available:
                raise ValueError(
                    "there is no open repository-owned promotion to preserve"
                )
            if pending_worker_changed:
                raise ValueError(
                    "the pending worker is incompatible with later worker inputs; "
                    "promote the new candidate instead"
                )
            return WorkerPromotionDecision(False, True, "preserved-pending")
        if requested_policy == "promote-candidate":
            return WorkerPromotionDecision(True, False, "candidate")
        if requested_policy != "auto":
            raise ValueError(f"unknown pending-worker policy: {requested_policy}")
        if pending_moves_worker:
            raise ValueError(
                "choose preserve-pending or promote-candidate for the open "
                "worker-moving promotion"
            )
        # A manual dispatch intentionally rebuilds both roles, including when
        # unpinned dependency resolution changes the image without a source diff.
        return WorkerPromotionDecision(True, False, "candidate")

    if event_name != "push":
        raise ValueError(f"unsupported workflow event: {event_name}")
    if pending_moves_worker and not adjacent_changed:
        raise ValueError(
            "a control-only change cannot implicitly carry or discard the open "
            "worker-moving promotion; re-run this workflow manually and choose "
            "preserve-pending or promote-candidate"
        )
    return WorkerPromotionDecision(accumulated_changed, False, "candidate")


def _bool(value: str) -> bool:
    if value not in {"true", "false"}:
        raise argparse.ArgumentTypeError("expected true or false")
    return value == "true"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--requested-policy", default="")
    parser.add_argument("--pending-available", type=_bool, required=True)
    parser.add_argument("--pending-moves-worker", type=_bool, required=True)
    parser.add_argument("--pending-worker-changed", type=_bool, required=True)
    parser.add_argument("--adjacent-changed", type=_bool, required=True)
    parser.add_argument("--accumulated-changed", type=_bool, required=True)
    args = parser.parse_args()
    decision = select_worker_promotion(
        event_name=args.event_name,
        requested_policy=args.requested_policy,
        pending_available=args.pending_available,
        pending_moves_worker=args.pending_moves_worker,
        pending_worker_changed=args.pending_worker_changed,
        adjacent_changed=args.adjacent_changed,
        accumulated_changed=args.accumulated_changed,
    )
    print(f"worker_changed={str(decision.worker_changed).lower()}")
    print(f"preserve_pending={str(decision.preserve_pending).lower()}")
    print(f"worker_selection={decision.worker_selection}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
