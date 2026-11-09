"""Regression scenarios for retained health and broker lifecycle boundaries."""
import base64
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import time
import uuid
import zipfile

from test_diagnostics_broker import BrokerTLSTestCase
from diagnostics_test_support import v1_fixture, v2_fixture, write_zip
from bicino_diagnostics import broker, cli
from bicino_diagnostics.bundle import open_evidence


class BrokerReliabilityTests(BrokerTLSTestCase):
    def fixture(self):
        path = self.parent/'evidence.zip'
        v1_fixture(path)
        data = path.read_bytes()
        return path, data, hashlib.sha256(data).hexdigest()

    def test_public_archive_frees_capacity_and_preserves_verified_replay(self):
        path, data, sha = self.fixture()
        ids = [str(uuid.uuid4()) for _ in range(20)]
        for identifier in ids:
            temporary = self.parent/'incoming.zip'
            temporary.write_bytes(data)
            self.store.accept_upload(identifier, temporary, sha)
        new_id = str(uuid.uuid4())
        headers = {broker.TOKEN_HEADER:self.config['token'], 'X-Content-SHA256':sha}
        self.assertEqual(self.exchange('PUT', '/v2/uploads/'+new_id, data, headers)[0], 507)
        archive = self.parent/'archive/ride.zip'
        with redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(['diag', '--broker-root', str(self.root), 'inbox', 'archive',
                '--id', ids[0], '--output', str(archive)]), 0)
        self.assertEqual(archive.read_bytes(), data)
        self.assertFalse((self.root/'bundles'/f'{ids[0]}.zip').exists())
        self.assertEqual(len(self.store.status()['bundles']), 19)
        self.assertEqual(self.exchange('PUT', '/v2/uploads/'+new_id, data, headers)[0], 200)
        self.assertEqual(self.exchange('PUT', '/v2/uploads/'+ids[0], data, headers)[0], 200)
        archive.write_bytes(b'damaged')
        self.assertEqual(self.exchange('PUT', '/v2/uploads/'+ids[0], data, headers)[0], 400)

    def test_legacy_cached_coverage_does_not_claim_health_was_checked(self):
        _, data, sha = self.fixture()
        incoming = self.parent/'incoming.zip'
        incoming.write_bytes(data)
        identifier = str(uuid.uuid4())
        self.store.accept_upload(identifier, incoming, sha)
        self.assertEqual(self.store.status()['bundles'][0]['coverage']['recordingCoverage'], 'unknown_unsealed_boot')
        with self.store.connect() as connection:
            saved = json.loads(connection.execute('SELECT coverage FROM bundles WHERE id=?', (identifier,)).fetchone()[0])
            saved['lossAccountingVersion'] = 2
            saved['recordingCoverage'] = 'no_detected_loss'
            connection.execute('UPDATE bundles SET coverage=? WHERE id=?', (json.dumps(saved), identifier))
        self.assertEqual(self.store.status()['bundles'][0]['coverage']['recordingCoverage'], 'unknown_legacy')

    def test_server_ownership_prevents_cleanup_of_active_uploads(self):
        partial = self.root/'pending/.upload-active'
        partial.write_bytes(b'active')
        broker.BrokerStore(self.root)
        self.assertEqual(partial.read_bytes(), b'active')
        with self.assertRaises(BlockingIOError):
            broker.BrokerHTTPServer(('127.0.0.1',0), broker.BrokerStore(self.root))
        self.assertEqual(partial.read_bytes(), b'active')
        with self.assertRaises(broker.InboxCapacityError):
            self.store.admit_staging(broker.MAX_STAGING_BYTES)

    def test_process_loss_reclaims_only_partial_staging_on_restart(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        # A real child server receives an unfinished body and is killed after
        # bytes reach its staging file. Never operate any configured live broker.
        child = subprocess.Popen([sys.executable, '-c',
            'from pathlib import Path; from bicino_diagnostics.broker import serve; import sys; serve(Path(sys.argv[1]))',
            str(self.root)], env=dict(__import__('os').environ, PYTHONPATH=str(Path(broker.__file__).parents[1])),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sock = None
        try:
            for _ in range(100):
                try:
                    raw = socket.create_connection(('127.0.0.1',self.port), timeout=.1)
                    context = ssl._create_unverified_context()
                    sock = context.wrap_socket(raw, server_hostname='127.0.0.1')
                    break
                except OSError:
                    time.sleep(.02)
            self.assertIsNotNone(sock)
            # Python 3.14 increased the default file buffer to 128 KiB. Send
            # beyond that buffer so disk bytes exist before killing the child,
            # while leaving half the declared request body unfinished.
            partial_body = b'x' * (2 * max(io.DEFAULT_BUFFER_SIZE, 64 * 1024))
            sock.sendall((f'PUT /v2/uploads/{uuid.uuid4()} HTTP/1.1\r\nHost: localhost\r\n'
                f'{broker.TOKEN_HEADER}: {self.config["token"]}\r\n'
                f'Content-Length: {2 * len(partial_body)}\r\n\r\n').encode() + partial_body)
            for _ in range(100):
                staged = list((self.root/'pending').glob('.upload-*'))
                if staged and staged[0].stat().st_size >= 65536: break
                time.sleep(.02)
            self.assertTrue(staged and staged[0].stat().st_size >= 65536)
        finally:
            child.kill(); child.wait(timeout=3)
            if sock: sock.close()
        # A rename before receipt commit is recoverable evidence, not a partial.
        renamed = self.root/'bundles'/f'{uuid.uuid4()}.zip'
        renamed.write_bytes(b'recoverable-renamed-file')
        self.server = broker.BrokerHTTPServer(('127.0.0.1',self.port), self.store)
        import threading
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval':.02}, daemon=True)
        self.thread.start()
        self.assertEqual(list((self.root/'pending').iterdir()), [])
        self.assertEqual(renamed.read_bytes(), b'recoverable-renamed-file')

    def test_unindexed_renames_are_preserved_and_consume_admission(self):
        _, data, sha = self.fixture()
        identifiers = [str(uuid.uuid4()) for _ in range(20)]
        for identifier in identifiers:
            (self.root/'bundles'/f'{identifier}.zip').write_bytes(data)
        incoming = self.parent/'incoming.zip'
        incoming.write_bytes(data)
        with self.assertRaises(broker.InboxCapacityError):
            self.store.accept_upload(str(uuid.uuid4()), incoming, sha)
        # Recovering the same interrupted identity does not double-charge it.
        self.store.accept_upload(identifiers[0], incoming, sha)
        self.assertEqual(len(list((self.root/'bundles').glob('*.zip'))), 20)

    def test_dripping_headers_and_body_have_absolute_deadlines(self):
        self.server.header_timeout = .25
        self.server.body_timeout = .25
        context = ssl._create_unverified_context()
        for prefix in (b'GET /v2/status HTTP/1.1\r\nX-Slow: ',
            (f'PUT /v2/uploads/{uuid.uuid4()} HTTP/1.1\r\nHost: localhost\r\n'
             f'{broker.TOKEN_HEADER}: {self.config["token"]}\r\nContent-Length: 10000\r\n\r\n').encode()):
            with context.wrap_socket(socket.create_connection(('127.0.0.1',self.port)), server_hostname='127.0.0.1') as sock:
                sock.sendall(prefix)
                started = time.monotonic()
                for _ in range(9):
                    time.sleep(.05)
                    try: sock.sendall(b'x')
                    except OSError: break
                self.assertEqual(self.exchange('GET','/v2/status')[0], 200)
                self.assertLess(time.monotonic() - started, 1.5)
        self.assertEqual(list((self.root/'pending').iterdir()), [])


class CoverageReliabilityTests(__import__('unittest').TestCase):
    def test_retained_storage_errors_degrade_coverage_without_double_counting(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inner, outer = root/'inner.zip', root/'outer.zip'
            chunk = v1_fixture(inner)
            with zipfile.ZipFile(inner) as archive:
                members = {n:archive.read(n) for n in archive.namelist() if n != 'checksums.sha256'}
            # Fixture has no device sidecar: add the authoritative health even
            # when no corresponding storage_gap event survives retention.
            health = {'schema':1,'source':'firmware','bootSequence':7,'activeChunk':2,
                'stats':{'enqueued':4,'written':1,'dropped':0,'storageErrors':3},'chunks':[chunk]}
            name = 'device/0123456789abcdef/7/recorder-health.json'
            # Use the fixture's real pseudonymous digest.
            device = next(n.split('/')[1] for n in members if n.startswith('device/'))
            name = f'device/{device}/7/recorder-health.json'
            members[name] = json.dumps(health).encode()
            write_zip(inner, members)
            acquisition = v2_fixture(outer, inner, chunk)
            acquisition['indexData'] = base64.b64encode(json.dumps(health).encode()).decode()
            with zipfile.ZipFile(outer) as archive:
                envelope = {n:archive.read(n) for n in archive.namelist() if n != 'checksums.sha256'}
            envelope['acquisitions/'+acquisition['id']+'.json'] = json.dumps(acquisition).encode()
            write_zip(outer, envelope)
            for path in (inner, outer):
                with open_evidence(path) as evidence:
                    coverage = evidence.coverage()
                    counters = [v for v in coverage['lossCounters'] if v['field'] == 'storageErrors']
                    self.assertEqual(len(counters), 1)
                    self.assertEqual(counters[0]['count'], 3)
                    self.assertEqual(coverage['recordingCoverage'], 'degraded')
                    if path == outer: self.assertEqual(coverage['delivery'][0]['state'], 'complete')

    def test_index_only_loss_is_not_hidden_by_zero_current_manifest(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inner, outer = root/'inner.zip', root/'outer.zip'
            chunk = v1_fixture(inner)
            acquisition = v2_fixture(outer, inner, chunk)
            health = json.loads(base64.b64decode(acquisition['indexData']))
            health['stats'].update(storageErrors=3, dropped=5)
            acquisition['indexData'] = base64.b64encode(json.dumps(health).encode()).decode()
            with zipfile.ZipFile(outer) as archive:
                members = {n:archive.read(n) for n in archive.namelist() if n != 'checksums.sha256'}
            members['acquisitions/'+acquisition['id']+'.json'] = json.dumps(acquisition).encode()
            write_zip(outer, members)
            with open_evidence(outer) as evidence:
                self.assertEqual(evidence.manifest['deviceDroppedEventCount'], 0)
                coverage = evidence.coverage()
                self.assertEqual(coverage['recordingCoverage'], 'degraded')
                self.assertEqual({v['field']:v['count'] for v in coverage['lossCounters']}, {'storageErrors':3, 'dropped':5})
                self.assertEqual(coverage['delivery'][0]['state'], 'complete')

    def test_historical_process_drop_counter_survives_event_retention(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'evidence.zip'
            v1_fixture(path)
            with zipfile.ZipFile(path) as archive:
                members = {n:archive.read(n) for n in archive.namelist() if n != 'checksums.sha256'}
            name = next(n for n in members if n.startswith('app/') and n.endswith('/manifest.json'))
            value = json.loads(members[name])
            old = str(uuid.uuid4())
            value.update(processId=old, droppedEventCount=4)
            members[f'app/{old}/manifest.json'] = json.dumps(value).encode()
            write_zip(path, members)
            with open_evidence(path) as evidence:
                coverage = evidence.coverage(required=('ios',))
                self.assertEqual(coverage['recordingCoverage'], 'degraded')
                self.assertTrue(any(c.get('processId') == old and c['count'] == 4 for c in coverage['lossCounters']))
