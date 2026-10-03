"""Small exact-byte fixtures shared by diagnostics transport and CLI tests."""
import base64
import hashlib
import json
from pathlib import Path
import uuid
import zipfile
from test_ride_diagnostics import (event, firmware_event, bundle_manifest,
    required_sidecars, APP_STREAM_PATH, APP_CAPTURE_ID, DEVICE_DIGEST)


def write_zip(path, members):
    members = dict(members)
    checksums = ''.join(f'{hashlib.sha256(payload).hexdigest()}  {name}\n' for name,payload in members.items())
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
        for name, payload in members.items(): archive.writestr(name, payload)
        archive.writestr('checksums.sha256', checksums)


def v1_fixture(path, include_device=True, count=3):
    app = b''.join((json.dumps(event(index))+'\n').encode() for index in range(count))
    source = {APP_STREAM_PATH:app}
    device = firmware_event(fields={'bootSequence':7,'firmwareFingerprint':'A1B2C3D4','recorderReady':True})
    raw = (json.dumps(device)+'\n').encode()
    sha = hashlib.sha256(raw).hexdigest()
    chunk = {'bootSequence':7,'chunk':1,'bytes':len(raw),'sha256':sha}
    if include_device:
        source[f'device/{DEVICE_DIGEST}/7/events-000001-{sha[:16]}.jsonl'] = raw
    manifest = bundle_manifest(source)
    members = {'manifest.json':json.dumps(manifest).encode(), **source, **required_sidecars(manifest)}
    write_zip(path,members)
    return chunk


def v2_fixture(path, inner, chunk, claims_complete=True, index=True):
    acquisition = {'schema':2,'id':str(uuid.uuid4()),'deviceDigest':DEVICE_DIGEST,
        'captureID':APP_CAPTURE_ID,'createdAt':810000000.0,'updatedAt':810000010.0,
        'phase':'complete' if claims_complete else 'partial','expected':[chunk] if index else [],
        'verified':[f"7:1:{chunk['sha256']}"] if claims_complete else []}
    if index:
        source_index={'schema':1,'source':'firmware','bootSequence':7,'activeChunk':2,
            'stats':{'enqueued':1,'written':1,'dropped':0,'storageErrors':0},'chunks':[chunk]}
        acquisition['indexData']=base64.b64encode(json.dumps(source_index).encode()).decode()
    name=f"acquisitions/{acquisition['id']}.json"
    data=inner.read_bytes()
    envelope={'schema':2,'eventFormatSchema':1,'registryDigest':'a'*64,
        'evidenceArchive':'evidence-v1.zip','evidenceSha256':hashlib.sha256(data).hexdigest(),
        'acquisitions':[name],'privacy':'diagnostic-no-raw-payloads'}
    write_zip(path,{'manifest.json':json.dumps(envelope).encode(),'evidence-v1.zip':data,
                    name:json.dumps(acquisition).encode()})
    return acquisition
