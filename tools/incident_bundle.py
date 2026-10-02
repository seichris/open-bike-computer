#!/usr/bin/env python3
"""Pin a scoped diagnostic bundle, scenario and exact-build symbol candidates."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
import re
import subprocess
import tempfile
import uuid
from pathlib import Path
import build_evidence as evidence
import replay_scenario
import ride_diagnostics

ROOT = Path(__file__).resolve().parents[1]


def context_data(path):
    context = evidence.read_json(path)
    allowed = {'schema','description','boardProfile','captureIds','operationIds','observedFailureAt'}
    if set(context) - allowed or context.get('schema') != 1:
        raise ValueError('unsupported incident context')
    if not isinstance(context.get('description'), str) or not 1 <= len(context['description']) <= 4096:
        raise ValueError('description must contain 1..4096 characters')
    if context.get('boardProfile') not in ('WAVESHARE_AMOLED_175','WAVESHARE_AMOLED_206','no-board'):
        raise ValueError('identify the actual board profile')
    captures = context.get('captureIds')
    if not isinstance(captures, list) or not captures or len(captures) != len(set(captures)):
        raise ValueError('select explicit capture IDs')
    for identifier in captures: uuid.UUID(identifier)
    for identifier in context.get('operationIds', []): uuid.UUID(identifier)
    if 'observedFailureAt' in context:
        date = datetime.fromisoformat(context['observedFailureAt'].replace('Z','+00:00'))
        if date.tzinfo is None: raise ValueError('failure timestamp needs a timezone')
    return context


def crash_data(path):
    # Apple .ips files can have one metadata JSON object followed by the report.
    if path.is_symlink() or path.stat().st_size > 32 * 1024**2: raise ValueError('unsafe native crash')
    text = path.read_text()
    decoder = json.JSONDecoder(); objects = []
    while text.strip():
        value, end = decoder.raw_decode(text.lstrip()); objects.append(value); text = text.lstrip()[end:]
    report = next((value for value in objects if isinstance(value, dict) and 'usedImages' in value), None)
    if report is None: raise ValueError('native crash has no usedImages UUID evidence')
    return report


def app_match(manifest, symbols, crash=None):
    candidates, matches = [], []
    for identifier, index in symbols:
        if index['kind'] != 'ios': continue
        identity = index['identity']
        if {key: identity.get(key) for key in ('version','build')} != manifest['appBuildIdentity']: continue
        candidates.append(identifier)
        if crash:
            info = crash.get('bundleInfo', {})
            if (info.get('CFBundleIdentifier') != identity['bundleIdentifier'] or
                info.get('CFBundleShortVersionString') != identity['version'] or
                info.get('CFBundleVersion') != identity['build']): continue
            images = [image for image in crash['usedImages'] if image.get('name') == identity.get('binaryName', 'BikeComputer')]
            crash_uuids = {str(uuid.UUID(image['uuid'])).upper() for image in images}
            symbol_uuids = {pair[0] for pair in identity['machOUUIDs']}
            if crash_uuids and crash_uuids <= symbol_uuids: matches.append(identifier)
    if len(matches) > 1: raise ValueError('ambiguous app symbol match')
    return {'candidateRecords': candidates, 'exactNativeCrashMatch': matches,
            'scope': 'native crash UUID; capture association is caller supplied' if matches else
                     'version/build candidates only; exact app image identity is missing'}


def create(bundle, context_path, scenario, records, root, native_crash=None):
    originals = {'bundle.zip': bundle, 'context.json': context_path, 'scenario.json': scenario}
    if native_crash: originals['native-crash.ips'] = native_crash
    expected_hashes = {name: evidence.sha(path) for name, path in originals.items()}
    context = context_data(context_path)
    manifest, streams = ride_diagnostics.validate_bundle(bundle)
    # Do not use a different capture's streams to fill this incident's coverage.
    if sorted(context['captureIds']) != sorted(manifest['selectedCaptureRange']):
        raise ValueError('bundle capture range must exactly match the incident scope; export a scoped bundle')
    replay_scenario.validate(scenario)
    symbols = [(record.name, evidence.verify(record)) for record in records]
    if len({identifier for identifier, _ in symbols}) != len(symbols): raise ValueError('duplicate symbols')
    crash = crash_data(native_crash) if native_crash else None
    app = app_match(manifest, symbols, crash)
    firmware = []
    for identifier, index in symbols:
        if index['kind'] == 'firmware':
            identity = index['identity']
            if not identity['environment'].startswith(context['boardProfile'] + '_') and identity['environment'] != context['boardProfile']:
                raise ValueError('firmware symbols target a different board profile')
            firmware.append({'record': identifier, 'identity': identity,
                'match': 'candidate only; schema-1 fingerprint does not prove the exact ELF/bin hash'})
    files = {'bundle.zip': bundle, 'context.json': context_path, 'scenario.json': scenario}
    for record in records:
        for path in record.rglob('*'):
            if path.is_file() or path.is_symlink():
                relative = f'symbols/{record.name}/{path.relative_to(record)}'
                files[relative] = path
                expected_hashes[relative] = evidence.sha(path)
    if native_crash: files['native-crash.ips'] = native_crash
    identity = {'createdAt': datetime.now(timezone.utc).isoformat(), 'context': context,
        'diagnosticSchema': manifest['schema'], 'appBuildIdentity': manifest['appBuildIdentity'],
        'firmwareBuildIdentities': manifest['firmwareBuildIdentities'],
        'sourceStreams': manifest.get('sourceStreams'), 'clock': {key: manifest.get(key) for key in ('oldestWallTime','newestWallTime','clockAnchorCount','uptimeEventCount','truncatedTailStreamCount')},
        'droppedEventCount': manifest.get('droppedEventCount'),
        'deviceDroppedEventCount': manifest.get('deviceDroppedEventCount'),
        'appSymbols': app, 'firmwareSymbols': firmware,
        'scenarioIdentity': replay_scenario.validate(scenario)['id'],
        'replayStatus': 'not-run',
        'physicalAcceptance': 'not established by an incident archive or host replay'}
    return evidence.publish('incident', identity, files, root, expected_hashes)


def verify(record):
    index = evidence.verify(record)
    if index['kind'] != 'incident': raise ValueError('expected an incident record')
    context = context_data(record / 'context.json')
    manifest, _ = ride_diagnostics.validate_bundle(record / 'bundle.zip')
    if sorted(context['captureIds']) != sorted(manifest['selectedCaptureRange']): raise ValueError('incident scope mismatch')
    if context != index['identity']['context']: raise ValueError('incident context mismatch')
    replay_scenario.validate(record / 'scenario.json')
    for symbols in (record / 'symbols').glob('*') if (record / 'symbols').exists() else []: evidence.verify(symbols)
    return index


def replay(record, root):
    index = verify(record)
    before = evidence.source()
    if before['dirty']: raise ValueError('replay receipts require clean committed source')
    started = datetime.now(timezone.utc)
    replay_scenario.replay([record / 'scenario.json'])
    if evidence.source() != before: raise ValueError('source changed during incident replay')
    finished = datetime.now(timezone.utc)
    result = {'schema': 1, 'incident': record.name, 'source': before,
              'scenarioSha256': evidence.sha(record / 'scenario.json'), 'startedAt': started.isoformat(),
              'completedAt': finished.isoformat(), 'status': 'passed',
              'scope': 'production module host replay; physical delivery is unverified'}
    reported = index['identity']['context'].get('observedFailureAt')
    if reported:
        failure = datetime.fromisoformat(reported.replace('Z','+00:00'))
        result['reportedFailureToReplaySeconds'] = (finished - failure).total_seconds()
        result['latencyBasis'] = 'caller-reported wall clock; includes clock uncertainty'
    with tempfile.TemporaryDirectory(prefix='bicino-replay-receipt-') as temporary:
        path = Path(temporary) / 'replay.json'; path.write_bytes(evidence.canonical(result) + b'\n')
        return evidence.publish('replay', result, {'replay.json': path}, root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    pin = commands.add_parser('create')
    pin.add_argument('--bundle', type=Path, required=True); pin.add_argument('--context', type=Path, required=True)
    pin.add_argument('--scenario', type=Path, required=True); pin.add_argument('--symbols', type=Path, action='append', default=[])
    pin.add_argument('--native-crash', type=Path)
    for name in ('verify','replay'):
        command = commands.add_parser(name); command.add_argument('record', type=Path)
    args = parser.parse_args()
    root = evidence.store_root().parent / 'incidents'
    try:
        if args.command == 'create': result = str(create(args.bundle, args.context, args.scenario, args.symbols, root, args.native_crash))
        elif args.command == 'verify': result = verify(args.record)
        else: result = str(replay(args.record, root / 'replays'))
        print(json.dumps(result))
    except (OSError, ValueError, KeyError, ride_diagnostics.DiagnosticError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Incident operation failed: {error}\n')
if __name__ == '__main__': main()
