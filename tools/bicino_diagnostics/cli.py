"""One bounded, machine-readable entry point for local and post-ride evidence.

Commands never select the first attached device, reboot, flash or relax TLS.
Accepted remote commands are not reported as completed device actions.
"""
from __future__ import annotations

import argparse
import base64
from collections import Counter
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import sqlite3
import sys
import tempfile
import time
import uuid
import zipfile

import ride_diagnostics as v1
from . import broker
from .bundle import EvidenceError, open_evidence

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = ROOT / 'protocol/diagnostics/registry-v2.json'
MAX_OUTPUT = 64 * 1024
PROFILES = {
    'ble-navigation': ('ble', 'navigation', 'gps', 'rideAutomation'),
    'map-rendering': ('map', 'storage', 'memory'),
    'transfer': ('transfer', 'storage', 'memory', 'ble'),
    'power': ('power', 'boot', 'lifecycle', 'memory'),
}


def registry() -> tuple[dict, str]:
    raw = REGISTRY.read_bytes()
    # The generated C++/Swift identity hashes these exact canonical bytes.
    data = json.loads(raw)
    return data, hashlib.sha256(json.dumps(data,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def emit(value: dict) -> None:
    encoded = json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)
    if len(encoded.encode()) > MAX_OUTPUT:
        raise EvidenceError('result exceeds output budget; narrow filters or use a smaller page')
    print(encoded)


def duration(value: str) -> int:
    match = re.fullmatch(r'([1-9][0-9]{0,4})(s|m|h)?', value)
    if not match:
        raise argparse.ArgumentTypeError('duration must be 1s through 4h')
    result = int(match[1]) * {None: 1, 's': 1, 'm': 60, 'h': 3600}[match[2]]
    if not 1 <= result <= 14400:
        raise argparse.ArgumentTypeError('duration must be 1s through 4h')
    return result


def target(value: str) -> str:
    if value != 'iphone' and not re.fullmatch('[0-9a-f]{16}', value):
        raise argparse.ArgumentTypeError('use iphone or the exact pseudonymous deviceDigest from capabilities/status')
    return value


def existing_broker(root: Path) -> Path:
    # A read command must not create an empty broker and pretend it is paired.
    root = root.expanduser().absolute()
    if not (root / 'credentials.json').is_file():
        raise EvidenceError('broker is not initialized; run diag broker init on the paired Mac')
    return root


def observed(root: Path, device: str) -> tuple[dict, dict]:
    state = broker.request(existing_broker(root), 'GET', '/v2/status')
    phone = state.get('phone')
    age = state.get('phoneStatusAgeSeconds')
    if not isinstance(phone, dict) or type(age) is not int or not 0 <= age <= 20:
        raise EvidenceError('no fresh iPhone observation; open the paired app on the same LAN')
    data, identity = registry()
    if phone.get('registryDigest') != identity:
        raise EvidenceError('phone registry differs from this checkout; use its matching source or update deliberately')
    if device == 'iphone':
        supported = sum(1 << data['domains'].index(name) for name in data['instrumentedDomains'])
        capabilities = {'schema': 2, 'schemaDigest': identity, 'supportedMask': supported,
                        'requestedPolicy': phone.get('phonePolicy'), 'rawPayloads': False}
    else:
        if phone.get('deviceDigest') != device:
            raise EvidenceError('requested device is not the freshly observed connected device')
        capabilities = phone.get('firmwarePolicy')
        if not isinstance(capabilities, dict) or capabilities.get('schemaDigest') != identity:
            raise EvidenceError('device does not expose this diagnostics schema; no capture command was sent')
    return phone, capabilities


def enqueue(root: Path, kind: str, device: str, parameters: dict) -> dict:
    command = broker.request(existing_broker(root), 'POST', '/v2/commands',
                             {'kind': kind, 'target': device, 'parameters': parameters})
    return {'schema': 2, 'state': 'queued', 'command': command,
            'next': 'Read diag status for the phone acknowledgement; accepted does not prove device persistence or delivery.'}


def filter_identity(args) -> dict:
    return {key: getattr(args, key, None) for key in (
        'source', 'category', 'level', 'capture', 'acquisition', 'device', 'operation', 'incident', 'since', 'until')}


def selected_events(evidence, filters: dict) -> list[dict]:
    data, _ = registry()
    levels = data['levels']
    minimum = levels.index(filters['level']) if filters.get('level') else 0
    since = v1._parse_timestamp(filters.get('since'))
    until = v1._parse_timestamp(filters.get('until'))
    if since and until and since > until:
        raise EvidenceError('since must precede until')
    result = []
    scope, acquisitions = evidence.resolve_scope(capture=filters.get('capture'),
        acquisition=filters.get('acquisition'), device=filters.get('device'))
    for event in evidence.scoped_events(scope, acquisitions):
        fields = event.get('fields', {})
        if filters.get('source') and event['source'] != filters['source']:
            continue
        if filters.get('category') and event['category'] != filters['category']:
            continue
        if levels.index(event['level']) < minimum:
            continue
        if filters.get('operation') and fields.get('operationId') != filters['operation']:
            continue
        if filters.get('incident') and fields.get('incidentId') != filters['incident']:
            continue
        stamp = v1._event_timestamp(event)
        if (since or until) and (stamp is None or (since and stamp < since) or (until and stamp > until)):
            continue
        result.append(event)
    return sorted(result, key=lambda event: (*v1._event_key(event), event['rawReference']['member']))


def query(args) -> dict:
    filters = filter_identity(args)
    signature = hashlib.sha256(json.dumps(filters, sort_keys=True).encode()).hexdigest()
    with open_evidence(args.bundle) as evidence:
        offset = 0
        if args.cursor:
            if len(args.cursor) > 1024:
                raise EvidenceError('invalid cursor')
            try:
                cursor = json.loads(base64.urlsafe_b64decode(args.cursor))
                if set(cursor) != {'schema', 'sha256', 'filters', 'offset'} or cursor['schema'] != 2 or cursor['sha256'] != evidence.sha256 or cursor['filters'] != signature or type(cursor['offset']) is not int or cursor['offset'] < 0:
                    raise EvidenceError('cursor belongs to different evidence or filters')
                offset = cursor['offset']
            except (ValueError, TypeError, KeyError) as exc:
                raise EvidenceError('invalid or stale cursor') from exc
        events = selected_events(evidence, filters)
        if offset > len(events):
            raise EvidenceError('cursor beyond evidence boundary')
        page, consumed = [], offset
        for event in events[offset:offset + args.limit]:
            # Reserve room for metadata and cursor in the 64 KiB tool response.
            if len(json.dumps(page + [event]).encode()) > 52 * 1024:
                break
            page.append(event)
            consumed += 1
        cursor = None
        if consumed < len(events):
            cursor = base64.urlsafe_b64encode(json.dumps({
                'schema': 2, 'sha256': evidence.sha256, 'filters': signature, 'offset': consumed,
            }, sort_keys=True).encode()).decode()
        return {'schema': 2, 'bundleSha256': evidence.sha256, 'events': page,
                'matchedEvents': len(events), 'returnedEvents': len(page), 'nextCursor': cursor,
                'ordering': 'derived wall time, source, storage sequence; rawReference preserves original order'}


def analyze(args) -> dict:
    with open_evidence(args.bundle) as evidence:
        events = selected_events(evidence, filter_identity(args))
        counts = Counter(f"{event['category']}.{event['event']}" for event in events)
        issues = [event for event in events if event['category'] == 'user' and event['event'] == 'issue_marker']
        noteworthy = [event for event in events if event['level'] in ('warning', 'error', 'fatal')]
        if args.around is not None:
            anchors = [v1._event_timestamp(event) for event in issues]
            anchors = [anchor for anchor in anchors if anchor is not None]
            noteworthy = [event for event in noteworthy if any(
                (stamp := v1._event_timestamp(event)) is not None and abs((stamp-anchor).total_seconds()) <= args.around
                for anchor in anchors)]
        return {'schema': 2, 'coverage': evidence.coverage(tuple(args.require.split(',')),
            capture=args.capture, acquisition=args.acquisition, device=args.device),
                'matchedEvents': len(events), 'eventFamilies': counts.most_common(30),
                'issueMarkers': issues[-10:], 'noteworthy': noteworthy[-15:],
                'interpretation': 'Evidence summary, not a causal diagnosis. Use query with the capture/operation and rawReferences before making findings.'}


def verify(args) -> tuple[dict, int]:
    with open_evidence(args.bundle) as evidence:
        value = evidence.coverage(tuple(args.require.split(',')),
            capture=args.capture, acquisition=args.acquisition, device=args.device)
        value['integrity'] = 'verified'
        complete = (not value['missingRequiredSources'] and value['delivery'] and
                    all(item['state'] == 'complete' for item in value['delivery']))
        return value, 3 if args.require_complete and not complete else 0


def import_bundle(args) -> dict:
    with open_evidence(args.bundle) as evidence:
        coverage = evidence.coverage()
        raw_digest = evidence.sha256
    destination = args.output.expanduser().absolute()
    if destination.exists() or destination.is_symlink() or any(p.is_symlink() for p in destination.parents):
        raise EvidenceError('output must be a new path without symlink ancestors')
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.bicino-', dir=destination.parent)
    try:
        with os.fdopen(fd, 'wb') as output, args.bundle.open('rb') as source:
            shutil.copyfileobj(source, output, length=64 * 1024)
            output.flush()
            os.fsync(output.fileno())
        if hashlib.sha256(Path(name).read_bytes()).hexdigest() != raw_digest:
            raise EvidenceError('source changed while importing')
        # Atomic no-clobber publication; a second process cannot be overwritten.
        os.link(name, destination)
    finally:
        Path(name).unlink(missing_ok=True)
    return {'schema': 2, 'path': str(destination), 'sha256': raw_digest, 'coverage': coverage}


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog='bicino', description=__doc__)
    groups = p.add_subparsers(dest='group', required=True)
    diag = groups.add_parser('diag')
    diag.add_argument('--broker-root', type=Path, default=broker.DEFAULT_ROOT)
    commands = diag.add_subparsers(dest='command', required=True)
    commands.add_parser('doctor')
    cap = commands.add_parser('capabilities')
    cap.add_argument('--device', type=target)
    cap.add_argument('--offline', action='store_true')
    commands.add_parser('status')
    b = commands.add_parser('broker').add_subparsers(dest='broker_command', required=True)
    initialize = b.add_parser('init')
    initialize.add_argument('--origin', required=True)
    initialize.add_argument('--pairing-file', type=Path, required=True)
    initialize.add_argument('--hours', type=int, default=8, choices=range(1, 25))
    serve = b.add_parser('serve')
    serve.add_argument('--listen', default='127.0.0.1')
    b.add_parser('status')
    b.add_parser('revoke')
    c = commands.add_parser('capture').add_subparsers(dest='capture_command', required=True)
    start = c.add_parser('start')
    start.add_argument('--device', type=target, required=True)
    choice = start.add_mutually_exclusive_group(required=True)
    choice.add_argument('--domains')
    choice.add_argument('--profile', choices=sorted(PROFILES))
    start.add_argument('--level', choices=['trace', 'debug', 'info'], default='debug')
    start.add_argument('--duration', type=duration, default=3600)
    start.add_argument('--budget-mib', type=int, choices=range(1,33), default=8)
    stop = c.add_parser('stop')
    stop.add_argument('--device', type=target, required=True)
    for name in ('collect', 'export', 'mark'):
        command = commands.add_parser(name)
        command.add_argument('--device', type=target, required=True)
        if name == 'mark':
            command.add_argument('--code', choices=['navigation_wrong', 'device_blank', 'connection_drop', 'sensor_missing', 'other'], required=True)
    live = commands.add_parser('live').add_subparsers(dest='live_command', required=True)
    for name in ('start','stop'):
        sub = live.add_parser(name)
        sub.add_argument('--device', type=target, required=True)
        if name == 'start':
            sub.add_argument('--seconds', type=int, default=60, choices=range(1,301))
    tail = commands.add_parser('tail')
    tail.add_argument('--device', type=target, required=True)
    tail.add_argument('--cursor')
    tail.add_argument('--limit', type=int, default=25, choices=range(1,51))
    inbox = commands.add_parser('inbox').add_subparsers(dest='inbox_command', required=True)
    inbox.add_parser('list')
    get = inbox.add_parser('get')
    get.add_argument('--id', type=uuid.UUID, required=True)
    get.add_argument('--output', type=Path, required=True)
    imp = commands.add_parser('import')
    imp.add_argument('bundle', type=Path)
    imp.add_argument('--output', type=Path, required=True)
    for name in ('verify', 'query', 'analyze'):
        command = commands.add_parser(name)
        command.add_argument('bundle', type=Path)
        command.add_argument('--capture', help='Only evidence bound to this capture UUID')
        command.add_argument('--acquisition', help='Only the original inventory for this collection UUID')
        command.add_argument('--device', type=target, help='An explicit firmware digest, or iphone')
        if name != 'query':
            command.add_argument('--require', default='ios,firmware')
        if name == 'verify':
            command.add_argument('--require-complete', action='store_true')
        else:
            command.add_argument('--source', choices=['ios','firmware','host'])
            command.add_argument('--category')
            command.add_argument('--level', choices=['trace','debug','info','warning','error','fatal'])
            command.add_argument('--operation')
            command.add_argument('--incident')
            command.add_argument('--since')
            command.add_argument('--until')
        if name == 'query':
            command.add_argument('--limit', type=int, default=25, choices=range(1,101))
            command.add_argument('--cursor')
        if name == 'analyze':
            command.add_argument('--around', type=int, choices=range(1,3601))
    return p


def run(args) -> tuple[dict | None, int]:
    data, identity = registry()
    root = args.broker_root
    if hasattr(args, 'require') and not set(args.require.split(',')) <= {'ios','firmware','host'}:
        raise EvidenceError('require must list ios,firmware,host')
    if args.command == 'doctor':
        return {'schema': 2, 'host': platform.system(), 'registryDigest': identity,
                'brokerInitialized': (root/'credentials.json').is_file(),
                'xcrunAvailable': shutil.which('xcrun') is not None,
                'opensslAvailable': shutil.which('openssl') is not None,
                'hardwareProbed': False, 'sideEffects': [],
                'remoteCodex': 'A cloud checkout cannot access the Mac or iPhone directly. Import a deliberately shared evidence archive.'}, 0
    if args.command == 'capabilities':
        if args.offline:
            return {'schema':2, 'scope':'checked_in_contract_not_device_observation', 'registryDigest':identity,
                    'domains':data['domains'], 'instrumentedDomains':data['instrumentedDomains'],
                    'levels':data['levels'], 'rawPayloads':False}, 0
        if args.device is None:
            raise EvidenceError('capabilities requires --device or --offline')
        phone, capabilities = observed(root, args.device)
        return {'schema':2, 'scope':'fresh_phone_observation', 'device':args.device,
                'capabilities':capabilities, 'supportedDomains':[name for i,name in enumerate(data['domains']) if capabilities['supportedMask'] & (1<<i)]}, 0
    if args.command == 'status' or args.command == 'broker' and args.broker_command == 'status':
        return broker.request(existing_broker(root), 'GET', '/v2/status'), 0
    if args.command == 'broker':
        if args.broker_command == 'init':
            return broker.initialize(root, args.origin, args.pairing_file, args.hours), 0
        if args.broker_command == 'serve':
            broker.serve(existing_broker(root), args.listen)
            return None, 0
        store = broker.BrokerStore(existing_broker(root))
        config = store.config()
        config['expiresAt'] = 0
        config['token'] = secrets.token_hex(32)
        broker.write_private(store.root/'credentials.json', json.dumps(config,sort_keys=True).encode())
        return {'schema':2, 'revoked':True, 'evidencePreserved':True}, 0
    if args.command == 'live':
        observed(root, args.device)
        return enqueue(root, 'live' if args.live_command == 'start' else 'stop_live', args.device,
            {'durationSeconds':args.seconds} if args.live_command == 'start' else {}), 0
    if args.command == 'tail':
        cursor = None
        if args.cursor:
            if len(args.cursor)>1024: raise EvidenceError('invalid live cursor')
            cursor = json.loads(base64.urlsafe_b64decode(args.cursor))
        result = broker.request(existing_broker(root), 'POST', '/v2/live/query',
            {'device':args.device,'cursor':cursor,'limit':args.limit})
        if result.get('nextCursor') is not None:
            result['nextCursor'] = base64.urlsafe_b64encode(json.dumps(result['nextCursor'],sort_keys=True).encode()).decode()
        return result, 0
    if args.command == 'capture':
        _, caps = observed(root, args.device)
        if args.capture_command == 'stop':
            return enqueue(root, 'stop_capture', args.device, {}), 0
        names = PROFILES[args.profile] if args.profile else tuple(args.domains.split(','))
        if not names or len(set(names)) != len(names) or any(name not in data['domains'] for name in names):
            raise EvidenceError('unknown or duplicate domain')
        mask = sum(1<<data['domains'].index(name) for name in names)
        if mask & ~caps['supportedMask']:
            raise EvidenceError('requested domain is unavailable on the observed target')
        return enqueue(root, 'capture', args.device, {
            'mask':mask, 'minimumLevel':data['levels'].index(args.level),
            'durationSeconds':args.duration, 'budgetBytes':args.budget_mib*1024*1024,
            'registryDigest':identity}), 0
    if args.command in ('collect', 'export', 'mark'):
        observed(root, args.device)
        return enqueue(root, args.command, args.device, {'code':args.code} if args.command == 'mark' else {}), 0
    if args.command == 'inbox':
        store = broker.BrokerStore(existing_broker(root))
        state = store.status()
        if args.inbox_command == 'list':
            return {'schema':2, 'scope':'local_verified_inbox', 'bundles':state['bundles']}, 0
        selected = next((item for item in state['bundles'] if item['id'] == str(args.id)),None)
        if selected is None:
            raise EvidenceError('bundle not present in the local inbox')
        args.bundle = store.root/'bundles'/f'{args.id}.zip'
        if hashlib.sha256(args.bundle.read_bytes()).hexdigest() != selected['sha256']:
            raise EvidenceError('inbox bytes differ from their verified receipt')
        return import_bundle(args), 0
    if args.command == 'import': return import_bundle(args), 0
    if args.command == 'verify': return verify(args)
    if args.command == 'query': return query(args), 0
    if args.command == 'analyze': return analyze(args), 0
    raise EvidenceError('unsupported command')


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    # All results are JSON. Accept --json anywhere for agent/tool consistency.
    argv = [argument for argument in argv if argument != '--json']
    try:
        args = parser().parse_args(argv)
        value, result = run(args)
        if value is not None:
            emit(value)
        return result
    except KeyboardInterrupt:
        return 130
    except (EvidenceError, v1.DiagnosticError, OSError, ValueError, TypeError,
            KeyError, AttributeError, sqlite3.Error, zipfile.BadZipFile) as error:
        # Do not include response bodies, credentials or untrusted exception text.
        # Known local validation messages are deliberately controlled vocabulary.
        message = str(error) if isinstance(error, EvidenceError) else 'input or local operation failed; evidence was not modified'
        emit({'schema':2, 'ok':False, 'error':'diagnostics_failed', 'message':message})
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
