#!/usr/bin/env python3
"""Aggregate final *-reuse-metrics.json artifacts from any of the three repos."""
import argparse
import json
import math
import re
from pathlib import Path

REASONS = set("accepted absent disabled event-ineligible policy-invalid policy-unavailable policy-ineligible source-dirty source-unverifiable environment-unverifiable source-mismatch recipe-mismatch environment-mismatch toolchain-mismatch dependencies-mismatch signature-invalid stale-or-invalid-time log-invalid network-unavailable unsuccessful-receipt receipt-invalid fingerprint-unavailable unavailable local-execution ineligible blocked planned".split())
TIMES = ("preparationMs", "lookupMs", "verificationMs", "fallbackDurationMs", "estimatedAvoidedExecutionMs")


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def require(condition):
    if not condition:
        raise ValueError("invalid metric report")


def validate(report):
    require(report["schema"] == 1 and report["kind"] == "local-result-reuse-metrics")
    require(re.fullmatch(r"[0-9a-f-]{36}", report["runId"]))
    require(report["repository"] in ("seichris/open-bike-computer", "chihoai/chiho", "seichris/taobaosearch"))
    require(re.fullmatch(r"(?:darwin|linux|win32|unknown)/[a-zA-Z0-9_]{1,20}", report["platform"]))
    require(report["context"] in ("ci-mode", "local") and number(report["initializationMs"]))
    require(isinstance(report["observations"], list))
    for row in report["observations"]:
        require(re.fullmatch(r"[a-z0-9-]{1,120}", row["check"]))
        require(type(row["eligible"]) is bool and type(row["attempted"]) is bool)
        require(row["outcome"] in ("ineligible", "not-attempted", "miss", "accepted"))
        require(row["reason"] in REASONS)
        require((row["outcome"] == "ineligible") == (not row["eligible"]))
        require(row["attempted"] == (row["outcome"] in ("accepted", "miss")))
        require(row["eligible"] or not row["attempted"])
        require(all(number(row[key]) for key in TIMES if key != "fallbackDurationMs"))
        fallback = row["fallbackDurationMs"]
        require(fallback is None or (number(fallback) and row["eligible"] and report["context"] == "ci-mode" and row["outcome"] != "accepted"))
        require(row["outcome"] == "accepted" or row["estimatedAvoidedExecutionMs"] == 0)
        require(row["outcome"] != "accepted" or (row["reason"] == "accepted" and report["context"] == "ci-mode"))
    return report


def bucket():
    return {"selectedChecks": 0, "eligibleChecks": 0, "attemptedLookups": 0, "acceptedReceipts": 0,
            "fallbackExecutions": 0, "preparationMs": 0, "lookupMs": 0, "verificationMs": 0,
            "fallbackDurationMs": 0, "estimatedAvoidedExecutionMs": 0, "missReasons": {}}


def add(target, row):
    target["selectedChecks"] += 1
    target["eligibleChecks"] += int(row["eligible"])
    target["attemptedLookups"] += int(row["attempted"])
    target["acceptedReceipts"] += int(row["outcome"] == "accepted")
    target["fallbackExecutions"] += int(row["fallbackDurationMs"] is not None)
    for key in TIMES:
        target[key] += row[key] or 0
    if row["eligible"] and row["outcome"] != "accepted":
        reasons = target["missReasons"]
        reasons[row["reason"]] = reasons.get(row["reason"], 0) + 1


def rates(target):
    for label, numerator, denominator in (
        ("attemptRate", "attemptedLookups", "eligibleChecks"),
        ("acceptancePerAttempt", "acceptedReceipts", "attemptedLookups"),
        ("acceptancePerEligible", "acceptedReceipts", "eligibleChecks"),
    ):
        target[label] = {"numerator": target[numerator], "denominator": target[denominator],
                         "ratio": target[numerator] / target[denominator] if target[denominator] else None}
    for key in TIMES:
        target[key] = round(target[key], 3)
    return target


def summarize(reports):
    totals = {context: {**bucket(), "runs": 0, "initializationMs": 0} for context in ("ci-mode", "local")}
    groups, seen = {}, set()
    invalid = duplicates = 0
    for report in reports:
        try:
            validate(report)
        except (AssertionError, KeyError, TypeError, ValueError):
            invalid += 1
            continue
        identity = (report["repository"], report["runId"])
        if identity in seen:
            duplicates += 1
            continue
        seen.add(identity)
        total = totals[report["context"]]
        total["runs"] += 1
        total["initializationMs"] += report["initializationMs"]
        for row in report["observations"]:
            key = tuple(report[field] for field in ("repository", "platform", "context")) + (row["check"],)
            add(groups.setdefault(key, bucket()), row)
            add(total, row)
    return {"schema": 1, "kind": "local-result-reuse-summary", "invalidReports": invalid,
            "duplicateRunsIgnored": duplicates, "totals": {key: rates(value) for key, value in totals.items()},
            "byRepositoryPlatformCheck": [{**dict(zip(("repository", "platform", "context", "check"), key)),
                                           **rates(value)} for key, value in sorted(groups.items())],
            "estimateBasis": "Accepted signed completedAt minus startedAt (whole seconds); elapsed local receipt window, not measured hosted command duration.",
            "limitations": ["No measurement of actual runner, billing, queue or end-to-end savings.",
                            "Absent receipts cannot identify the differing source, recipe or runtime hint.",
                            "Initialization is shared per run, not allocated to individual checks.",
                            "Missing artifacts and telemetry write failures are outside these denominators."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path, help="Final metric files or artifact directories (recursive)")
    args = parser.parse_args()
    files = set()
    for item in args.reports:
        files.update(item.rglob("*-reuse-metrics.json") if item.is_dir() else [item])
    reports = []
    for filename in sorted(files):
        try:
            if filename.stat().st_size > 8_000_000:
                raise ValueError("oversized metric file")
            reports.append(json.loads(filename.read_text()))
        except (OSError, ValueError):
            reports.append(None)
    print(json.dumps(summarize(reports), indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
