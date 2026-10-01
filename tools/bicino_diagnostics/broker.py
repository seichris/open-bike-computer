"""Opt-in local HTTPS artifact/command broker; no remote shell or hardware writes.

Phone and control tokens are distinct. Only an explicitly imported enrollment
file grants a phone access. TLS pins are verified before client tokens are sent.
"""
from __future__ import annotations
import base64
import hashlib
import hmac
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import ssl
import stat
import subprocess
import tempfile
import threading
import time
from typing import Any
from urllib.parse import urlsplit
import uuid
import zipfile

from .bundle import legacy, EvidenceError, MAX_BUNDLE, SHA, UUID, read as read_bundle, sha256_file, strict_json

MAX_BODY = 1024 * 1024
MAX_JOBS = 256
MAX_INBOX = 1024 * 1024 * 1024
APP_FAMILIES = {"LetItRide.BikeComputer", "LetItRide.BikeComputer.dev"}
COMMANDS = {"capture.start", "capture.end", "mark", "collect", "observe"}

class BrokerError(ValueError):
    pass


def private_root(root: Path) -> Path:
    root = root.expanduser().absolute()
    if root.is_symlink():
        raise BrokerError("symlink_state_directory")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = root.stat()
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise BrokerError("state_directory_must_be_owned_and_mode_0700")
    return root


def atomic_json(path: Path, value: Any) -> None:
    if path.is_symlink():
        raise BrokerError("symlink_state_file")
    raw = (json.dumps(value, sort_keys=True, allow_nan=False) + "\n").encode()
    descriptor, temporary = tempfile.mkstemp(prefix=".state-", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as file:
            file.write(raw); file.flush(); os.fsync(file.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def load_json(path: Path, maximum: int = 128 * 1024) -> Any:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > maximum or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise BrokerError("unsafe_state_file")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as file:
        return strict_json(file.read(maximum + 1))


def validate_origin(origin: str) -> tuple[str, int]:
    parsed = urlsplit(origin)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/"):
        raise BrokerError("https_origin_required")
    host = parsed.hostname
    try:
        address = ipaddress.ip_address(host)
        if not address.is_private and not address.is_loopback:
            raise BrokerError("local_broker_requires_private_address")
        if address.is_unspecified or address.is_multicast:
            raise BrokerError("invalid_advertised_address")
    except ValueError:
        if host != "localhost" and not host.endswith(".local"):
            raise BrokerError("local_broker_requires_private_address_or_local_hostname")
    port = parsed.port or 443
    if not 1 <= port <= 65535: raise BrokerError("invalid_port")
    return host, port


def initialize(root: Path, origin: str, app_family: str) -> dict[str, Any]:
    root = private_root(root)
    validate_origin(origin)
    if app_family not in APP_FAMILIES: raise BrokerError("invalid_app_family")
    if (root / "config.json").exists(): raise BrokerError("broker_already_initialized")
    executable = shutil.which("openssl")
    if not executable: raise BrokerError("openssl_required_for_local_tls_identity")
    key, certificate = root / "server.key", root / "server.pem"
    previous = os.umask(0o077)
    try:
        subprocess.run([executable, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
                        "-keyout", str(key), "-out", str(certificate), "-subj", "/CN=Bicino Local Diagnostics"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    finally:
        os.umask(previous)
    der = ssl.PEM_cert_to_DER_cert(certificate.read_text())
    configuration = {"schema": 2, "brokerID": str(uuid.uuid4()), "baseURL": origin.rstrip("/"),
                     "certificateSHA256": hashlib.sha256(der).hexdigest(), "appFamily": app_family,
                     "phoneToken": secrets.token_hex(32), "controlToken": secrets.token_hex(32),
                     "expiresAtEpoch": int(time.time()) + 30 * 86400}
    atomic_json(root / "config.json", configuration)
    enrollment = {key: value for key, value in configuration.items() if key not in ("phoneToken", "controlToken")}
    enrollment["token"] = configuration["phoneToken"]
    enrollment["permissions"] = ["read", "capture", "collect"]
    atomic_json(root / "enrollment.json", enrollment)
    return {"schema": 2, "enrollmentFile": str(root / "enrollment.json"), "baseURL": configuration["baseURL"],
            "appFamily": app_family, "expiresAtEpoch": configuration["expiresAtEpoch"],
            "warning": "Enrollment contains a secret; import it into the matching iPhone app. Never paste it into chat or commit it."}


def validate_device_status(value: Any) -> None:
    keys = {"schema", "contractSHA256", "captureID", "generation", "effectiveLevels", "remainingSeconds", "filtered", "rateLimited", "durableSequence", "markerQueued", "markerDurable", "policyPersisted", "detailedAutomationAvailable", "crashAvailable"}
    if not isinstance(value, dict) or set(value) != keys or value["schema"] != 2:
        raise BrokerError("invalid_device_status")
    from .cli import contract
    if not SHA.fullmatch(str(value["contractSHA256"])) or (value["captureID"] != "" and not UUID.fullmatch(str(value["captureID"]))):
        raise BrokerError("invalid_device_identity")
    if not isinstance(value["effectiveLevels"], str) or len(value["effectiveLevels"]) != len(contract()["categories"]) or set(value["effectiveLevels"]) - set("012345"):
        raise BrokerError("invalid_effective_levels")
    for key in ("generation","remainingSeconds","filtered","rateLimited","durableSequence","markerQueued","markerDurable"):
        if type(value[key]) is not int or not 0 <= value[key] <= 2**32-1: raise BrokerError("invalid_device_counter")
    if value["remainingSeconds"] > 14400 or value["markerDurable"] > value["markerQueued"]: raise BrokerError("invalid_device_checkpoint")
    if any(type(value[k]) is not bool for k in ("policyPersisted","detailedAutomationAvailable","crashAvailable")):
        raise BrokerError("invalid_device_flags")


def validate_live_tail(value: Any) -> None:
    keys = {"schema", "source", "bootSequence", "requestedBoot", "requestedAfter", "nextSequence", "oldestSequence", "newestSequence", "bootChanged", "gap", "more", "liveDropped", "durableSequence", "durableSequenceValid", "events"}
    if not isinstance(value, dict) or set(value) != keys or value["schema"] != 2 or value["source"] != "firmware": raise BrokerError("invalid_firmware_tail")
    for key in ("bootSequence","requestedBoot","requestedAfter","nextSequence","oldestSequence","newestSequence","liveDropped","durableSequence"):
        if type(value[key]) is not int or not 0 <= value[key] <= 2**32-1: raise BrokerError("invalid_tail_cursor")
    for key in ("bootChanged","gap","more","durableSequenceValid"):
        if type(value[key]) is not bool: raise BrokerError("invalid_tail_state")
    if not isinstance(value["events"], list) or len(value["events"]) > 8: raise BrokerError("invalid_tail_events")
    previous = None
    for event in value["events"]:
        legacy.validate_event(event, "live/firmware")
        if event["source"] != "firmware" or event.get("fields", {}).get("bootSequence") != value["bootSequence"] or (previous is not None and event["sequence"] <= previous): raise BrokerError("invalid_tail_stream")
        previous = event["sequence"]
    if previous is not None and previous != value["nextSequence"]: raise BrokerError("invalid_tail_next_cursor")


class Store:
    def __init__(self, root: Path):
        self.root = private_root(root)
        self.lock = threading.RLock()
        for name in ("jobs", "uploads", "artifacts"):
            private_root(self.root / name)
        self.config = load_json(root / "config.json")
        if self.config.get("schema") != 2: raise BrokerError("invalid_broker_configuration")
        validate_origin(self.config["baseURL"])

    def path(self, kind: str, identity: str, suffix: str = ".json") -> Path:
        if not (UUID.fullmatch(identity) or SHA.fullmatch(identity)): raise BrokerError("invalid_identity")
        return self.root / kind / (identity + suffix)

    def job(self, identity: str) -> dict[str, Any]:
        return load_json(self.path("jobs", identity))

    def enqueue(self, value: Any) -> dict[str, Any]:
        if not isinstance(value, dict) or set(value) != {"id", "kind", "arguments", "deviceDigest", "expiresAtEpoch"}:
            raise BrokerError("invalid_command_shape")
        if not UUID.fullmatch(str(value["id"])) or value["kind"] not in COMMANDS or not re.fullmatch(r"[0-9a-f]{16}", str(value["deviceDigest"])):
            raise BrokerError("invalid_command")
        expiry = value["expiresAtEpoch"]
        if type(expiry) is not int or not time.time() < expiry <= time.time() + 86401:
            raise BrokerError("invalid_command_expiry")
        self.validate_arguments(value["kind"], value["arguments"])
        path = self.path("jobs", value["id"])
        with self.lock:
            if path.exists():
                retained = self.job(value["id"])
                if {key: retained[key] for key in value} != value: raise BrokerError("command_identity_conflict")
                return retained
            if len(list((self.root / "jobs").glob("*.json"))) >= MAX_JOBS: raise BrokerError("job_retention_full")
            job = dict(value, state="queued", createdAtEpoch=int(time.time()), result=None)
            atomic_json(path, job)
            return job

    @staticmethod
    def validate_arguments(kind: str, arguments: Any) -> None:
        if not isinstance(arguments, dict) or len(json.dumps(arguments)) > 16 * 1024: raise BrokerError("invalid_arguments")
        from .cli import contract
        registry = contract()
        if kind == "capture.start":
            allowed = {"captureID", "generation", "profile", "durationSeconds", "createdAtEpoch", "levels"}
            if set(arguments) != allowed or not UUID.fullmatch(str(arguments["captureID"])):
                raise BrokerError("invalid_capture_request")
            if type(arguments["generation"]) is not int or not 0 < arguments["generation"] <= 2**32 - 1:
                raise BrokerError("invalid_generation")
            if type(arguments["durationSeconds"]) is not int or not 1 <= arguments["durationSeconds"] <= 14400:
                raise BrokerError("invalid_capture_duration")
            if type(arguments["createdAtEpoch"]) is not int or not time.time() - 300 <= arguments["createdAtEpoch"] <= time.time() + 10:
                raise BrokerError("invalid_capture_clock")
            if not isinstance(arguments["profile"], str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", arguments["profile"]):
                raise BrokerError("invalid_profile")
            if not isinstance(arguments["levels"], dict) or not all(domain in registry["categories"] and level in registry["levels"] for domain, level in arguments["levels"].items()):
                raise BrokerError("unsupported_domain_or_level")
        elif kind == "capture.end":
            if set(arguments) != {"captureID"} or not UUID.fullmatch(str(arguments["captureID"])): raise BrokerError("invalid_capture_identity")
        elif kind == "mark":
            if set(arguments) != {"code"} or arguments["code"] not in {"navigation_wrong", "device_blank", "connection_drop", "sensor_missing", "other"}: raise BrokerError("invalid_issue_code")
        elif kind == "observe":
            if set(arguments) != {"bootSequence", "after", "limit"} or any(type(arguments[k]) is not int or not 0 <= arguments[k] <= 2**32-1 for k in ("bootSequence", "after")) or type(arguments["limit"]) is not int or not 1 <= arguments["limit"] <= 8:
                raise BrokerError("invalid_observation_cursor")
        elif kind == "collect":
            if set(arguments) - {"captureID"} or (arguments.get("captureID") is not None and not UUID.fullmatch(str(arguments["captureID"]))): raise BrokerError("invalid_capture_identity")

    def next_command(self) -> dict[str, Any] | None:
        with self.lock:
            candidates = []
            for path in sorted((self.root / "jobs").glob("*.json")):
                job = load_json(path)
                if job["state"] not in ("queued", "leased"): continue
                if job["expiresAtEpoch"] <= time.time():
                    job["state"] = "expired"; atomic_json(path, job); continue
                candidates.append(job)
            if not candidates: return None
            # A deferred bulk collection must not block a capture/marker.
            selected = min(candidates, key=lambda item: (item["kind"] == "collect", item["createdAtEpoch"], item["id"]))
            selected["state"] = "leased"; atomic_json(self.path("jobs", selected["id"]), selected)
            return {key: selected[key] for key in ("id", "kind", "arguments", "deviceDigest", "expiresAtEpoch")}

    def complete(self, identity: str, result: Any) -> dict[str, Any]:
        if not isinstance(result, dict) or type(result.get("ok")) is not bool or len(json.dumps(result)) > 64 * 1024:
            raise BrokerError("invalid_result")
        if set(result) - {"ok", "code", "artifactSHA256", "collectionID", "captureID", "receipt", "incidentID", "devicePersistence", "iphoneCaptureMayBeActive", "tail"}:
            raise BrokerError("unsupported_result_fields")
        if result.get("code") is not None and not re.fullmatch(r"[a-z0-9_]{1,80}", str(result["code"])):
            raise BrokerError("invalid_result_code")
        if result.get("tail") is not None: validate_live_tail(result["tail"])
        if result.get("receipt") is not None: validate_device_status(result["receipt"])
        with self.lock:
            job = self.job(identity)
            if job["state"] in ("completed", "failed"):
                if job["result"] != result: raise BrokerError("result_conflict")
                return job
            if job["state"] != "leased": raise BrokerError("command_not_leased")
            if result["ok"] and job["kind"] == "collect":
                artifact = str(result.get("artifactSHA256", ""))
                if not SHA.fullmatch(artifact) or not self.path("artifacts", artifact, ".zip").exists():
                    raise BrokerError("artifact_not_verified")
            job["state"] = "completed" if result["ok"] else "failed"
            job["result"] = result; job["finishedAtEpoch"] = int(time.time())
            atomic_json(self.path("jobs", identity), job)
            return job

    def _finish_upload(self, identity: str, value: dict[str, Any]) -> dict[str, Any]:
        """Replayable commit: bytes -> validated artifact -> receipt.

        A power cut at either rename/receipt boundary is recovered on the next
        status request. Invalid bytes are never exposed as a verified artifact.
        """
        partial = self.path("uploads", identity, ".part")
        destination = self.path("artifacts", value["sha256"], ".zip")
        candidate = partial if partial.exists() else destination
        try:
            if candidate.is_symlink() or not candidate.is_file() or candidate.stat().st_size != value["totalBytes"]:
                raise BrokerError("upload_file_unavailable")
            if sha256_file(candidate) != value["sha256"]:
                raise BrokerError("upload_digest_mismatch")
            summary, _ = read_bundle(candidate)
        except (BrokerError, EvidenceError, legacy.DiagnosticError, OSError, zipfile.BadZipFile) as error:
            # Reset only the uncommitted transfer. The immutable hash identity
            # still prevents replacing this job with a different artifact.
            if partial.exists() and not partial.is_symlink(): partial.unlink()
            value = dict(value, received=0, complete=False, failure="artifact_validation_failed")
            atomic_json(self.path("uploads", identity), value)
            raise BrokerError("artifact_validation_failed") from error
        if candidate == partial:
            os.replace(partial, destination)
        atomic_json(self.path("artifacts", value["sha256"]), summary)
        value = dict(value, complete=True)
        value.pop("failure", None)
        atomic_json(self.path("uploads", identity), value)
        return value

    def upload_status(self, identity: str) -> dict[str, Any]:
        self.job(identity)
        path = self.path("uploads", identity)
        with self.lock:
            if not path.exists(): return {"received": 0, "complete": False}
            value = load_json(path)
            partial = self.path("uploads", identity, ".part")
            if value["complete"]:
                artifact = self.path("artifacts", value["sha256"], ".zip")
                if artifact.is_symlink() or not artifact.is_file():
                    raise BrokerError("verified_artifact_unavailable")
            else:
                if partial.is_symlink(): raise BrokerError("unsafe_upload_path")
                if partial.exists() and partial.stat().st_size > value["received"]:
                    with partial.open("r+b") as file:
                        file.truncate(value["received"]); file.flush(); os.fsync(file.fileno())
                if value["received"] == value["totalBytes"]:
                    return self._finish_upload(identity, value)
                if (not partial.exists() and value["received"] != 0) or (partial.exists() and partial.stat().st_size < value["received"]):
                    raise BrokerError("committed_partial_bytes_missing")
            return value

    def append_upload(self, identity: str, digest: str, total: int, offset: int, body: bytes, chunk_hash: str) -> dict[str, Any]:
        if not SHA.fullmatch(digest) or not 0 < total <= MAX_BUNDLE or not 0 <= offset < total or not 0 < len(body) <= MAX_BODY or offset + len(body) > total:
            raise BrokerError("invalid_upload_range")
        if hashlib.sha256(body).hexdigest() != chunk_hash: raise BrokerError("upload_slice_hash_mismatch")
        with self.lock:
            job = self.job(identity)
            if job["kind"] != "collect" or job["state"] not in ("leased", "completed"):
                raise BrokerError("upload_not_authorized_for_command")
            value = self.upload_status(identity)
            if value.get("sha256") not in (None, digest) or value.get("totalBytes") not in (None, total):
                raise BrokerError("upload_identity_conflict")
            if value.get("complete"): return value
            partial = self.path("uploads", identity, ".part")
            if offset != value["received"]: raise BrokerError("upload_offset_conflict")
            used = sum(path.stat().st_size for kind in ("uploads", "artifacts") for path in (self.root / kind).iterdir() if path.is_file())
            if used + len(body) > MAX_INBOX: raise BrokerError("artifact_retention_full")
            if partial.is_symlink(): raise BrokerError("unsafe_upload_path")
            flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(partial, flags, 0o600)
            with os.fdopen(descriptor, "r+b") as file:
                if os.fstat(file.fileno()).st_size != offset: raise BrokerError("partial_file_length_mismatch")
                file.seek(offset); file.write(body); file.flush(); os.fsync(file.fileno())
            received = offset + len(body)
            value = {"received": received, "complete": False, "sha256": digest, "totalBytes": total}
            atomic_json(self.path("uploads", identity), value)
            if received == total:
                return self._finish_upload(identity, value)
            return value

    def heartbeat(self, value: Any) -> None:
        if not isinstance(value, dict) or value.get("schema") != 2 or value.get("appFamily") != self.config["appFamily"]:
            raise BrokerError("wrong_app_family")
        if set(value) - {"schema", "appFamily", "deviceDigest", "device", "iphone", "rideActive", "foreground", "capture", "tail"}:
            raise BrokerError("unsupported_heartbeat_fields")
        if value.get("deviceDigest") is not None and not re.fullmatch(r"[0-9a-f]{16}", str(value["deviceDigest"])):
            raise BrokerError("invalid_device_digest")
        for key in ("rideActive", "foreground"):
            if type(value.get(key)) is not bool: raise BrokerError("invalid_phone_state")
        phone = value.get("iphone")
        allowed = {"contractSHA256", "levels", "domains", "retainedBytes", "droppedEvents", "appVersion", "appBuild"}
        if not isinstance(phone, dict) or set(phone) != allowed: raise BrokerError("invalid_phone_capabilities")
        from .cli import contract
        registry = contract()
        if not SHA.fullmatch(str(phone["contractSHA256"])) or phone["levels"] != registry["levels"] or phone["domains"] != registry["categories"]:
            raise BrokerError("unsupported_phone_contract")
        for key in ("retainedBytes", "droppedEvents"):
            if type(phone[key]) is not int or not 0 <= phone[key] <= 2**63-1: raise BrokerError("invalid_phone_counter")
        for key in ("appVersion", "appBuild"):
            if not re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", str(phone[key])): raise BrokerError("invalid_build_identity")
        if value.get("device") is not None: validate_device_status(value["device"])
        if value.get("capture") is not None:
            capture = value["capture"]
            allowed_capture = {"schema", "captureID", "generation", "profile", "createdAt", "expiresAt", "durationSeconds", "levels"}
            if not isinstance(capture, dict) or set(capture) != allowed_capture or capture["schema"] != 2:
                raise BrokerError("invalid_capture_receipt")
            if not UUID.fullmatch(str(capture["captureID"]).lower()) or not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", str(capture["profile"])):
                raise BrokerError("invalid_capture_receipt")
            if type(capture["generation"]) is not int or not 0 < capture["generation"] <= 2**32-1 or type(capture["durationSeconds"]) is not int or not 0 <= capture["durationSeconds"] <= 14400:
                raise BrokerError("invalid_capture_receipt")
            import math
            if any(type(capture[k]) not in (int,float) or not math.isfinite(capture[k]) for k in ("createdAt","expiresAt")):
                raise BrokerError("invalid_capture_clock")
            if not isinstance(capture["levels"], dict) or not all(d in registry["categories"] and level in registry["levels"] for d,level in capture["levels"].items()):
                raise BrokerError("unsupported_capture_levels")
        tail = value.get("tail", [])
        if not isinstance(tail, list) or len(tail) > 32: raise BrokerError("invalid_live_tail")
        for event in tail:
            legacy.validate_event(event, "live/iphone")
            if event["source"] != "ios": raise BrokerError("invalid_live_source")
        if len(json.dumps(value)) > 64 * 1024: raise BrokerError("heartbeat_too_large")
        value = dict(value, receivedAtEpoch=int(time.time()))
        atomic_json(self.root / "heartbeat.json", value)

    def status(self) -> dict[str, Any]:
        path = self.root / "heartbeat.json"
        heartbeat = load_json(path) if path.exists() else None
        age = max(0, int(time.time()) - heartbeat["receivedAtEpoch"]) if heartbeat else None
        return {"schema": 2, "brokerID": self.config["brokerID"], "phone": heartbeat,
                "heartbeatAgeSeconds": age, "phoneFresh": age is not None and age <= 15,
                "commandKinds": sorted(COMMANDS), "destructiveHardwareActions": False}


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    def __init__(self, address: tuple[str, int], store: Store):
        self.store = store
        self.slots = threading.BoundedSemaphore(12)
        self.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.tls.minimum_version = ssl.TLSVersion.TLSv1_2
        self.tls.load_cert_chain(store.root / "server.pem", store.root / "server.key")
        super().__init__(address, Handler)
    def process_request(self, request: socket.socket, client_address: Any) -> None:
        if not self.slots.acquire(blocking=False): request.close(); return
        super().process_request(request, client_address)
    def process_request_thread(self, request: socket.socket, client_address: Any) -> None:
        try:
            request.settimeout(10)
            secure = self.tls.wrap_socket(request, server_side=True)
            super().process_request_thread(secure, client_address)
        except (OSError, ssl.SSLError): request.close()
        finally: self.slots.release()
    def handle_error(self, request: Any, client_address: Any) -> None:
        # Never dump request bodies, credential headers, or local state paths.
        pass


class Handler(BaseHTTPRequestHandler):
    server: Server
    protocol_version = "HTTP/1.1"
    def log_message(self, *_: Any) -> None: pass
    def reply(self, status: int, value: Any) -> None:
        raw = json.dumps(value, sort_keys=True, allow_nan=False).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw))); self.send_header("Connection", "close")
        self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(raw)
        self.close_connection = True
    def role(self) -> str:
        values = self.headers.get_all("Authorization", [])
        if len(values) != 1 or not values[0].startswith("Bearer "): raise PermissionError("unauthorized")
        token = values[0][7:]
        if self.server.store.config["expiresAtEpoch"] <= time.time(): raise PermissionError("enrollment_expired")
        for role, key in (("phone", "phoneToken"), ("control", "controlToken")):
            if hmac.compare_digest(token, self.server.store.config[key]): return role
        raise PermissionError("unauthorized")
    def body(self, maximum: int = 64 * 1024) -> bytes:
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1 or not re.fullmatch(r"0|[1-9][0-9]{0,8}", lengths[0]):
            raise BrokerError("content_length_required")
        length = int(lengths[0])
        if length > maximum: raise BrokerError("request_too_large")
        raw = self.rfile.read(length)
        if len(raw) != length: raise BrokerError("short_request_body")
        return raw
    def do_GET(self) -> None: self.dispatch("GET")
    def do_POST(self) -> None: self.dispatch("POST")
    def dispatch(self, method: str) -> None:
        try:
            role = self.role(); store = self.server.store
            path = self.path
            if len(path) > 256 or "?" in path or "%" in path or ".." in path: raise BrokerError("invalid_path")
            if method == "GET" and path == "/v2/status" and role == "control":
                return self.reply(200, store.status())
            if method == "POST" and path == "/v2/heartbeat" and role == "phone":
                store.heartbeat(strict_json(self.body())); return self.reply(200, {"ok": True})
            if method == "GET" and path == "/v2/next" and role == "phone":
                return self.reply(200, {"command": store.next_command()})
            if method == "POST" and path == "/v2/jobs" and role == "control":
                return self.reply(200, store.enqueue(strict_json(self.body())))
            if match := re.fullmatch(r"/v2/jobs/([0-9a-f-]{36})", path):
                identity = match[1]
                if method == "GET" and role == "control": return self.reply(200, store.job(identity))
                if method == "POST" and role == "phone": return self.reply(200, store.complete(identity, strict_json(self.body())))
            if match := re.fullmatch(r"/v2/uploads/([0-9a-f-]{36})", path):
                if method == "GET" and role == "phone": return self.reply(200, store.upload_status(match[1]))
            if match := re.fullmatch(r"/v2/uploads/([0-9a-f-]{36})/([0-9a-f]{64})/([0-9]{1,9})/([0-9]{1,9})", path):
                if method == "POST" and role == "phone":
                    result = store.append_upload(match[1], match[2], int(match[3]), int(match[4]), self.body(MAX_BODY), self.headers.get("X-Bicino-Chunk-SHA256", ""))
                    return self.reply(200, result)
            if match := re.fullmatch(r"/v2/artifacts/([0-9a-f]{64})", path):
                if method == "GET" and role == "control":
                    artifact = store.path("artifacts", match[1], ".zip")
                    if artifact.is_symlink() or not artifact.is_file(): raise BrokerError("artifact_unavailable")
                    self.send_response(200); self.send_header("Content-Type", "application/zip")
                    self.send_header("Content-Length", str(artifact.stat().st_size)); self.send_header("Connection", "close")
                    self.send_header("Cache-Control", "no-store"); self.end_headers()
                    with artifact.open("rb") as file: shutil.copyfileobj(file, self.wfile, 64 * 1024)
                    self.close_connection = True; return
            self.reply(404, {"ok": False, "code": "not_found"})
        except PermissionError:
            self.reply(401, {"ok": False, "code": "unauthorized_or_expired"})
        except (BrokerError, EvidenceError, legacy.DiagnosticError) as error:
            self.reply(409, {"ok": False, "code": str(error).split(":", 1)[0]})
        except (OSError, KeyError, ValueError, zipfile.BadZipFile):
            self.reply(400, {"ok": False, "code": "invalid_or_unavailable_request"})


def request(root: Path, method: str, path: str, value: Any = None, *, output: Path | None = None) -> dict[str, Any]:
    configuration = load_json(private_root(root) / "config.json")
    host, port = validate_origin(configuration["baseURL"])
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    connection = http.client.HTTPSConnection(host, port, context=context, timeout=30)
    try:
        # Explicit handshake/pin before sending any bearer credential. stdlib
        # direct sockets do not inherit HTTP proxy environment variables.
        connection.connect()
        if connection.sock is None or hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest() != configuration["certificateSHA256"]:
            raise BrokerError("tls_pin_mismatch")
        body = None if value is None else json.dumps(value, sort_keys=True, allow_nan=False).encode()
        connection.request(method, path, body=body, headers={"Authorization": "Bearer " + configuration["controlToken"], "Content-Type": "application/json", "Connection": "close"})
        response = connection.getresponse()
        if response.status != 200: raise BrokerError("broker_http_" + str(response.status))
        if output is not None:
            length = int(response.getheader("Content-Length", "-1"))
            if not 0 < length <= MAX_BUNDLE: raise BrokerError("invalid_artifact_length")
            if output.exists(): raise BrokerError("output_already_exists")
            output.parent.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            received = 0
            try:
                with os.fdopen(descriptor, "wb") as file:
                    while block := response.read(64 * 1024):
                        received += len(block)
                        if received > length: raise BrokerError("oversized_artifact")
                        file.write(block)
                    file.flush(); os.fsync(file.fileno())
                if received != length: raise BrokerError("truncated_artifact")
                return {"path": str(output), "bytes": received, "sha256": sha256_file(output)}
            except BaseException:
                output.unlink(missing_ok=True); raise
        raw = response.read(128 * 1024 + 1)
        if len(raw) > 128 * 1024: raise BrokerError("oversized_response")
        result = strict_json(raw)
        if not isinstance(result, dict): raise BrokerError("invalid_response")
        return result
    finally:
        connection.close()
