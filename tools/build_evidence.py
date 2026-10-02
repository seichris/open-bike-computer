#!/usr/bin/env python3
"""Retain exact-build symbols and compare observed firmware cache inputs."""
from __future__ import annotations
import argparse
import errno
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_FILE = 2 * 1024**3


def sha(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_FILE:
        raise ValueError(f"missing, unsafe or oversized evidence: {path}")
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def read_json(path):
    if path.is_symlink() or path.stat().st_size > 8 * 1024**2:
        raise ValueError(f"unsafe JSON: {path}")
    return json.loads(path.read_text())


def source(root=ROOT):
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=root).decode().strip()
    return {'commit': git('rev-parse', 'HEAD'), 'tree': git('rev-parse', 'HEAD^{tree}'),
            'dirty': bool(git('status', '--porcelain'))}


def store_root():
    return Path(os.environ.get('BICINO_BUILD_EVIDENCE_DIR',
        str(Path.home() / 'Library/Application Support/OpenBikeComputer/build-evidence')))


def publish(kind, identity, files, root, expected_hashes=None):
    """Write an immutable, content-addressed index; never replace an earlier record."""
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.is_symlink():
        raise ValueError('evidence root must not be a symlink')
    with tempfile.TemporaryDirectory(prefix='.collect-', dir=root) as temporary:
        staging = Path(temporary)
        artifacts = []
        for relative, original in sorted(files.items()):
            target = staging / relative
            if Path(relative).is_absolute() or '..' in Path(relative).parts:
                raise ValueError('unsafe artifact path')
            if len(artifacts) >= 20000: raise ValueError('too many symbol files')
            digest = sha(original)
            if expected_hashes and relative in expected_hashes and digest != expected_hashes[relative]:
                raise ValueError('artifact changed after validation')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, target)
            if sha(target) != digest or sha(original) != digest:
                raise ValueError('artifact changed during collection')
            target.chmod(0o600)
            artifacts.append({'path': relative, 'sha256': digest, 'bytes': target.stat().st_size})
        index = {'schema': 1, 'kind': kind, 'identity': identity, 'artifacts': artifacts}
        identifier = hashlib.sha256(canonical(index)).hexdigest()
        (staging / 'index.json').write_bytes(canonical(index) + b'\n')
        destination = root / identifier
        try:
            staging.rename(destination)
            # TemporaryDirectory tolerates its original path being renamed.
        except OSError as error:
            if error.errno not in (errno.EEXIST, errno.ENOTEMPTY): raise
            verify(destination)
            if read_json(destination / 'index.json') != index:
                raise ValueError('content-addressed evidence conflict')
        return destination


def verify(record):
    if record.is_symlink() or not re.fullmatch('[0-9a-f]{64}', record.name):
        raise ValueError('expected a content-addressed evidence directory')
    index = read_json(record / 'index.json')
    if index.get('schema') != 1 or index.get('kind') not in ('firmware', 'ios', 'incident', 'replay'):
        raise ValueError('unsupported symbol index')
    if hashlib.sha256(canonical(index)).hexdigest() != record.name:
        raise ValueError('symbol index hash mismatch')
    seen = {'index.json'}
    for entry in index['artifacts']:
        relative = entry['path']
        if Path(relative).is_absolute() or '..' in Path(relative).parts or relative in seen:
            raise ValueError('unsafe/duplicate symbol path')
        seen.add(relative)
        path = record / relative
        for parent in path.parents:
            if parent == record.parent: break
            if parent.is_symlink(): raise ValueError('symbol path traverses a symlink')
        if sha(path) != entry['sha256'] or path.stat().st_size != entry['bytes']:
            raise ValueError('symbol artifact hash mismatch')
    if {str(p.relative_to(record)) for p in record.rglob('*') if p.is_file() or p.is_symlink()} != seen:
        raise ValueError('unindexed symbol evidence')
    return index


def cache_observation(manifest, previous=None):
    fields = ('coreInputKey', 'runtimeProvenance', 'platformioIniSha256',
              'sdkconfigDefaultsSha256', 'environmentSdkconfigSha256',
              'platformArchiveSha256', 'platformPackagesSha256',
              'managedComponentsSha256', 'libraryDependenciesSha256', 'producerInputs')
    inputs = {field: manifest.get(field) for field in fields}
    changed = [field for field in fields if previous and previous['inputs'].get(field) != inputs[field]]
    status = manifest.get('coreCache', 'unknown')
    explanation = 'verified core reused' if status == 'hit' else (
        'no comparison baseline; cache absence or rejection requires build logs' if previous is None else
        'observed input changes: ' + ', '.join(changed) if changed else
        'same observed inputs; cache absence, eviction or rejection requires build logs')
    return {'schema': 1, 'sourceIdentity': manifest.get('sourceIdentity'),
            'environment': manifest['environment'], 'coreCache': status,
            'inputs': inputs, 'changedInputs': changed, 'explanation': explanation,
            'phaseTimingsMs': manifest.get('phaseTimingsMs', {}),
            'previousPhaseTimingsMs': previous.get('phaseTimingsMs') if previous else None,
            'comparisonScope': 'recorded manifest inputs only; not cache authorization'}


def firmware(project, environment, root, previous=None):
    if not re.fullmatch(r'WAVESHARE_AMOLED_(175|206)(_[A-Z_]+)?', environment):
        raise ValueError('invalid firmware environment')
    manifest_path = project / '.pio/open-bike-build/builds' / environment / 'current.json'
    manifest_digest = sha(manifest_path)
    manifest = read_json(manifest_path)
    if manifest.get('environment') != environment or manifest.get('uploadEligible') is not True:
        raise ValueError('requires a successful attested build manifest')
    build = project / '.pio/build' / environment
    files = {'firmware.elf': build / 'firmware.elf', 'build-manifest.json': manifest_path}
    for name, field in [('firmware.elf', 'firmwareElfSha256'), ('firmware.bin', 'firmwareBinSha256')]:
        if sha(build / name) != manifest.get(field):
            raise ValueError(f'{name} does not match its build manifest')
    # The binary itself is identified by hash; retain ELF and map for symbolication.
    maps = sorted(build.glob('*.map'))
    if len(maps) != 1:
        raise ValueError('requires exactly one final linker map')
    files['firmware.map'] = maps[0]
    identity = {key: manifest.get(key) for key in ('sourceIdentity', 'environment',
                'firmwareElfSha256', 'firmwareBinSha256', 'coreInputKey', 'runtimeProvenance')}
    record = publish('firmware', identity, files, root, {'firmware.elf': manifest['firmwareElfSha256'],
                                                        'build-manifest.json': manifest_digest})
    # Derive producer inputs from the manifest's exact Git identity, never from
    # whichever source happens to occupy the worktree now. This is observational.
    manifest = dict(manifest)
    producer_inputs = {}
    commit = manifest.get('sourceIdentity', '')
    if re.fullmatch('[0-9a-f]{40}', commit):
        try:
            for name in ('prebuild.py', 'tools/build_firmware.py', 'tools/generated_sdkconfig.py',
                         'tools/pioarduino_custom_core.py', 'tools/firmware_runtime.py',
                         'tools/firmware_compile_cache.py', 'tools/shared_firmware_cache.py'):
                content = subprocess.check_output(['git','show',f'{commit}:esp32/{name}'],
                                                  cwd=project, stderr=subprocess.DEVNULL)
                producer_inputs[name] = hashlib.sha256(content).hexdigest()
        except subprocess.SubprocessError:
            producer_inputs = {}
    manifest['producerInputs'] = producer_inputs or None
    baseline = previous or (root / ('cache-' + environment + '.json'))
    observation = cache_observation(manifest, read_json(baseline) if baseline.exists() else None)
    # Observation is intentionally separate from immutable symbols and trusted build manifests.
    output = root / ('cache-' + environment + '.json')
    temporary = output.with_suffix('.tmp-' + str(os.getpid()))
    temporary.write_bytes(canonical(observation) + b'\n')
    temporary.replace(output)
    history = root / ('cache-observation-' + hashlib.sha256(canonical(observation)).hexdigest() + '.json')
    if history.exists():
        if read_json(history) != observation: raise ValueError('observation hash conflict')
    else: history.write_bytes(canonical(observation) + b'\n')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as stream:
            stream.write(f'### Firmware cache observation: {environment}\n\n')
            stream.write(f'Core cache: **{observation["coreCache"]}**. {observation["explanation"]}.\n\n')
            stream.write('| Phase | Previous ms | Current ms |\n|---|---:|---:|\n')
            previous_timings = observation.get('previousPhaseTimingsMs') or {}
            for phase, duration in sorted(observation['phaseTimingsMs'].items()):
                stream.write(f'| {phase} | {previous_timings.get(phase, "unavailable")} | {duration} |\n')
    print(json.dumps({'symbols': str(record), 'cacheReport': str(output), 'history': str(history), 'observation': observation}))
    return record


def dwarf_uuids(path):
    result = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True)
    values = sorted(re.findall(r'UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)', result))
    if not values:
        raise ValueError(f'no Mach-O UUIDs: {path}')
    return [(identifier.upper(), arch) for identifier, arch in values]


def ios(derived, configuration, before, root):
    after = source()
    if before != after or after['dirty']:
        raise ValueError('symbols require unchanged clean committed source throughout the build')
    products = derived / 'Build/Products'
    app = products / (configuration + '-iphoneos') / 'BikeComputer.app'
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    launcher = app / info['CFBundleExecutable']
    debug_image = app / (info['CFBundleExecutable'] + '.debug.dylib')
    binary = debug_image if debug_image.exists() else launcher
    binary_uuids = dwarf_uuids(binary)
    launcher_uuids = dwarf_uuids(launcher)
    required_uuids = set(binary_uuids) | set(launcher_uuids)
    dsyms = sorted(products.rglob('*.dSYM'))
    files, matched, dsym_identities = {}, [], {}
    for dsym in dsyms:
        if not dsym.parent.name.startswith(configuration + '-'):
            continue
        uuids = dwarf_uuids(dsym)
        dsym_identities[str(dsym.relative_to(products))] = uuids
        if required_uuids <= set(uuids):
            matched.append(str(dsym.relative_to(products)))
        for path in dsym.rglob('*'):
            if path.is_symlink():
                raise ValueError('dSYM symlinks are not supported')
            if path.is_file():
                files[str(path.relative_to(products))] = path
    if len(matched) != 1:
        raise ValueError('requires exactly one dSYM matching the app Mach-O UUIDs')
    files['app-Info.plist'] = app / 'Info.plist'
    identity = {'source': after, 'configuration': configuration,
        'bundleIdentifier': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'], 'binarySha256': sha(binary), 'binaryName': binary.name,
        'launcherSha256': sha(launcher), 'launcherMachOUUIDs': launcher_uuids,
        'machOUUIDs': binary_uuids, 'matchingDSYM': matched[0], 'dSYMs': dsym_identities}
    record = publish('ios', identity, files, root)
    print(json.dumps({'symbols': str(record), 'identity': identity}))
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('source')
    firm = commands.add_parser('firmware')
    firm.add_argument('--project', type=Path, default=ROOT / 'esp32')
    firm.add_argument('--environment', required=True)
    firm.add_argument('--previous', type=Path)
    apple = commands.add_parser('ios')
    apple.add_argument('--derived-data', type=Path, required=True)
    apple.add_argument('--configuration', choices=['Debug', 'Release'], required=True)
    apple.add_argument('--source-before', required=True)
    check = commands.add_parser('verify'); check.add_argument('record', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'source': print(json.dumps(source()))
        elif args.command == 'firmware': firmware(args.project, args.environment, store_root(), args.previous)
        elif args.command == 'ios': ios(args.derived_data, args.configuration, json.loads(args.source_before), store_root())
        else: print(json.dumps(verify(args.record)))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Build evidence failed: {error}\n')


if __name__ == '__main__': main()
