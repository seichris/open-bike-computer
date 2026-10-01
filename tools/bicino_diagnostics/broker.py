"""Explicitly paired, pinned-TLS LAN inbox and bounded command queue.

There is no shell/flash/reset endpoint. User-owned credentials never appear in
command results, logs, URLs, or evidence. Recorders do not depend on this server.
"""
from __future__ import annotations
from contextlib import closing
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import ssl
import subprocess
import tempfile
import time
from urllib.parse import urlsplit
import uuid
import zipfile
import ride_diagnostics as v1

from .bundle import EvidenceError, MAX_BYTES, open_evidence, integer
from .live import LiveInbox

TOKEN_HEADER = 'X-Bicino-Diagnostics-Token'
MAX_JSON = 64 * 1024
DEFAULT_ROOT = Path.home()/'.local/share/bicino/diagnostics'
KINDS = {'capture', 'mark', 'collect', 'export', 'stop_capture', 'live', 'stop_live'}


def private_root(root: Path) -> Path:
    root = root.expanduser().absolute()
    # Refuse symlinks in existing ancestors, not only the final directory.
    if any(p.is_symlink() for p in (root,*root.parents)):
        raise EvidenceError('broker path contains a symlink')
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    stat = root.stat()
    if stat.st_uid != os.getuid() or stat.st_mode & 0o077:
        raise EvidenceError('broker directory must be user-owned with mode 0700')
    return root


def write_private(path: Path, data: bytes) -> None:
    fd, temporary = tempfile.mkstemp(prefix='.write-', dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_private(path: Path, maximum: int = MAX_JSON) -> bytes:
    if path.is_symlink():
        raise EvidenceError('credential symlink refused')
    s = path.stat()
    if s.st_uid != os.getuid() or s.st_mode & 0o077 or s.st_size > maximum:
        raise EvidenceError('unsafe credential ownership, mode or size')
    return path.read_bytes()


def origin_parts(origin: str):
    value = urlsplit(origin)
    if value.scheme != 'https' or value.username or value.password or value.query or value.fragment or value.path not in ('','/'):
        raise EvidenceError('a bare HTTPS LAN origin is required')
    try:
        address = ipaddress.ip_address(value.hostname or '')
        port = value.port
    except ValueError as exc:
        raise EvidenceError('use an explicit private IPv4 address') from exc
    if address.version != 4 or not any(address in ipaddress.ip_network(n) for n in ('10.0.0.0/8','127.0.0.0/8','172.16.0.0/12','192.168.0.0/16')) or not port:
        raise EvidenceError('use a private IPv4 address and explicit port')
    return value.hostname, port


def initialize(root: Path, origin: str, pairing_output: Path, hours: int = 24) -> dict:
    origin_parts(origin)
    if not 1 <= hours <= 24:
        raise EvidenceError('pairing lifetime must be 1–24 hours')
    root = private_root(root)
    if (root/'credentials.json').exists() or (root/'server.key').exists():
        raise EvidenceError('broker already initialized; revoke or use a new private directory')
    # Do not permit output to overwrite repository files or existing credentials.
    pairing_output = pairing_output.expanduser().absolute()
    if pairing_output.exists() or pairing_output.is_symlink() or pairing_output.parent.is_symlink():
        raise EvidenceError('pairing output must be a new file in a non-symlink directory')
    key, certificate = root/'server.key', root/'server.crt'
    with tempfile.TemporaryDirectory(prefix='.certificate-',dir=root) as temporary:
        k,c = Path(temporary)/'key.pem',Path(temporary)/'cert.pem'
        subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:prime256v1',
                        '-nodes','-days','2','-subj','/CN=Bicino Diagnostics',
                        '-keyout',str(k),'-out',str(c)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
        write_private(key,k.read_bytes())
        write_private(certificate,c.read_bytes())
    der = ssl.PEM_cert_to_DER_cert(certificate.read_text())
    config = {'schema':2,'origin':origin.rstrip('/'),'certificateSHA256':hashlib.sha256(der).hexdigest(),
              'token':secrets.token_hex(32),'expiresAt':int(time.time())+hours*3600}
    write_private(root/'credentials.json',json.dumps(config,sort_keys=True).encode())
    write_private(pairing_output,json.dumps(config,sort_keys=True).encode())
    return {'schema':2,'origin':config['origin'],'pairingFile':str(pairing_output),
            'certificateSHA256':config['certificateSHA256'],'expiresAt':config['expiresAt']}


class BrokerStore:
    def __init__(self, root: Path):
        self.root = private_root(root)
        self.live = LiveInbox()
        for directory in ('bundles','pending'):
            private_root(self.root/directory)
        database = self.root/'broker.sqlite3'
        if database.exists() and database.is_symlink():
            raise EvidenceError('database symlink refused')
        with closing(self.connect()) as connection, connection:
            connection.executescript('''
                CREATE TABLE IF NOT EXISTS commands(id TEXT PRIMARY KEY, created INTEGER NOT NULL,
                    expires INTEGER NOT NULL, kind TEXT NOT NULL, body TEXT NOT NULL, result TEXT);
                CREATE TABLE IF NOT EXISTS status(id INTEGER PRIMARY KEY CHECK(id=1), updated INTEGER, body TEXT);
                CREATE TABLE IF NOT EXISTS bundles(id TEXT PRIMARY KEY, created INTEGER, sha256 TEXT, bytes INTEGER, coverage TEXT);
            ''')
        os.chmod(database,0o600)

    def connect(self):
        connection = sqlite3.connect(self.root/'broker.sqlite3', timeout=5)
        connection.execute('PRAGMA synchronous=FULL')
        return connection

    def config(self) -> dict:
        config = json.loads(read_private(self.root/'credentials.json'))
        if config['schema']!=2 or not re.fullmatch('[0-9a-f]{64}', config['token']):
            raise EvidenceError('invalid broker credentials')
        origin_parts(config['origin'])
        return config

    def enqueue(self, kind: str, target: str, parameters: dict) -> dict:
        if kind not in KINDS or not re.fullmatch('iphone|[0-9a-f]{16}',target):
            raise EvidenceError('unsupported command or target')
        if kind=='capture':
            if set(parameters)!={'mask','minimumLevel','durationSeconds','budgetBytes','registryDigest'} or not all(integer(parameters[k],1) for k in ('mask','durationSeconds','budgetBytes')) or not integer(parameters['minimumLevel'],0,5) or parameters['durationSeconds']>14400 or not 1024<=parameters['budgetBytes']<=32*1024*1024 or not re.fullmatch('[0-9a-f]{64}',parameters['registryDigest']):
                raise EvidenceError('invalid bounded capture request')
        elif kind=='live':
            if set(parameters) != {'durationSeconds'} or not integer(parameters['durationSeconds'],1,300):
                raise EvidenceError('invalid bounded live lease')
        elif kind=='mark':
            if set(parameters)!={'code'} or parameters['code'] not in ('navigation_wrong','device_blank','connection_drop','sensor_missing','other'):
                raise EvidenceError('unsupported issue marker')
        elif parameters:
            raise EvidenceError('unexpected command parameters')
        now = int(time.time())
        command={'schema':2,'id':str(uuid.uuid4()),'kind':kind,'target':target,'parameters':parameters,'createdAt':now,'expiresAt':now+3600}
        with closing(self.connect()) as connection, connection:
            connection.execute('DELETE FROM commands WHERE (result IS NOT NULL OR expires<?) AND created<?',(now,now-86400))
            if connection.execute('SELECT count(*) FROM commands').fetchone()[0]>=100:
                raise EvidenceError('command history full; preserve results before removing the broker directory')
            if connection.execute('SELECT count(*) FROM commands WHERE result IS NULL AND expires>=?',(now,)).fetchone()[0]>=20:
                raise EvidenceError('pending command limit reached')
            connection.execute('INSERT INTO commands VALUES(?,?,?,?,?,NULL)',(command['id'],now,command['expiresAt'],kind,json.dumps(command)))
        return command

    def pending(self) -> list[dict]:
        with closing(self.connect()) as c:
            return [json.loads(row[0]) for row in c.execute('SELECT body FROM commands WHERE result IS NULL AND expires>=? ORDER BY created,id LIMIT 8',(int(time.time()),))]

    def acknowledge(self, value: dict) -> None:
        if not isinstance(value,dict) or set(value)!={'id','state','code'} or value['state'] not in ('accepted','rejected','interrupted') or not re.fullmatch('[a-z0-9_]{1,64}',value['code']):
            raise EvidenceError('invalid command acknowledgement')
        value = dict(value, id=str(uuid.UUID(value['id'])))
        encoded=json.dumps(value,sort_keys=True)
        with closing(self.connect()) as c, c:
            existing=c.execute('SELECT result FROM commands WHERE id=?',(value['id'],)).fetchone()
            if existing is None:
                raise EvidenceError('unknown command')
            if existing[0] is not None and existing[0]!=encoded:
                raise EvidenceError('command acknowledgement changed')
            c.execute('UPDATE commands SET result=? WHERE id=?',(encoded,value['id']))

    def status(self) -> dict:
        now=int(time.time())
        with closing(self.connect()) as c:
            row=c.execute('SELECT updated,body FROM status WHERE id=1').fetchone()
            bundles=[{'id':r[0],'createdAt':r[1],'sha256':r[2],'bytes':r[3],'coverage':{key:json.loads(r[4])[key] for key in ('eventCount','sources','missingRequiredSources','recordingCoverage','deliveryEvidence')}} for r in c.execute('SELECT * FROM bundles ORDER BY created DESC LIMIT 20')]
            commands=[{'command':json.loads(r[0]),'result':json.loads(r[1]) if r[1] else None} for r in c.execute('SELECT body,result FROM commands ORDER BY created DESC LIMIT 20')]
        return {'schema':2,'phone':json.loads(row[1]) if row else None,
                'phoneStatusAgeSeconds':now-row[0] if row else None,'bundles':bundles,'commands':commands}

    def phone_status(self, value: dict) -> None:
        required={'schema','phoneID','registryDigest','deviceDigest','firmwarePolicy','phonePolicy','collectionRunning'}
        if not isinstance(value,dict) or set(value)!=required or value['schema']!=2 or type(value['collectionRunning']) is not bool:
            raise EvidenceError('invalid phone status')
        value = dict(value, phoneID=str(uuid.UUID(value['phoneID'])))
        if not re.fullmatch('[0-9a-f]{64}',value['registryDigest']) or (value['deviceDigest'] is not None and not re.fullmatch('[0-9a-f]{16}',value['deviceDigest'])):
            raise EvidenceError('invalid observed device identity')
        phone_policy=value['phonePolicy']
        if phone_policy is not None:
            if not isinstance(phone_policy,dict) or set(phone_policy)!={'captureID','generation','mask','minimumLevel','durationSeconds','budgetBytes'}:
                raise EvidenceError('invalid phone policy')
            uuid.UUID(phone_policy['captureID'])
            if not all(integer(phone_policy[k]) for k in ('generation','mask','minimumLevel','durationSeconds','budgetBytes')):
                raise EvidenceError('invalid phone policy values')
        policy=value['firmwarePolicy']
        if policy is not None:
            allowed={'schema','schemaDigest','supportedMask','generation','mask','minimumLevel','active','captureId','remainingBytes','filteredCount','deadlineUptimeMs','baselineMinimumLevel','rawPayloads'}
            if not isinstance(policy,dict) or set(policy)!=allowed or policy['schema']!=2 or not re.fullmatch('[0-9a-f]{64}',policy['schemaDigest']) or not all(integer(policy[k]) for k in ('supportedMask','generation','mask','minimumLevel','remainingBytes','filteredCount','deadlineUptimeMs','baselineMinimumLevel')) or type(policy['active']) is not bool or policy['rawPayloads'] is not False:
                raise EvidenceError('invalid firmware policy status')
            if policy['captureId']:
                uuid.UUID(policy['captureId'])
        with closing(self.connect()) as c, c:
            previous=c.execute('SELECT body FROM status WHERE id=1').fetchone()
            if previous and json.loads(previous[0])['phoneID']!=value['phoneID']:
                raise EvidenceError('broker is already paired to a different phone')
            c.execute('INSERT OR REPLACE INTO status VALUES(1,?,?)',(int(time.time()),json.dumps(value)))

    def accept_upload(self, identifier: str, incoming: Path, sha: str) -> dict:
        identifier = str(uuid.UUID(identifier))
        if not re.fullmatch('[0-9a-f]{64}',sha):
            raise EvidenceError('invalid upload hash')
        if hashlib.sha256(incoming.read_bytes()).hexdigest()!=sha:
            raise EvidenceError('upload hash mismatch')
        with open_evidence(incoming) as evidence:
            coverage=evidence.coverage()
        size=incoming.stat().st_size
        with closing(self.connect()) as c, c:
            c.execute('BEGIN IMMEDIATE')
            existing=c.execute('SELECT sha256 FROM bundles WHERE id=?',(identifier,)).fetchone()
            if existing:
                if existing[0]!=sha:
                    raise EvidenceError('upload identity reused with different bytes')
                retained = self.root/'bundles'/f'{identifier}.zip'
                if not retained.is_file() or retained.is_symlink() or hashlib.sha256(retained.read_bytes()).hexdigest() != sha:
                    raise EvidenceError('acknowledged inbox evidence is missing or damaged')
                return {'schema':2,'id':identifier,'sha256':sha,'accepted':True}
            count,total=c.execute('SELECT count(*),coalesce(sum(bytes),0) FROM bundles').fetchone()
            if count>=20 or total+size>512*1024*1024:
                raise EvidenceError('inbox full; archive evidence explicitly before deleting')
            destination=self.root/'bundles'/f'{identifier}.zip'
            if destination.exists():
                # Recover a process interruption after rename, before SQLite COMMIT.
                if destination.is_symlink() or hashlib.sha256(destination.read_bytes()).hexdigest()!=sha:
                    raise EvidenceError('conflicting interrupted upload')
            else:
                os.replace(incoming,destination)
                os.chmod(destination,0o600)
            c.execute('INSERT INTO bundles VALUES(?,?,?,?,?)',(identifier,int(time.time()),sha,size,json.dumps(coverage)))
        return {'schema':2,'id':identifier,'sha256':sha,'accepted':True}


def request(root: Path, method: str, path: str, body: dict | None = None) -> dict:
    config=BrokerStore(root).config()
    host,port=origin_parts(config['origin'])
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname=False
    context.verify_mode=ssl.CERT_NONE
    context.minimum_version=ssl.TLSVersion.TLSv1_2
    connection=http.client.HTTPSConnection(host,port,context=context,timeout=15)
    try:
        connection.connect()
        if not hmac.compare_digest(hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest(),config['certificateSHA256']):
            raise EvidenceError('TLS pin mismatch; no credential was sent')
        payload=json.dumps(body).encode() if body is not None else b''
        connection.request(method,path,body=payload,headers={TOKEN_HEADER:config['token'],'Content-Type':'application/json'})
        response=connection.getresponse()
        raw=response.read(MAX_JSON+1)
        if response.status!=200 or len(raw)>MAX_JSON:
            raise EvidenceError(f'broker request rejected ({response.status})')
        return json.loads(raw)
    finally:
        connection.close()


class BrokerHTTPServer(HTTPServer):
    # One serialized request worker bounds RAM and concurrent uploads. A client
    # cannot hold it indefinitely: handshake, header and body have deadlines.
    allow_reuse_address=True
    def __init__(self,address,store:BrokerStore):
        self.store=store
        self.rejected_connections=0
        self.context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version=ssl.TLSVersion.TLSv1_2
        self.context.load_cert_chain(store.root/'server.crt',store.root/'server.key')
        super().__init__(address,BrokerHandler)
    def handle_error(self, request, client_address):
        # Peer disconnects are expected (including pin rejection). Never print
        # socket addresses, headers or exception bodies into agent-visible logs.
        self.rejected_connections += 1
    def get_request(self):
        sock,address=super().get_request()
        sock.settimeout(15)
        try:
            return self.context.wrap_socket(sock,server_side=True),address
        except Exception:
            sock.close()
            raise


class BrokerHandler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):
        pass # never log credentials, paths or arbitrary request content
    def reply(self,code:int,value:dict):
        raw=json.dumps(value,sort_keys=True).encode()
        self.send_response(code)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(raw)))
        self.send_header('Cache-Control','no-store')
        self.send_header('Connection','close')
        self.end_headers()
        self.wfile.write(raw)
        self.close_connection=True
    def authorized(self)->bool:
        config=self.server.store.config()
        tokens=self.headers.get_all(TOKEN_HEADER) or []
        return len(tokens)==1 and len(tokens[0])==64 and int(time.time())<config['expiresAt'] and hmac.compare_digest(tokens[0],config['token'])
    def body_length(self, maximum:int)->int:
        sizes=self.headers.get_all('Content-Length') or []
        if self.headers.get('Transfer-Encoding') or len(sizes)!=1 or not re.fullmatch('[0-9]{1,10}',sizes[0]):
            raise EvidenceError('bounded content length required')
        length=int(sizes[0])
        if length>maximum:
            raise EvidenceError('request too large')
        return length
    def json_body(self):
        length=self.body_length(MAX_JSON)
        raw=self.rfile.read(length)
        if len(raw)!=length:
            raise EvidenceError('truncated request')
        return json.loads(raw)
    def do_GET(self):
        self.dispatch()
    def do_POST(self):
        self.dispatch()
    def do_PUT(self):
        self.dispatch()
    def dispatch(self):
        incoming=None
        try:
            if not self.authorized():
                self.reply(401,{'error':'unauthorized'})
                return
            store=self.server.store
            if self.command=='GET' and self.path=='/v2/commands':
                result={'schema':2,'commands':store.pending()}
            elif self.command=='GET' and self.path=='/v2/status':
                result=store.status()
            elif self.command=='POST' and self.path=='/v2/commands':
                value=self.json_body()
                if not isinstance(value,dict) or set(value)!={'kind','target','parameters'}:
                    raise EvidenceError('invalid command')
                result=store.enqueue(value['kind'],value['target'],value['parameters'])
            elif self.command=='POST' and self.path=='/v2/ack':
                store.acknowledge(self.json_body()); result={'ok':True}
            elif self.command=='POST' and self.path=='/v2/live':
                value=self.json_body()
                phone=store.status()['phone']
                if phone is None or (value.get('device')!='iphone' and value.get('device')!=phone['deviceDigest']):
                    raise EvidenceError('live source is not the observed paired device')
                store.live.accept(value); result={'ok':True}
            elif self.command=='POST' and self.path=='/v2/live/query':
                value=self.json_body()
                if not isinstance(value,dict) or set(value)!={'device','cursor','limit'}:
                    raise EvidenceError('invalid live query')
                result=store.live.query(value['device'],value['cursor'],value['limit'])
            elif self.command=='POST' and self.path=='/v2/phone':
                store.phone_status(self.json_body()); result={'ok':True}
            elif self.command=='PUT' and re.fullmatch(r'/v2/uploads/[0-9a-f-]{36}',self.path):
                identifier=self.path.rsplit('/',1)[1]
                uuid.UUID(identifier)
                expected=self.body_length(MAX_BYTES)
                fd,name=tempfile.mkstemp(prefix='.upload-',dir=store.root/'pending')
                incoming=Path(name)
                deadline=time.monotonic()+120
                with os.fdopen(fd,'wb') as handle:
                    remaining=expected
                    while remaining:
                        if time.monotonic()>deadline:
                            raise EvidenceError('upload deadline exceeded')
                        block=self.rfile.read(min(64*1024,remaining))
                        if not block:
                            raise EvidenceError('truncated upload')
                        handle.write(block); remaining-=len(block)
                    handle.flush();os.fsync(handle.fileno())
                result=store.accept_upload(identifier,incoming,self.headers.get('X-Content-SHA256',''))
            else:
                self.reply(404,{'error':'not_found'});return
            self.reply(200,result)
        except (EvidenceError,ValueError,TypeError,KeyError,AttributeError,OSError,sqlite3.Error,subprocess.SubprocessError,zipfile.BadZipFile,v1.DiagnosticError):
            try:
                self.reply(400,{'error':'request_rejected'})
            except OSError:
                pass
        finally:
            if incoming is not None:
                incoming.unlink(missing_ok=True)


def serve(root:Path,listen:str='127.0.0.1'):
    store=BrokerStore(root)
    host,port=origin_parts(store.config()['origin'])
    if listen not in ('127.0.0.1','0.0.0.0',host):
        raise EvidenceError('listen address must be loopback or the explicit configured LAN address')
    with BrokerHTTPServer((listen,port),store) as server:
        server.serve_forever(poll_interval=.5)
