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
    if not isinstance(value, dict) or not required <= value.keys() or value.keys() - required - {'captureID', 'indexData', 'failureCode', 'origin', 'evidenceRetained', 'appEvidence'}:
        raise EvidenceError('invalid acquisition fields')
    if type(value['schema']) is not int or value['schema'] != 2 or value['phase'] not in ('requested', 'collecting', 'partial', 'complete', 'cancelled'):
        raise EvidenceError('invalid acquisition state')
    if value.get('origin') not in (None, 'manual', 'post_ride'):
        raise EvidenceError('invalid acquisition origin')
    if value.get('evidenceRetained') is not None and type(value['evidenceRetained']) is not bool:
        raise EvidenceError('invalid acquisition cache provenance')
    # This records app-side cache provenance only. Delivery below still checks
    # actual archived bytes against the original inventory, never this flag.
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
    app_chunks = value.get('appEvidence', [])
    if not isinstance(app_chunks, list) or len(app_chunks) > 256:
        raise EvidenceError('oversized app acquisition')
    app_paths = set()
    for item in app_chunks:
        if not isinstance(item, dict) or set(item) != {'path', 'bytes', 'sha256'}:
            raise EvidenceError('invalid app receipt')
        path = item['path']
        if not isinstance(path, str) or not re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/events-[0-9]{6,10}\.jsonl', path) or path in app_paths:
            raise EvidenceError('invalid app receipt path')
        if not value.get('captureID') or not integer(item['bytes'], 1, 256*1024) or not isinstance(item['sha256'], str) or not HEX.fullmatch(item['sha256']):
            raise EvidenceError('invalid app receipt identity')
        app_paths.add(path)
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

    def resolve_scope(self, *, capture: str | None = None,
                      acquisition: str | None = None, device: str | None = None) -> tuple[dict, list[dict]]:
        """Resolve explicit identities before counting sources or receipt claims.

        A different ride/device must never satisfy the requested investigation.
        An acquisition selects its original capture/device when those selectors
        are omitted. Unknown/mismatched selectors yield no matching inventory.
        """
        def canonical(value):
            if value is None:
                return None
            try:
                return str(uuid.UUID(str(value)))
            except (ValueError, TypeError, AttributeError) as exc:
                raise EvidenceError('invalid capture or acquisition UUID') from exc
        capture, acquisition = canonical(capture), canonical(acquisition)
        if device is not None and device != 'iphone' and not re.fullmatch('[0-9a-f]{16}', device):
            raise EvidenceError('explicit pseudonymous device identity required')
        matches = [item for item in self.acquisitions
                   if (acquisition is None or canonical(item['id']) == acquisition)
                   and (capture is None or canonical(item.get('captureID')) == capture)
                   and (device is None or item['deviceDigest'] == device)]
        if acquisition is not None and matches:
            capture = capture or canonical(matches[0].get('captureID'))
            device = device or matches[0]['deviceDigest']
        return {'capture': capture, 'acquisition': acquisition, 'device': device,
                'matchedAcquisitions': len(matches)}, matches

    def scoped_events(self, scope: dict, acquisitions: list[dict]) -> list[dict]:
        if scope['acquisition'] is not None and not acquisitions:
            return []
        inventory_paths = {
            f"device/{item['deviceDigest']}/{chunk['bootSequence']}/events-{chunk['chunk']:06d}-{chunk['sha256'][:16]}.jsonl"
            for item in acquisitions for chunk in item['expected']
        }
        selected = []
        for event in self.events():
            if scope['capture'] is not None and str(event.get('captureId', '')).lower() != scope['capture']:
                continue
            path = event['rawReference']['member']
            if event['source'] == 'firmware':
                if scope['device'] is not None and not path.startswith(f"device/{scope['device']}/"):
                    continue
                if scope['acquisition'] is not None and path not in inventory_paths:
                    continue
            elif scope['acquisition'] is not None and scope['capture'] is None:
                # Older unbound receipts cannot establish an associated iPhone
                # capture merely because this bundle also contains phone logs.
                continue
            selected.append(event)
        return selected

    def coverage(self, required: tuple[str,...] = ('ios','firmware'), *,
                 capture: str | None = None, acquisition: str | None = None,
                 device: str | None = None) -> dict:
        scope, acquisitions = self.resolve_scope(capture=capture, acquisition=acquisition, device=device)
        events = self.scoped_events(scope, acquisitions)
        sources = {e['source'] for e in events}
        missing_sources = sorted(set(required) - sources)
        selected_paths = {event['rawReference']['member'] for event in events}
        scoped = any(scope[key] is not None for key in ('capture', 'acquisition', 'device'))
        streams = [stream for stream in self.streams if not scoped or stream.path in selected_paths]
        gaps = sum(stream.dropped_sequences for stream in streams)
        tails = sum(bool(stream.truncated_tail) for stream in streams)
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
                counters.append({'stream': 'manifest.json', 'source': 'host', 'field': key, 'count': count, 'scope': 'bundle_global'})
        # Check actual evidence, not only the phone's possibly stale receipts.
        deliveries = []
        with zipfile.ZipFile(self.source) as archive:
            members = {m.filename: m for m in archive.infolist()}
            for acquisition in acquisitions:
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
        return {'schema':2, 'bundleSha256':self.sha256, 'scope':scope, 'eventCount':len(events),
                'sources':sorted(sources), 'missingRequiredSources':missing_sources,
                'delivery':deliveries, 'deliveryEvidence': 'inventoried' if deliveries else 'no_acquisition_manifest',
                'recordingCoverage':'degraded' if degraded else 'no_detected_loss',
                'coverageCaveat':'No detected loss is not proof that every requested provider was enabled.',
                'sequenceGaps':gaps, 'recoverableTails':tails, 'lossCounters':counters[:100],
                'lossAccountingScope':'selected_streams_and_bundle_global_counters' if scoped else 'bundle',
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
        stream_by_path = {stream.path: stream for stream in streams}
        with zipfile.ZipFile(source) as archive:
            for acquisition in acquisitions:
                for receipt in acquisition.get('appEvidence', []):
                    name = 'app/' + receipt['path']
                    stream = stream_by_path.get(name)
                    if stream is None:
                        raise EvidenceError('retained app evidence is missing')
                    data = archive.read(name)
                    process = receipt['path'].split('/')[0]
                    capture = str(uuid.UUID(acquisition['captureID']))
                    if len(data) != receipt['bytes'] or digest(data) != receipt['sha256'] or not any(str(event.get('captureId', '')).lower() == capture for event in stream.events) or any(str(event.get('processId', '')).lower() != process for event in stream.events):
                        raise EvidenceError('retained app evidence identity mismatch')
        yield Evidence(path, source, manifest, streams, acquisitions, sha)
