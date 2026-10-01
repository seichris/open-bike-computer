#!/usr/bin/env python3
"""Analyze authenticated diagnostics JSONL, not physical/production acceptance."""
import argparse
import json
import re
from collections import Counter
from pathlib import Path

EVENTS = {"transfer_checkpoint", "transfer_resources", "transfer_stacks"}
POOLS = ("internal", "dma", "psram")
MODES = ("map", "firmware", "diagnostics", "debug")
PROFILES = {
    f"WAVESHARE_AMOLED_{board}{suffix}": MODES if suffix == "_REMOTE_DEBUG" else MODES[:3]
    for board in ("175", "206") for suffix in ("", "_PRODUCTION", "_REMOTE_DEBUG")
}
PHASES = {
    "transfer_entry", "network_ready", "commit_granted", "grant_released",
    "map_terminal", "before_map_activation", "after_map_activation", "boot_selected",
    "cancelled", "network_stopped", "owner_released", "shutdown_requested", "worker_failed",
    "operation_selected", "ota_begin",
}
POOL_METRICS = ("freeBytes", "largestBytes", "minimumFreeBytes", "minimumLargestBytes")
STACK_METRICS = ("tlsStackBytes", "ownerStackBytes", "rendererStackBytes")


def uint32(value, minimum=0, maximum=0xffffffff):
    return type(value) is int and minimum <= value <= maximum


def validate_event(event):
    if not isinstance(event, dict) or not isinstance(event.get("event"), str):
        return "expected an event object with a string event name"
    name = event["event"]
    if name not in EVENTS:
        return None
    fields = event.get("fields")
    if not isinstance(fields, dict):
        return "expected a fields object"
    for key in ("bootSequence", "attempt", "sampleCount"):
        if not uint32(fields.get(key), 1, 64 if key == "sampleCount" else 0xffffffff):
            return f"invalid or missing {key}"
    fingerprint = fields.get("firmwareFingerprint")
    if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-fA-F]{8}", fingerprint):
        return "invalid or missing firmwareFingerprint"
    if name == "transfer_checkpoint":
        if fields.get("mode") not in MODES or not isinstance(fields.get("phase"), str) or fields["phase"] not in PHASES:
            return "invalid or missing mode/phase"
        if type(fields.get("cleanupFailed")) is not bool:
            return "invalid or missing cleanupFailed"
    elif name == "transfer_resources":
        if fields.get("scope") not in POOLS:
            return "invalid or missing resource scope"
        for key in POOL_METRICS:
            if not uint32(fields.get(key)):
                return f"invalid or missing {key}"
    else:
        if not uint32(fields.get("stackAvailableMask"), maximum=7):
            return "invalid or missing stackAvailableMask"
        for key in STACK_METRICS:
            if not uint32(fields.get(key)):
                return f"invalid or missing {key}"
    return None


def load_events(paths):
    events, errors = [], []
    for path in paths:
        try:
            with path.open(encoding="utf-8") as stream:
                for number, line in enumerate(stream, 1):
                    if not line.strip():
                        continue
                    try:
                        events.append(json.loads(line))
                    except (json.JSONDecodeError, ValueError):
                        errors.append(f"{path}:{number}: invalid JSON")
        except (OSError, UnicodeError) as error:
            errors.append(f"{path}: cannot read diagnostics ({type(error).__name__})")
    return events, errors


def analyze(events, minimum_cycles=100, minimum_per_mode=20, required_modes=MODES):
    samples, errors = {}, []
    if not required_modes or any(mode not in MODES for mode in required_modes):
        errors.append("required modes must be a nonempty subset of supported modes")
    if not uint32(minimum_cycles, 1) or not uint32(minimum_per_mode, 1):
        errors.append("minimum cycle counts must be positive integers")
        minimum_cycles = minimum_per_mode = 1
    for index, event in enumerate(events, 1):
        error = validate_event(event)
        if error:
            errors.append(f"record {index}: {error}")
            continue
        if event.get("event") not in EVENTS:
            continue
        fields = event["fields"]
        key = (fields["bootSequence"], fields["firmwareFingerprint"].lower(),
               fields["attempt"], fields["sampleCount"])
        sample = samples.setdefault(key, {})
        name = fields["scope"] if event["event"] == "transfer_resources" else event["event"]
        if name in sample:
            errors.append(f"duplicate record {key}/{name}")
        sample[name] = fields
    fingerprints = {key[1] for key in samples}
    if len(fingerprints) > 1:
        errors.append("mixed firmware fingerprints; analyze exact candidates separately")
    cycles = {}
    stack_minima = {"tlsStackBytes": None, "ownerStackBytes": None, "rendererStackBytes": None}
    stack_missing = Counter()
    for key, sample in sorted(samples.items()):
        expected = {*POOLS, "transfer_checkpoint", "transfer_stacks"}
        if set(sample) != expected:
            errors.append(f"incomplete checkpoint {key}: {sorted(expected - set(sample))}")
            continue
        stacks = sample["transfer_stacks"]
        availability = stacks.get("stackAvailableMask", 0)
        for bit, name in enumerate(stack_minima):
            if availability & (1 << bit):
                value = stacks[name]
                if type(value) is not int or not 0 <= value <= 0xffffffff:
                    errors.append(f"invalid stack measurement {key}/{name}")
                else:
                    previous = stack_minima[name]
                    stack_minima[name] = value if previous is None else min(previous, value)
            else:
                stack_missing[name] += 1
        metadata = sample["transfer_checkpoint"]
        if metadata["cleanupFailed"]:
            errors.append(f"cleanup failure {key}")
        for pool in POOLS:
            for metric in ("freeBytes", "largestBytes", "minimumFreeBytes", "minimumLargestBytes"):
                value = sample[pool][metric]
                if type(value) is not int or not 0 <= value <= 0xffffffff:
                    errors.append(f"invalid metric {key}/{pool}/{metric}")
        cycles.setdefault(key[:3], []).append(sample)
    modes, baselines, completed = Counter(), {pool: [] for pool in POOLS}, 0
    for key, cycle in cycles.items():
        phases = [sample["transfer_checkpoint"]["phase"] for sample in cycle]
        if phases[0] != "transfer_entry" or "owner_released" not in phases:
            errors.append(f"incomplete cycle {key}: {phases}")
            continue
        ordinals = [sample["transfer_checkpoint"]["sampleCount"] for sample in cycle]
        if ordinals != list(range(1, ordinals[-1] + 1)) or ordinals[-1] >= 64:
            errors.append(f"missing or exhausted checkpoint sequence {key}")
        if "network_ready" not in phases:
            errors.append(f"startup did not reach network readiness {key}")
        completed += 1
        mode = cycle[0]["transfer_checkpoint"]["mode"]
        modes[mode] += 1
        if mode not in required_modes:
            errors.append(f"unsupported mode for selected profile {key}: {mode}")
        if any(sample["transfer_checkpoint"]["mode"] != mode for sample in cycle):
            errors.append(f"mode changed inside cycle {key}")
        for pool in POOLS:
            baselines[pool].append(cycle[0][pool])
    if completed < minimum_cycles:
        errors.append(f"only {completed}/{minimum_cycles} complete cycles")
    for mode in required_modes:
        if modes[mode] < minimum_per_mode:
            errors.append(f"only {modes[mode]}/{minimum_per_mode} {mode} cycles")
    trends = {}
    for pool, values in baselines.items():
        if values:
            trends[pool] = {metric: {"first": values[0][metric], "last": values[-1][metric],
                                    "delta": values[-1][metric] - values[0][metric],
                                    "minimum": min(v[metric] for v in values)}
                            for metric in ("freeBytes", "largestBytes")}
    return {"completeCycles": completed, "modeCounts": dict(modes),
            "requiredModes": list(required_modes),
            "entryBaselines": trends, "stackMinimaBytes": stack_minima,
            "stackUnavailableSamples": dict(stack_missing), "errors": errors,
            "evidenceComplete": not errors,
            "physicalAcceptance": "NOT ESTABLISHED; review reserves, stack minima, task/file leaks, SD and iPhone gates separately"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--profile", choices=tuple(PROFILES),
                        help="Exact attested profile; omitted means all four modes are required")
    parser.add_argument("--minimum-cycles", type=int, default=100)
    parser.add_argument("--minimum-per-mode", type=int, default=20)
    args = parser.parse_args()
    events, errors = load_events(args.files)
    modes = PROFILES[args.profile] if args.profile else MODES
    report = analyze(events, args.minimum_cycles, args.minimum_per_mode, modes)
    report["profile"] = args.profile or "unspecified; four-mode debug coverage required"
    report["errors"] = errors + report["errors"]
    report["evidenceComplete"] = not report["errors"]
    print(json.dumps(report, indent=2))
    return 0 if report["evidenceComplete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
