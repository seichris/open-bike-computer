"""Sanitized observability; never used to authorize receipt reuse."""
import json
import os
import platform
import subprocess
import uuid


def metric(operation):
    try:
        return operation()
    except Exception:
        return None


def category(error, stage=""):
    reason = str(error)
    known = {
        "no matching local result": "absent", "local reuse not enabled": "disabled",
        "only pull-request CI can reuse local tests": "event-ineligible",
        "fork or repository mismatch": "event-ineligible", "invalid event source": "event-ineligible",
        "dirty source cannot be reused": "source-dirty",
        "assume-unchanged or sparse paths cannot attest a full checkout": "source-unverifiable",
        "source mismatch (PR head and actual merge tree must both match)": "source-mismatch",
        "command or execution profile mismatch": "recipe-mismatch",
        "toolchain mismatch": "toolchain-mismatch", "dependencies mismatch": "dependencies-mismatch",
        "receipt is expired or has invalid timestamps": "stale-or-invalid-time",
        "log integrity mismatch": "log-invalid",
        "receipt does not attest a successful local execution": "unsuccessful-receipt",
        "GitHub evidence transport unavailable": "network-unavailable",
        "oversized receipt": "receipt-invalid", "receipt schema or repository mismatch": "receipt-invalid",
    }
    if isinstance(error, subprocess.CalledProcessError) and error.cmd[:3] == ["ssh-keygen", "-Y", "verify"]:
        return "signature-invalid"
    return known.get(reason, {"lookup": "network-unavailable", "verification": "receipt-invalid",
        "fingerprint": "fingerprint-unavailable", "policy": "policy-unavailable"}.get(stage, "unavailable"))


class ReuseMetrics:
    def __init__(self, repository, hosted):
        system = {"Darwin": "darwin", "Linux": "linux", "Windows": "win32"}.get(platform.system(), "unknown")
        arch = {"x86_64": "x64", "AMD64": "x64", "aarch64": "arm64"}.get(platform.machine(), platform.machine())
        self.report = {"schema": 1, "kind": "local-result-reuse-metrics", "runId": str(uuid.uuid4()),
                       "repository": repository, "platform": f"{system}/{arch}",
                       "context": "ci-mode" if hosted else "local", "initializationMs": 0, "observations": []}

    def start(self, check, eligible, reason):
        observation = {"check": check, "eligible": eligible, "attempted": False,
                       "outcome": "not-attempted" if eligible else "ineligible",
                       "reason": reason if eligible else "ineligible", "preparationMs": 0,
                       "lookupMs": 0, "verificationMs": 0, "fallbackDurationMs": None,
                       "estimatedAvoidedExecutionMs": 0}
        self.report["observations"].append(observation)
        return observation

    def execution(self, observation, duration_ms):
        if observation and observation["eligible"] and self.report["context"] == "ci-mode" and observation["outcome"] != "accepted":
            observation["fallbackDurationMs"] = duration_ms

    def write(self, filename):
        # The containing report directory already exists. No logs, env, keys or raw errors.
        with open(filename, "w", opener=lambda name, flags: os.open(name, flags, 0o600)) as stream:
            json.dump(self.report, stream, indent=2, allow_nan=False)
            stream.write("\n")
