"""Machine-readable diagnostics commands. No implicit pairing, flashing, or resets."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
import time
import uuid

from . import __version__
from . import bundle


def contract() -> dict:
    return json.loads(Path(__file__).with_name("contract.generated.json").read_text())


def duration(value: str) -> int:
    match = re.fullmatch(r"([1-9][0-9]{0,5})(s|m|h)?", value)
    if not match: raise argparse.ArgumentTypeError("duration must be seconds, Nm, or Nh")
    result = int(match[1]) * {None: 1, "s": 1, "m": 60, "h": 3600}[match[2]]
    if not 1 <= result <= 14400: raise argparse.ArgumentTypeError("duration must be between 1s and 4h")
    return result


def default_state() -> Path:
    if sys.platform == "darwin": return Path.home() / "Library/Application Support/BicinoDiagnostics"
    return Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "bicino-diagnostics"


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--state", type=Path, default=default_state())
    subs = p.add_subparsers(dest="command", required=True)
    subs.add_parser("doctor")
    caps = subs.add_parser("capabilities"); caps.add_argument("--device")
    b = subs.add_parser("broker"); bs = b.add_subparsers(dest="broker_command", required=True)
    init = bs.add_parser("init"); init.add_argument("--advertise", required=True); init.add_argument("--app-family", required=True, choices=["LetItRide.BikeComputer", "LetItRide.BikeComputer.dev"])
    serve = bs.add_parser("serve"); serve.add_argument("--listen", default="127.0.0.1"); serve.add_argument("--port", type=int)
    cap = subs.add_parser("capture"); cs = cap.add_subparsers(dest="capture_command", required=True)
    start = cs.add_parser("start"); start.add_argument("--device", required=True); start.add_argument("--profile", default="ble-navigation", choices=list(contract()["profiles"]))
    start.add_argument("--duration", type=duration, default=7200); start.add_argument("--domain", action="append", default=[]); start.add_argument("--capture-id")
    start.add_argument("--wait", type=int, default=0)
    end = cs.add_parser("end"); end.add_argument("--device", required=True); end.add_argument("--capture-id", required=True); end.add_argument("--wait", type=int, default=0)
    mark = subs.add_parser("mark"); mark.add_argument("--device", required=True); mark.add_argument("--code", choices=["navigation_wrong", "device_blank", "connection_drop", "sensor_missing", "other"], default="other"); mark.add_argument("--wait", type=int, default=0)
    collect = subs.add_parser("collect"); collect.add_argument("--device", required=True); collect.add_argument("--capture-id"); collect.add_argument("--wait", type=int, default=0); collect.add_argument("--output", type=Path); collect.add_argument("--require", default="ios,firmware")
    job = subs.add_parser("job"); job.add_argument("id"); job.add_argument("--wait", type=int, default=0)
    fetch = subs.add_parser("fetch"); fetch.add_argument("id"); fetch.add_argument("--output", type=Path, required=True); fetch.add_argument("--require", default="ios,firmware")
    analyze = subs.add_parser("analyze"); analyze.add_argument("bundle", type=Path); analyze.add_argument("--output", type=Path); analyze.add_argument("--require", default="")
    query = subs.add_parser("query"); query.add_argument("bundle", type=Path)
    for name in ("source", "domain", "level", "capture", "incident", "operation", "cursor"): query.add_argument("--" + name)
    query.add_argument("--limit", type=int, default=100)
    tail = subs.add_parser("tail"); tail.add_argument("--source", choices=["ios", "firmware"], default="ios"); tail.add_argument("--after", type=int, default=-1); tail.add_argument("--process-id"); tail.add_argument("--limit", type=int, default=32)
    tail.add_argument("--device"); tail.add_argument("--boot-sequence", type=int, default=0)
    symbols = subs.add_parser("symbols"); sy = symbols.add_subparsers(dest="symbols_command", required=True)
    reg = sy.add_parser("register"); reg.add_argument("artifact", type=Path); reg.add_argument("--build-sha", required=True); reg.add_argument("--target", required=True); reg.add_argument("--profile", required=True)
    lookup = sy.add_parser("resolve"); lookup.add_argument("--artifact-sha256", required=True)
    return p


def require_sources(summary: dict, required: str) -> bool:
    names = set(filter(None, required.split(",")))
    if not names.issubset({"ios", "firmware", "host"}): raise bundle.EvidenceError("invalid_required_source")
    missing = names - {key for key, count in summary["sourceCounts"].items() if count > 0}
    summary["missingRequiredSources"] = sorted(missing)
    return not missing and summary["deliveryState"] != "incomplete" and summary["recordingCoverage"] != "missing_requested_capture"


def wait_job(root: Path, value: dict, seconds: int) -> dict:
    from .broker import BrokerError, request
    if not 0 <= seconds <= 300: raise BrokerError("wait_must_be_between_0_and_300_seconds")
    until = time.monotonic() + seconds
    while value["state"] in ("queued", "leased") and time.monotonic() < until:
        time.sleep(min(1, max(0, until - time.monotonic())))
        value = request(root, "GET", "/v2/jobs/" + value["id"])
    return value


def enqueue(root: Path, kind: str, device: str, arguments: dict, seconds: int) -> dict:
    from .broker import request
    command = {"id": str(uuid.uuid4()), "kind": kind, "arguments": arguments,
               "deviceDigest": device, "expiresAtEpoch": int(time.time()) + (86400 if kind == "collect" else 300)}
    return wait_job(root, request(root, "POST", "/v2/jobs", command), seconds)


def fetch(root: Path, job: dict, output: Path, required: str) -> dict:
    from .broker import BrokerError, request
    if job.get("state") != "completed" or job.get("kind") != "collect": raise BrokerError("collection_not_completed")
    digest = job.get("result", {}).get("artifactSHA256", "")
    if not bundle.SHA.fullmatch(digest): raise BrokerError("invalid_artifact_identity")
    output.mkdir(parents=True, exist_ok=True)
    destination = output / ("bicino-" + digest + ".zip")
    if destination.exists():
        if destination.is_symlink() or bundle.sha256_file(destination) != digest: raise BrokerError("existing_artifact_mismatch")
    else:
        value = request(root, "GET", "/v2/artifacts/" + digest, output=destination)
        if value["sha256"] != digest: raise BrokerError("download_digest_mismatch")
    summary, _ = bundle.read(destination)
    ok = require_sources(summary, required)
    (output / (digest + ".summary.json")).write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
    return {"ok": ok, "artifact": str(destination), "summary": summary}


def run(args: argparse.Namespace) -> dict:
    from .broker import BrokerError, Store, Server, atomic_json, initialize, load_json, private_root, request, validate_origin
    if args.command == "broker":
        if args.broker_command == "init": return initialize(args.state, args.advertise, args.app_family)
        store = Store(args.state)
        _, advertised_port = validate_origin(store.config["baseURL"])
        port = args.port if args.port is not None else advertised_port
        if not 1 <= port <= 65535: raise BrokerError("invalid_port")
        server = Server((args.listen, port), store)
        print(json.dumps({"schema": 2, "state": "listening", "listen": args.listen, "port": port}), flush=True)
        try: server.serve_forever(poll_interval=0.5)
        finally: server.server_close()
        return {"state": "stopped"}
    if args.command == "doctor":
        value = {"schema": 2, "version": __version__, "host": platform.system(),
                 "xcrunAvailable": shutil.which("xcrun") is not None, "automaticHardwareWrites": False,
                 "brokerConfigured": (args.state / "config.json").exists()}
        if value["brokerConfigured"]:
            try:
                status = request(args.state, "GET", "/v2/status")
                if status.get("phone"): status["phone"].pop("tail", None)
                value["broker"] = status
            except (BrokerError, OSError): value["broker"] = {"state": "unreachable"}
        return value
    if args.command == "capabilities":
        value = request(args.state, "GET", "/v2/status")
        phone = value.get("phone")
        if args.device and (not phone or phone.get("deviceDigest") != args.device): raise BrokerError("requested_device_not_observed")
        if phone: phone.pop("tail", None)
        value["contract"] = {key: contract()[key] for key in ("schema", "categories", "levels", "profiles", "limits")}
        return value
    if args.command == "capture":
        if args.capture_command == "start":
            capture_id = str(uuid.UUID(args.capture_id)) if args.capture_id else str(uuid.uuid4())
            levels = dict(contract()["profiles"][args.profile]["levels"])
            for item in args.domain:
                if "=" not in item: raise BrokerError("domain_must_be_name_equals_level")
                domain, level = item.split("=", 1); levels[domain] = level
            arguments = {"captureID": capture_id, "generation": 1, "profile": args.profile,
                         "durationSeconds": args.duration, "createdAtEpoch": int(time.time()), "levels": levels}
            return enqueue(args.state, "capture.start", args.device, arguments, args.wait)
        return enqueue(args.state, "capture.end", args.device, {"captureID": str(uuid.UUID(args.capture_id))}, args.wait)
    if args.command == "mark": return enqueue(args.state, "mark", args.device, {"code": args.code}, args.wait)
    if args.command == "collect":
        arguments = {"captureID": str(uuid.UUID(args.capture_id))} if args.capture_id else {}
        job = enqueue(args.state, "collect", args.device, arguments, args.wait)
        if args.output and job["state"] == "completed": return fetch(args.state, job, args.output, args.require)
        return job
    if args.command == "job": return wait_job(args.state, request(args.state, "GET", "/v2/jobs/" + str(uuid.UUID(args.id))), args.wait)
    if args.command == "fetch": return fetch(args.state, request(args.state, "GET", "/v2/jobs/" + str(uuid.UUID(args.id))), args.output, args.require)
    if args.command == "analyze":
        summary, events = bundle.read(args.bundle)
        ok = require_sources(summary, args.require)
        if args.output:
            if args.output.exists() and any(args.output.iterdir()): raise bundle.EvidenceError("analysis_output_must_be_empty")
            args.output.mkdir(parents=True, exist_ok=True)
            (args.output / "summary.json").write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
            with (args.output / "timeline.jsonl").open("w") as file:
                for event in events: file.write(json.dumps(event, sort_keys=True) + "\n")
        return {"ok": ok, "summary": summary}
    if args.command == "query":
        return bundle.query(args.bundle, **{key: getattr(args, key) for key in ("source", "domain", "level", "capture", "incident", "operation", "cursor", "limit")})
    if args.command == "tail":
        if args.source == "firmware":
            if not args.device: raise BrokerError("explicit_device_digest_required")
            value = enqueue(args.state, "observe", args.device, {"bootSequence": args.boot_sequence, "after": max(0,args.after), "limit": min(8,args.limit)}, 10)
            value["observationOnly"] = True
            value["warning"] = "Live observation is lossy and not a durable acquisition; use collect for retained evidence."
            return value
        if not 1 <= args.limit <= 100: raise BrokerError("invalid_tail_limit")
        value = request(args.state, "GET", "/v2/status")
        if not value.get("phoneFresh"): raise BrokerError("phone_heartbeat_stale")
        events = value.get("phone", {}).get("tail", [])
        if not isinstance(events, list): raise BrokerError("invalid_tail")
        process = events[-1].get("processId") if events else None
        changed = args.process_id is not None and process != args.process_id
        selected = [event for event in events if event.get("source") == "ios" and (changed or event.get("sequence", -1) > args.after)]
        selected = selected[:args.limit]
        gap = changed or bool(selected and args.after >= 0 and selected[0]["sequence"] > args.after + 1)
        return {"schema": 2, "source": "ios", "processID": process, "events": selected, "gap": gap,
                "nextSequence": selected[-1]["sequence"] if selected else args.after,
                "durability": "live_reader_observation_not_a_durable_export"}
    if args.command == "symbols":
        root = private_root(args.state); directory = private_root(root / "symbols")
        if args.symbols_command == "register":
            if not re.fullmatch(r"[0-9a-f]{40}", args.build_sha) or not all(re.fullmatch(r"[A-Z0-9_]{1,80}", x) for x in (args.target, args.profile)):
                raise BrokerError("invalid_build_identity")
            if args.artifact.is_symlink() or not args.artifact.is_file(): raise BrokerError("symbol_artifact_must_be_regular_file")
            if args.artifact.stat().st_size > 300 * 1024 * 1024: raise BrokerError("symbol_artifact_too_large")
            digest = bundle.sha256_file(args.artifact)
            destination = directory / (digest + ".elf")
            if not destination.exists(): shutil.copyfile(args.artifact, destination); destination.chmod(0o600)
            with destination.open("rb") as file:
                if file.read(4) != b"\x7fELF": raise BrokerError("expected_firmware_elf")
            value = {"schema": 2, "sha256": digest, "buildSHA": args.build_sha, "target": args.target, "profile": args.profile, "path": str(destination)}
            atomic_json(directory / (digest + ".json"), value); return value
        if not bundle.SHA.fullmatch(args.artifact_sha256): raise BrokerError("invalid_symbol_digest")
        value = load_json(directory / (args.artifact_sha256 + ".json"))
        artifact = directory / (args.artifact_sha256 + ".elf")
        if bundle.sha256_file(artifact) != args.artifact_sha256: raise BrokerError("symbol_artifact_digest_mismatch")
        value["path"] = str(artifact)
        return value
    raise BrokerError("unsupported_command")


def main(argv: list[str] | None = None) -> int:
    values = list(sys.argv[1:] if argv is None else argv)
    if values and values[0] == "diag": values.pop(0)
    # Every command emits JSON; accept this flag anywhere for agent ergonomics.
    values = [value for value in values if value != "--json"]
    try:
        args = parser().parse_args(values)
        result = run(args)
        print(json.dumps(result, sort_keys=True, allow_nan=False))
        return 1 if result.get("ok") is False or result.get("state") in ("failed", "expired") else 0
    except KeyboardInterrupt:
        print(json.dumps({"ok": False, "code": "interrupted"})); return 130
    except (OSError, ValueError, KeyError, TypeError, __import__("zipfile").BadZipFile) as error:
        # No stack traces, credentials, free-form device messages or file data.
        from .broker import BrokerError
        code = str(error).split(":", 1)[0] if isinstance(error, (BrokerError, bundle.EvidenceError)) else "operation_failed"
        print(json.dumps({"ok": False, "code": code})); return 1


if __name__ == "__main__": raise SystemExit(main())
