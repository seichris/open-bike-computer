"""Read v1 evidence and v2 acquisition envelopes, never trusting receipt claims."""
from __future__ import annotations
import base64
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import tempfile
from typing import Iterator, Any
import uuid
import zipfile
import ride_diagnostics as v1

MAX_BYTES = 104 * 1024 * 1024
MAX_RECEIPT_BYTES = 256 * 1024
HEX = re.compile(r"^[0-9a-f]{64}$")
ACQUISITION = re.compile(r"^acquisitions/[0-9a-f-]{36}\.json$")

class EvidenceError(ValueError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def integer(value: Any, minimum: int = 0, maximum: int = 2**32-1) -> bool:
    return type(value) is int and minimum <= value <= maximum


def validate_acquisition(value: dict) -> dict:
    required = {'schema', 'id', 'deviceDigest', 'createdAt', 'updatedAt', 'phase', 'expected', 'verified'}
    if not isinstance(value, dict) or not required <= value.keys() or value.keys() - required - {'captureID', 'indexData', 'failureCode'}:
        raise EvidenceError('invalid acquisition fields')
    if type(value['schema']) is not int or value['schema'] != 2 or value['phase'] not in ('requested', 'collecting', 'partial', 'complete', 'cancelled'):
        raise EvidenceError('invalid acquisition state')
    try:
        uuid.UUID(value['id'])
        if value.get('captureID') is not None:
            uuid.UUID(value['captureID'])
    except (ValueError, TypeError, AttributeError) as exc:
        raise EvidenceError('invalid acquisition identity') from exc
    if not isinstance(value['deviceDigest'], str) or not re.fullmatch('[0-9a-f]{16}', value['deviceDigest']):
        raise EvidenceError('invalid pseudonymous device identity')
    for field in ('createdAt','updatedAt'):
        if type(value[field]) not in (int, float) or not -1e11 < value[field] < 1e11:
            raise EvidenceError('invalid acquisition clock')
    if value.get('failureCode') is not None and (not isinstance(value['failureCode'], str) or not re.fullmatch('[a-z0-9_]{1,64}', value['failureCode'])):
        raise EvidenceError('invalid failure code')
    if not isinstance(value['expected'], list) or len(value['expected']) > 256 or not isinstance(value['verified'], list):
        raise EvidenceError('oversized acquisition')
    keys, identities = set(), set()
    for chunk in value['expected']:
        if not isinstance(chunk, dict) or set(chunk) != {'bootSequence', 'chunk', 'bytes', 'sha256'}:
            raise EvidenceError('invalid chunk receipt')
        if not all(integer(chunk[k], 1) for k in ('bootSequence', 'chunk')) or not integer(chunk['bytes'], 1, 256*1024):
            raise EvidenceError('invalid chunk bounds')
        if not isinstance(chunk['sha256'], str) or not HEX.fullmatch(chunk['sha256']):
            raise EvidenceError('invalid chunk hash')
        identity = (chunk['bootSequence'], chunk['chunk'])
        if identity in identities:
            raise EvidenceError('duplicate chunk')
        identities.add(identity)
        keys.add(f"{identity[0]}:{identity[1]}:{chunk['sha256']}")
    if not all(isinstance(k,str) for k in value['verified']) or len(set(value['verified'])) != len(value['verified']) or not set(value['verified']) <= keys:
        raise EvidenceError('invalid verification claims')
    index = None
    if value.get('indexData') is not None:
        try:
            raw = base64.b64decode(value['indexData'], validate=True)
            if len(raw) > 64*1024:
                raise EvidenceError('oversized device index')
            index = json.loads(raw)
            if not isinstance(index, dict):
                raise EvidenceError('invalid acquisition index shape')
            # Reuse the closed-vocabulary v1 index validator, including privacy.
            v1._check_privacy(index, path='acquisition/index.json')
            v1._validate_json_sidecar(f"device/{value['deviceDigest']}/{index.get('bootSequence')}/recorder-health.json", index)
        except (ValueError, TypeError, AttributeError, v1.DiagnosticError) as exc:
            raise EvidenceError('invalid acquisition index') from exc
        expected = sorted(value['expected'], key=lambda c:(c['bootSequence'],c['chunk']))
        indexed = sorted(index['chunks'], key=lambda c:(c['bootSequence'],c['chunk']))
        if any(c['bootSequence'] > index['bootSequence'] or (c['bootSequence'] == index['bootSequence'] and c['chunk'] >= index['activeChunk']) for c in indexed):
            raise EvidenceError('inventory includes active or future chunk')
        if expected != indexed:
            raise EvidenceError('acquisition differs from its original device inventory')
    elif value['expected'] or value['phase'] == 'complete':
        raise EvidenceError('acquisition has no inventory')
    if value['phase'] == 'complete' and set(value['verified']) != keys:
        raise EvidenceError('complete receipt lacks verified chunks')
    return value


@dataclass
class Evidence:
    path: Path
    source: Path
    manifest: dict
    streams: tuple
    acquisitions: list[dict]
    sha256: str

    def events(self) -> list[dict]:
        correlated = v1._correlate_events(self.streams)
        references = ((stream.path, line) for stream in self.streams for line in range(1, len(stream.events)+1))
        for event, (path, line) in zip(correlated, references, strict=True):
            event['rawReference'] = {'member': path, 'line': line, 'bundleSha256': self.sha256}
        return correlated

    def coverage(self, required: tuple[str,...] = ('ios','firmware')) -> dict:
        events = self.events()
        sources = {e['source'] for e in events}
        missing_sources = sorted(set(required) - sources)
        gaps = sum(s.dropped_sequences for s in self.streams)
        tails = sum(bool(s.truncated_tail) for s in self.streams)
        counters = []
        for event in events:
            for key in ('droppedCount','storageErrorCount'):
                val = event.get('fields',{}).get(key)
                try:
                    count = int(val or 0)
                except (ValueError,TypeError):
                    count = 0
                if count:
                    counters.append({'stream':event['rawReference']['member'], 'source':event['source'], 'field':key, 'count':count})
        for key in ('droppedEventCount', 'deviceDroppedEventCount'):
            count = self.manifest.get(key, 0)
            if type(count) is int and count > 0:
                counters.append({'stream': 'manifest.json', 'source': 'host', 'field': key, 'count': count})
        # Check actual evidence, not only the phone's possibly stale receipts.
        deliveries = []
        with zipfile.ZipFile(self.source) as archive:
            members = {m.filename: m for m in archive.infolist()}
            for acquisition in self.acquisitions:
                missing = []
                for item in acquisition['expected']:
                    name = (f"device/{acquisition['deviceDigest']}/{item['bootSequence']}/"
                            f"events-{item['chunk']:06d}-{item['sha256'][:16]}.jsonl")
                    entry = members.get(name)
                    if entry is None or entry.file_size != item['bytes'] or digest(archive.read(name)) != item['sha256']:
                        missing.append({'bootSequence':item['bootSequence'],'chunk':item['chunk']})
                deliveries.append({'id':acquisition['id'], 'deviceDigest':acquisition['deviceDigest'], 'captureID':acquisition.get('captureID'),
                    'state':'complete' if acquisition.get('indexData') is not None and not missing else 'incomplete',
                    'expectedChunks':len(acquisition['expected']), 'missingChunks':missing,
                    'reportedPhase':acquisition['phase']})
        degraded = bool(missing_sources or gaps or tails or counters)
        return {'schema':2, 'bundleSha256':self.sha256, 'eventCount':len(events),
                'sources':sorted(sources), 'missingRequiredSources':missing_sources,
                'delivery':deliveries, 'deliveryEvidence': 'inventoried' if deliveries else 'no_acquisition_manifest',
                'recordingCoverage':'degraded' if degraded else 'no_detected_loss',
                'coverageCaveat':'No detected loss is not proof that every requested provider was enabled.',
                'sequenceGaps':gaps, 'recoverableTails':tails, 'lossCounters':counters[:100],
                'nativeCrashEvidence':'not_in_standard_bundle',
                'buildIdentity':{'app':self.manifest.get('appBuildIdentity'), 'firmware':self.manifest.get('firmwareBuildIdentities')}}


@contextmanager
def open_evidence(path: Path) -> Iterator[Evidence]:
    path = path.expanduser()
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_BYTES:
        raise EvidenceError('bundle is missing, symlinked or oversized')
    sha = digest(path.read_bytes())
    with tempfile.TemporaryDirectory(prefix='bicino-evidence-') as directory:
        source = path
        acquisitions: list[dict] = []
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            names = [m.filename for m in members]
            if len(set(names)) != len(names) or sum(m.file_size for m in members) > MAX_BYTES:
                raise EvidenceError('duplicate or oversized archive')
            if any(m.file_size > MAX_BYTES or m.flag_bits & 1 for m in members):
                raise EvidenceError('unsupported archive member')
            if 'evidence-v1.zip' in names:
                allowed = {'manifest.json','evidence-v1.zip','checksums.sha256'}
                if any(n not in allowed and not ACQUISITION.fullmatch(n) for n in names) or len(names)>23:
                    raise EvidenceError('unsafe or unsupported v2 member')
                for name in names:
                    if name != 'evidence-v1.zip' and archive.getinfo(name).file_size > MAX_RECEIPT_BYTES:
                        raise EvidenceError('oversized v2 metadata')
                envelope = json.loads(archive.read('manifest.json'))
                if not isinstance(envelope,dict) or set(envelope) != {'schema','eventFormatSchema','registryDigest','evidenceArchive','evidenceSha256','acquisitions','privacy'} or envelope['schema']!=2 or envelope['eventFormatSchema']!=1 or envelope['evidenceArchive']!='evidence-v1.zip' or envelope['privacy']!='diagnostic-no-raw-payloads':
                    raise EvidenceError('unsupported v2 manifest')
                if not isinstance(envelope['registryDigest'],str) or not isinstance(envelope['evidenceSha256'],str) or not HEX.fullmatch(envelope['registryDigest']) or not HEX.fullmatch(envelope['evidenceSha256']):
                    raise EvidenceError('invalid envelope digest')
                declared = envelope['acquisitions']
                if not isinstance(declared,list) or not all(isinstance(n,str) for n in declared) or len(set(declared))!=len(declared) or set(names) != allowed | set(declared):
                    raise EvidenceError('incomplete acquisition inventory')
                checksums = {}
                for line in archive.read('checksums.sha256').decode().splitlines():
                    checksum, separator, name = line.partition('  ')
                    if not separator or not HEX.fullmatch(checksum) or name in checksums:
                        raise EvidenceError('invalid checksum manifest')
                    checksums[name]=checksum
                if set(checksums) != set(names)-{'checksums.sha256'}:
                    raise EvidenceError('unbound archive members')
                for name, expected in checksums.items():
                    if digest(archive.read(name)) != expected:
                        raise EvidenceError('checksum mismatch')
                source = Path(directory)/'evidence-v1.zip'
                source.write_bytes(archive.read('evidence-v1.zip'))
                if digest(source.read_bytes()) != envelope['evidenceSha256']:
                    raise EvidenceError('evidence identity mismatch')
                for name in declared:
                    receipt = validate_acquisition(json.loads(archive.read(name)))
                    if name != 'acquisitions/'+receipt['id'].lower()+'.json':
                        raise EvidenceError('acquisition filename identity mismatch')
                    acquisitions.append(receipt)
        manifest, streams = v1.validate_bundle(source)
        yield Evidence(path, source, manifest, streams, acquisitions, sha)
