"""Signed, optional local test evidence. Every miss leaves the hosted check runnable.

The evidence branch is untrusted transport. Only a key authorized by the PR base
can attest a result; the checkout tree, recipe and live runner fingerprint must
also match. This module never supplies firmware or app build artifacts.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "seichris/open-bike-computer"
BRANCH = "ci/local-test-results"
POLICY = "tools/development/local-results-policy.json"
NAMESPACE = "bicino-local-ci-v1"
MAX_ENVELOPE = 700_000
MAX_LOG = 8_000_000
SHA = re.compile(r"[0-9a-f]{40}\Z")
ERRORS = (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError, zlib.error)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def command(args, **kwargs):
    return subprocess.check_output(args, stderr=subprocess.PIPE, timeout=120, **kwargs).decode().strip()


def api(endpoint, method="GET", body=None, missing=False):
    # No shell interpolation or credentials in arguments/logs. gh uses the local
    # login, or the read-only GH_TOKEN supplied to this step in Actions.
    args = ["gh", "api", "--hostname", "github.com", "--method", method,
            "repos/" + REPOSITORY + "/" + endpoint]
    if body is not None:
        args += ["--input", "-"]
    result = subprocess.run(args, input=canonical(body) if body is not None else None,
                            capture_output=True, timeout=30, cwd=ROOT)
    if result.returncode:
        if missing and b"HTTP 404" in result.stderr:
            return None
        raise RuntimeError("GitHub evidence transport unavailable")
    if len(result.stdout) > 2_000_000:
        raise ValueError("oversized GitHub evidence response")
    return json.loads(result.stdout)


def read_file(path, ref, *, missing=False):
    result = api("contents/" + path + "?ref=" + quote(ref, safe=""), missing=missing)
    if result is None:
        return None
    if result.get("type") != "file" or result.get("encoding") != "base64" or result["size"] > MAX_ENVELOPE:
        raise ValueError("unsupported or oversized evidence file")
    data = base64.b64decode("".join(result["content"].split()), validate=True)
    if len(data) != result["size"] or len(data) > MAX_ENVELOPE:
        raise ValueError("evidence size mismatch")
    return data, result["sha"]


def validate_policy(policy):
    if (policy["schema"] != 1 or policy["repository"] != REPOSITORY or
            not 0 < policy["maxAgeSeconds"] <= 7 * 86400 or
            not isinstance(policy["checks"], list) or not policy["publicKeys"]):
        raise ValueError("unsupported local results policy")
    for key in policy["publicKeys"]:
        if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/]+={0,3}", key):
            raise ValueError("invalid local results public key")
    return policy


def eligible(check):
    # Keep Linux, firmware, generated identities and artifact-producing app
    # builds out even if someone accidentally adds them to the policy list.
    return (check["id"] == "ios-simulator" or
            (check.get("component") == "ios" and check.get("host") == ["Darwin"]
             and "xcrun" in check.get("tools", []) and check.get("level", "fast") == "fast"))


def environment():
    # Shared execution profile. In particular ONLY_TESTING, SDKROOT, TOOLCHAINS,
    # compiler flags, DYLD_*, PYTHONPATH and shell startup hooks cannot narrow or
    # change a reusable run. Paths/caches and simulator IDs are disposable.
    result = {key: os.environ[key] for key in ("HOME", "DEVELOPER_DIR") if key in os.environ}
    result.update(PATH=str(Path(sys.executable).parent) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                  LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8", TZ="UTC", PYTHONNOUSERSITE="1")
    return result


def fingerprint(simulator=False):
    if platform.system() != "Darwin":
        raise ValueError("local results require a macOS runner")
    env = environment()
    def run(*args):
        return command(list(args), env=env, cwd=ROOT)
    python = json.loads(run("python3", "-c", "import sys,json,importlib.metadata as m,hashlib; "
        "print(json.dumps({'version':sys.version,'packages':sorted([d.metadata['Name'],d.version,"
        "hashlib.sha256((d.read_text('RECORD') or '').encode()).hexdigest()] for d in m.distributions())}))"))
    result = {"os": run("/usr/bin/sw_vers"), "architecture": platform.machine(), "python": python,
              "executables": {tool: file_digest(shutil.which(tool, path=env["PATH"]))
                              for tool in ("python3", "bash", "git", "xcrun")},
              "xcode": run(str(ROOT / "ios-app/scripts/xcodebuild-cli.sh"), "-version")}
    for tool in ("swiftc", "clang"):
        binary = run("xcrun", "--find", tool)
        version = "\n".join(line for line in run("xcrun", tool, "--version").splitlines()
                            if not line.startswith("InstalledDir:"))
        result[tool] = {"version": version, "sha256": file_digest(binary)}
    result["toolBinaries"] = {tool: file_digest(run("xcrun", "--find", tool))
                              for tool in ("swift-frontend", "swift", "ld", "xcodebuild", "simctl")}
    result["sdks"] = {sdk: {"version": run("xcrun", "--sdk", sdk, "--show-sdk-version"),
                             "build": run("xcrun", "--sdk", sdk, "--show-sdk-build-version"),
                             "settingsSha256": file_digest(Path(run("xcrun", "--sdk", sdk, "--show-sdk-path")) / "SDKSettings.json")}
                      for sdk in ("macosx", "iphoneos", "iphonesimulator", "watchos", "watchsimulator")}
    if simulator:
        # Capture exactly the runtime and device type chosen by the real runner.
        # Build version distinguishes patched runtimes with the same OS version.
        runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
        result["simulators"] = {}
        for name in ("ios", "watchos"):
            # selected_type uses xcrun; run it with the same normalized env.
            selected = json.loads(run(sys.executable, "-c",
                "import json; from tools.development.simulator_session import selected_type; "
                f"print(json.dumps(selected_type({name!r})))"))
            runtime = next(r for r in runtimes if r["identifier"] == selected[1])
            result["simulators"][name] = {"deviceType": selected[0], "runtime": selected[1],
                                           "version": runtime["version"], "build": runtime["buildversion"]}
    return result


def recipe(check, *, board=None, evidence=False, fresh=False):
    return {"check": check, "board": board, "evidence": evidence, "fresh": fresh,
            "executionProfile": 1, "runnerSha256": file_digest(ROOT / "tools/dev_check.py"),
            "verifierSha256": file_digest(Path(__file__))}


def sign(payload, key):
    with tempfile.TemporaryDirectory(prefix="bicino-sign-") as temporary:
        path = Path(temporary) / "receipt"
        path.write_bytes(canonical(payload))
        command(["ssh-keygen", "-Y", "sign", "-n", NAMESPACE, "-f", str(key), str(path)])
        return {"payload": payload, "signature": path.with_suffix(".sig").read_text()}


def verify_signature(envelope, policy):
    with tempfile.TemporaryDirectory(prefix="bicino-verify-") as temporary:
        root = Path(temporary)
        signature = root / "signature"
        signature.write_text(envelope["signature"])
        allowed = root / "allowed-signers"
        allowed.write_text("".join(f"bicino-local-ci {key}\n" for key in policy["publicKeys"]))
        command(["ssh-keygen", "-Y", "verify", "-n", NAMESPACE, "-I", "bicino-local-ci",
                 "-f", str(allowed), "-s", str(signature)], input=canonical(envelope["payload"]))


def verify(envelope, policy, source, expected_commit, expected_recipe, toolchain, *, now=None):
    validate_policy(policy)
    if len(canonical(envelope)) > MAX_ENVELOPE:
        raise ValueError("oversized receipt")
    verify_signature(envelope, policy)
    p = envelope["payload"]
    if p["schema"] != 1 or p["repository"] != REPOSITORY:
        raise ValueError("receipt schema or repository mismatch")
    if (source["dirty"] or p["source"]["dirty"] is not False or p["sourceUnchanged"] is not True or
            p["source"]["tree"] != source["tree"] or p["source"]["commit"] != expected_commit):
        raise ValueError("source mismatch (PR head and actual merge tree must both match)")
    if (p["recipe"] != expected_recipe or p["checkId"] not in policy["checks"] or
            p["checkId"] != expected_recipe["check"]["id"]):
        raise ValueError("command or execution profile mismatch")
    if p["toolchain"] != toolchain or not toolchain:
        raise ValueError("toolchain mismatch")
    if p["status"] != "passed" or p["exitCode"] != 0 or p["execution"] != "local":
        raise ValueError("receipt does not attest a successful local execution")
    now = int(time.time()) if now is None else now
    start, end = p["startedAt"], p["completedAt"]
    if (type(start) is not int or type(end) is not int or not 0 < start <= end <= now or
            now - start > policy["maxAgeSeconds"]):
        raise ValueError("receipt is expired or has invalid timestamps")
    compressed = base64.b64decode(p["logZlibBase64"], validate=True)
    decoder = zlib.decompressobj()
    log = decoder.decompress(compressed, MAX_LOG + 1)
    if (len(log) > MAX_LOG or not decoder.eof or decoder.unused_data or
            len(log) != p["logBytes"] or digest(log) != p["logSha256"]):
        raise ValueError("log integrity mismatch")
    return log


def receipt_path(source, check_id):
    if not SHA.fullmatch(source["tree"]) or not re.fullmatch(r"[a-z0-9-]+", check_id):
        raise ValueError("invalid receipt identity")
    return f"results/{source['tree']}/{check_id}.json"


def publish(envelope):
    payload = envelope["payload"]
    data = canonical(envelope)
    if len(data) > MAX_ENVELOPE:
        raise ValueError("receipt too large for transport")
    path = receipt_path(payload["source"], payload["checkId"])
    previous = read_file(path, BRANCH, missing=True)
    body = {"branch": BRANCH, "message": "Retain signed local test result [skip ci]",
            "content": base64.b64encode(data).decode()}
    if previous:
        body["sha"] = previous[1]
    # The API's blob SHA condition prevents concurrent writers losing evidence.
    api("contents/" + path, "PUT", body)


class Session:
    def __init__(self, checks, source, *, reuse=False, plan=False, **options):
        self.source, self.options = source, options
        self.policy, self.key, self.expected_commit = None, None, None
        self.fingerprints, self.contracts = {}, {}
        self.reason = "local reuse not enabled"
        self.reuse = reuse
        candidates = [c for c in checks if eligible(c)]
        if plan or not candidates:
            return
        try:
            if reuse:
                if (os.environ.get("GITHUB_EVENT_NAME") != "pull_request" or
                        os.environ.get("LOCAL_RESULTS_ALLOWED") != "true"):
                    raise ValueError("only pull-request CI can reuse local tests")
                event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
                pr = event["pull_request"]
                if (event["repository"]["full_name"] != REPOSITORY or
                        pr["head"]["repo"]["full_name"] != REPOSITORY):
                    raise ValueError("fork or repository mismatch")
                base, self.expected_commit = pr["base"]["sha"], pr["head"]["sha"]
                if not SHA.fullmatch(base) or not SHA.fullmatch(self.expected_commit):
                    raise ValueError("invalid event source")
                # Never authorize a signing key from the PR or evidence branch.
                data = read_file(POLICY, base)
                self.policy = validate_policy(json.loads(data[0]))
            else:
                if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS"):
                    return
                key = subprocess.run(["git", "config", "--get", "bicino.localResultsKey"], cwd=ROOT,
                                     capture_output=True, text=True, timeout=5).stdout.strip()
                if not key:
                    return
                self.key = Path(key)
                if (not self.key.is_file() or self.key.is_symlink() or self.key.stat().st_mode & 0o077 or
                        self.key.stat().st_uid != os.getuid()):
                    raise ValueError("local signing key unavailable or permissions too broad")
                self.policy = validate_policy(json.loads((ROOT / POLICY).read_text()))
            if source["dirty"]:
                raise ValueError("dirty source cannot be reused")
            tracked = command(["git", "ls-files", "-v"], cwd=ROOT)
            if any(line and (line[0].islower() or line[0] == "S") for line in tracked.splitlines()):
                raise ValueError("assume-unchanged or sparse paths cannot attest a full checkout")
            for check in candidates:
                if check["id"] in self.policy["checks"]:
                    self.contracts[check["id"]] = recipe(check, **options)
            for simulated in {c == "ios-simulator" for c in self.contracts}:
                self.fingerprints[simulated] = fingerprint(simulated)
            self.reason = "no matching local result"
        except ERRORS as error:
            self.contracts = {}
            self.reason = str(error) if isinstance(error, ValueError) else "local evidence unavailable"

    def try_reuse(self, check, report_path):
        if not self.reuse or check["id"] not in self.contracts:
            return None, self.reason
        try:
            data = read_file(receipt_path(self.source, check["id"]), BRANCH, missing=True)
            if data is None:
                return None, "no matching local result"
            envelope = json.loads(data[0])
            log = verify(envelope, self.policy, self.source, self.expected_commit,
                         self.contracts[check["id"]], self.fingerprints[check["id"] == "ios-simulator"])
            directory = report_path.parent / "reused-local-results"
            directory.mkdir(parents=True, exist_ok=True)
            evidence_path = directory / (check["id"] + ".json")
            evidence_path.write_bytes(data[0])
            log_path = directory / (check["id"] + ".log")
            log_path.write_bytes(log)
            return {"status": "passed", "exitCode": 0, "execution": "reused-local",
                    "log": str(log_path), "signedReceipt": str(evidence_path),
                    "receiptSha256": digest(data[0]), "receiptBlob": data[1],
                    "localCompletedAt": envelope["payload"]["completedAt"]}, "verified local result"
        except ERRORS as error:
            return None, str(error) if isinstance(error, ValueError) else "local evidence unavailable"

    def finish(self, report):
        if (not self.key or not self.contracts or report["status"] != "passed" or
                report["sourceUnchanged"] is not True):
            return
        try:
            if any(fingerprint(kind) != value for kind, value in self.fingerprints.items()):
                raise ValueError("toolchain changed while tests ran")
            for entry in report["checks"]:
                check_id = entry["id"]
                if check_id not in self.contracts or entry.get("execution") != "local" or entry["status"] != "passed":
                    continue
                log = Path(entry["log"]).read_bytes()
                if len(log) > MAX_LOG:
                    raise ValueError("local test log is too large")
                payload = {"schema": 1, "repository": REPOSITORY, "source": report["source"],
                    "sourceUnchanged": True, "checkId": check_id, "recipe": self.contracts[check_id],
                    "toolchain": self.fingerprints[check_id == "ios-simulator"],
                    "startedAt": entry["startedAt"], "completedAt": entry["completedAt"],
                    "status": "passed", "exitCode": 0, "execution": "local",
                    "logSha256": digest(log), "logBytes": len(log),
                    "logZlibBase64": base64.b64encode(zlib.compress(log, 9)).decode()}
                envelope = sign(payload, self.key)
                verify(envelope, self.policy, self.source, self.source["commit"],
                       self.contracts[check_id], payload["toolchain"])
                path = Path(entry["log"]).with_suffix(".signed.json")
                path.write_bytes(canonical(envelope))
                publish(envelope)
                entry["publishedLocalReceipt"] = str(path)
                print(f"PUBLISHED local CI result: {check_id}", flush=True)
        except ERRORS as error:
            # An upload or attestation failure is a cache miss, not a test result.
            report["localPublication"] = "unavailable; hosted CI will run"
            print("Local CI publication unavailable; hosted CI will run (" + type(error).__name__ + ")", flush=True)


def setup():
    if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS"):
        raise ValueError("configure signing only on a trusted local Mac")
    remote = command(["git", "remote", "get-url", "origin"], cwd=ROOT)
    if remote not in (f"git@github.com:{REPOSITORY}.git", f"https://github.com/{REPOSITORY}.git"):
        raise ValueError("unexpected repository remote")
    directory = Path.home() / "Library/Application Support/OpenBikeComputer/local-ci"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = directory / "id_ed25519"
    if not key.exists():
        command(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "bicino-local-ci", "-f", str(key)])
    public = " ".join(command(["ssh-keygen", "-y", "-f", str(key)]).split()[:2])
    path = ROOT / POLICY
    policy = json.loads(path.read_text())
    if public not in policy["publicKeys"]:
        policy["publicKeys"].append(public)
    validate_policy(policy)
    path.write_text(json.dumps(policy, indent=2) + "\n")
    # An orphan data branch has no workflows and is never checked out/executed.
    if api("git/ref/heads/" + BRANCH, missing=True) is None:
        tree = api("git/trees", "POST", {"tree": [{"path": "README.md", "mode": "100644", "type": "blob",
            "content": "Signed Bicino local test evidence. Data only; never merge this branch.\n"}]})
        commit = api("git/commits", "POST", {"message": "Initialize local test evidence [skip ci]",
                                               "tree": tree["sha"], "parents": []})
        api("git/refs", "POST", {"ref": "refs/heads/" + BRANCH, "sha": commit["sha"]})
    command(["git", "config", "--local", "bicino.localResultsKey", str(key)], cwd=ROOT)
    print("Local publication configured. Review and merge the public key policy to enable CI trust.")


if __name__ == "__main__":
    if sys.argv[1:] != ["setup"]:
        raise SystemExit("usage: tools/dev-env python3 tools/development/local_results.py setup")
    setup()
