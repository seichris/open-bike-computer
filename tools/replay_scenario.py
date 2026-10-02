#!/usr/bin/env python3
"""Replay versioned scenarios against the actual production Swift queue."""
import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]


def validate(path):
    if path.is_symlink() or path.stat().st_size > 256 * 1024:
        raise ValueError('scenario must be a bounded regular file')
    value = json.loads(path.read_text())
    if set(value) != {'schema', 'id', 'module', 'maxCount', 'steps'} or value['schema'] != 1:
        raise ValueError('unsupported scenario schema')
    if value['module'] != 'navigation-write-queue' or not isinstance(value['id'], str) or not value['id']:
        raise ValueError('unsupported scenario module/id')
    if type(value['maxCount']) is not int or not 1 <= value['maxCount'] <= 64 or not isinstance(value['steps'], list) or not 1 <= len(value['steps']) <= 1000:
        raise ValueError('scenario limits exceeded')
    allowed = {'action','label','writeClass','key','milliseconds','canSend','depth','oldestAgeMs','coalesced','cleared','delivered','accepted'}
    for step in value['steps']:
        if not isinstance(step, dict) or set(step) - allowed or step.get('action') not in ('enqueue','advance','flush','disconnect','expect'):
            raise ValueError('unknown scenario action/field')
        if step['action'] == 'expect' and len(step) == 1:
            raise ValueError('empty assertion')
        for key in ('milliseconds','depth','oldestAgeMs','coalesced','cleared'):
            if key in step and (type(step[key]) is not int or not 0 <= step[key] <= 86400000):
                raise ValueError('invalid scenario integer')
        for key in ('canSend','accepted'):
            if key in step and type(step[key]) is not bool: raise ValueError('invalid scenario boolean')
        for key in ('label','key'):
            if key in step and (not isinstance(step[key], str) or not 1 <= len(step[key].encode()) <= 576):
                raise ValueError('invalid scenario label/key')
        if 'delivered' in step and (not isinstance(step['delivered'], list) or
                                   any(not isinstance(label, str) for label in step['delivered'])):
            raise ValueError('invalid delivery assertion')
        required = {'enqueue': {'label','writeClass'}, 'advance': {'milliseconds'}, 'flush': {'canSend'}}
        if not required.get(step['action'], set()) <= step.keys(): raise ValueError('incomplete scenario action')
    return value


def replay(paths):
    for path in paths: validate(path)
    compiler = ['xcrun','swiftc'] if os.uname().sysname == 'Darwin' else [shutil.which('swiftc') or 'swiftc']
    with tempfile.TemporaryDirectory(prefix='bicino-scenario-') as temporary:
        root = Path(temporary)
        # Compile and execute immutable copies of the bytes that were validated.
        fixtures = []
        for index, path in enumerate(paths):
            copy = root / f'{index}.json'; copy.write_bytes(path.read_bytes()); validate(copy); fixtures.append(str(copy))
        output = root / 'replay'
        subprocess.run([*compiler,'-D','HOST_TESTING','-o',str(output),
            str(ROOT / 'ios-app/BikeComputer/BikeComputer/Utilities/NavigationWriteQueue.swift'),
            str(ROOT / 'ios-app/tests/scenario-replay/main.swift')], check=True)
        subprocess.run([str(output),*fixtures], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scenario', nargs='*', type=Path)
    args = parser.parse_args()
    try: replay(args.scenario or sorted((ROOT / 'protocol/scenarios').glob('*.json')))
    except (OSError, ValueError, subprocess.SubprocessError) as error: parser.exit(1, f'Replay failed: {error}\n')
if __name__ == '__main__': main()
