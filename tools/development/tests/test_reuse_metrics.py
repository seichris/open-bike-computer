"""Cross-repository schema, denominator, aggregation and privacy checks."""
import copy
import importlib.util
import json
import unittest
import sys

# CI runs this from the checkout before receipt lookup; do not dirty it.
sys.dont_write_bytecode = True
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = next(path for path in (HERE / "summarize-local-reuse.py", HERE.parent / "summarize-local-reuse.py") if path.exists())
spec = importlib.util.spec_from_file_location("summary", SCRIPT)
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


def report(repository, run_id, context="ci-mode"):
    return {"schema": 1, "kind": "local-result-reuse-metrics", "runId": f"00000000-0000-0000-0000-{run_id:012d}",
            "repository": repository, "platform": "darwin/arm64", "context": context,
            "initializationMs": 11, "observations": []}


def row(outcome="miss", reason="absent"):
    return {"check": "unit", "eligible": outcome != "ineligible", "attempted": outcome in ("accepted", "miss"),
            "outcome": outcome, "reason": reason, "preparationMs": 2, "lookupMs": 3, "verificationMs": 5,
            "fallbackDurationMs": 17 if outcome == "miss" else None,
            "estimatedAvoidedExecutionMs": 9000 if outcome == "accepted" else 0}


class SummaryTests(unittest.TestCase):
    def test_three_repositories_platforms_denominators_and_duplicates(self):
        a = report("seichris/open-bike-computer", 1)
        a["observations"] = [row("accepted", "accepted"), row(), row("ineligible", "ineligible")]
        b = report("chihoai/chiho", 2)
        b["platform"] = "linux/x64"
        b["observations"] = [row("not-attempted", "policy-unavailable")]
        b["observations"][0]["fallbackDurationMs"] = 23
        c = report("seichris/taobaosearch", 3, "local")
        c["observations"] = [row("not-attempted", "local-execution")]
        result = summary.summarize([a, b, c, copy.deepcopy(a)])
        total = result["totals"]["ci-mode"]
        self.assertEqual(result["duplicateRunsIgnored"], 1)
        self.assertEqual((total["selectedChecks"], total["eligibleChecks"], total["attemptedLookups"], total["acceptedReceipts"]), (4, 3, 2, 1))
        self.assertEqual(total["acceptancePerAttempt"], {"numerator": 1, "denominator": 2, "ratio": .5})
        self.assertEqual(total["acceptancePerEligible"]["denominator"], 3)
        self.assertEqual(total["fallbackDurationMs"], 40)
        self.assertEqual(total["estimatedAvoidedExecutionMs"], 9000)
        self.assertEqual(total["initializationMs"], 22)
        self.assertEqual(result["totals"]["local"]["acceptedReceipts"], 0)
        self.assertEqual(result["totals"]["local"]["eligibleChecks"], 1)
        self.assertEqual({r["repository"] for r in result["byRepositoryPlatformCheck"]}, {a["repository"], b["repository"], c["repository"]})
        self.assertIsNone(summary.summarize([])["totals"]["ci-mode"]["acceptancePerAttempt"]["ratio"])

    def test_invalid_and_private_fields_cannot_pollute_aggregate(self):
        valid = report("chihoai/chiho", 1)
        valid["observations"] = [row()]
        valid["rawError"] = "token=private-value"
        valid["observations"][0]["log"] = "private-value"
        invalid = []
        for key, value in (("reason", "token=private-value"), ("check", "private/value"),
                           ("attempted", False), ("fallbackDurationMs", float("nan")),
                           ("estimatedAvoidedExecutionMs", 1000)):
            clone = copy.deepcopy(valid)
            clone["observations"][0][key] = value
            invalid.append(clone)
        result = summary.summarize([None, {}, *invalid, valid])
        self.assertEqual(result["invalidReports"], 7)
        self.assertEqual(result["totals"]["ci-mode"]["eligibleChecks"], 1)
        self.assertNotIn("private-value", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
