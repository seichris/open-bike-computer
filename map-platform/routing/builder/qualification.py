#!/usr/bin/env python3
"""Judge one archive's qualification probes and write their summary.

`stages/qualify.sh` runs the smoke probes, the cross-border probes, the
territory audit and the profile probe against one archive and leaves each
report as `NAME.json` with its exit status in `exit-codes.txt`. This reads
them, writes `summary.json` and fails unless every check passed.

The audit exits 2 whenever a unit did not route, and on a planet graph 17
units never do: remote islands and reefs, a glacier and Vatican City, whose
fixture seeds lie at sea, give a zero-length route or were never generated
(see the refresh runbook). The audit passes when no other unit fails. A known
exception that now routes is reported, not failed, so the list can be
shortened.

A city sample runs only the smoke probes, on fixtures made from its own legs.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCHEMA = "bicino-planet-qualification-v1"
CHECKS = ("smoke", "cross-border", "audit", "profiles")
SAMPLE_CHECKS = ("smoke",)
# Units the 2026-11-24, 2026-11-25 and 2026-11-26 planet audits did not route.
KNOWN_AUDIT_EXCEPTIONS = frozenset((
    "ATC", "ATF", "BJN", "BVT", "CLP", "CSI", "FQI", "HMD", "HQI", "IOT", "KAS", "KQI",
    "PCN", "SCR", "SER", "TKL", "VAT",
))


def read_exit_codes(path):
    codes = {}
    for line in path.read_text().splitlines():
        name, _, code = line.partition(" ")
        codes[name] = int(code)
    return codes


def judge_probes(report, exit_code):
    probes = (report or {}).get("probes") or []
    passed = sum(1 for probe in probes if probe.get("passed"))
    failed = [probe.get("name") for probe in probes if not probe.get("passed")]
    return {"passed": bool(probes) and not failed and exit_code == 0,
            "routed": passed, "probes": len(probes), "failed": failed, "exitStatus": exit_code}


def judge_audit(report, exit_code, known=KNOWN_AUDIT_EXCEPTIONS):
    units = (report or {}).get("units") or []
    not_routed = sorted(unit["code"] for unit in units if unit.get("state") != "routed")
    unexpected = sorted(set(not_routed) - known)
    return {"passed": bool(units) and not unexpected and exit_code in (0, 2),
            "routed": len(units) - len(not_routed), "units": len(units), "notRouted": not_routed,
            "unexpected": unexpected, "knownExceptionsNowRouting": sorted(known - set(not_routed)),
            "exitStatus": exit_code}


def judge_profiles(report, exit_code):
    report = report or {}
    probes, failures = report.get("probes") or [], report.get("failures")
    return {"passed": bool(probes) and failures == [] and exit_code == 0,
            "pairs": len(probes), "failures": failures, "exitStatus": exit_code}


JUDGES = {"smoke": judge_probes, "cross-border": judge_probes, "audit": judge_audit, "profiles": judge_profiles}


def summarize(directory, label, sample=False):
    codes = read_exit_codes(directory / "exit-codes.txt")
    wanted = SAMPLE_CHECKS if sample else CHECKS
    checks = {}
    for name in CHECKS:
        if name not in wanted:
            checks[name] = {"skipped": "not run on a city sample"}
            continue
        try:
            report = json.loads((directory / f"{name}.json").read_text())
        except (OSError, ValueError):
            report = None
        checks[name] = JUDGES[name](report, codes.get(name))
        if report is None:
            checks[name]["error"] = "the check left no report"
    return {"schema": SCHEMA, "label": label, "sample": sample,
            "passed": all(check.get("passed", True) for check in checks.values()), "checks": checks}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", required=True, type=Path, help="The archive's qualification directory")
    parser.add_argument("--label", required=True, choices=("ungraded", "graded"))
    parser.add_argument("--sample", action="store_true")
    args = parser.parse_args(argv)
    summary = summarize(args.dir, args.label, args.sample)
    (args.dir / "summary.json").write_text(json.dumps(summary, indent=1) + "\n")
    for name, check in summary["checks"].items():
        print(f"{name}: {json.dumps(check)}")
    print(f"{args.label}: {'qualified' if summary['passed'] else 'NOT qualified'}")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
