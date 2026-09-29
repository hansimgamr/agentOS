"""Isolated TLS transport tests; no production files, keys or chats are touched."""
import contextlib
import hashlib
import http.client
import io
import json
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacRelay'))
import credentials
import relay


class Upstream(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.server.received_auth = self.headers.get('Authorization')
        self.server.received_path = self.path
        if self.path.endswith('/truncated/messages'):
            payload = b'event: assistant.delta\ndata: {"delta":"partial"}\n\n'
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(payload) + 100))
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            self.close_connection = True
            return
        payload = b'{"ok":true}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_DELETE = do_GET


class RelayTransport(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.stack = contextlib.ExitStack()
        for name in ('DEVICES', 'PAIRING', 'LOCK'):
            self.stack.enter_context(patch.object(credentials, name, root / name.lower()))
        self.stack.enter_context(patch.object(credentials, 'PRIVATE', root))
        self.upstream = ThreadingHTTPServer(('localhost', 0), Upstream)
        self.stack.enter_context(patch.object(relay, 'HERMES', self.upstream.server_address))
        cert, key = root / 'cert.pem', root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).digest()
        self.server = ThreadingHTTPServer(('localhost', 0), relay.Bridge)
        self.server.master_key = 'isolated-test-master-key'
        self.server.certificate_fingerprint = self.pin.hex()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.threads = []
        for server in (self.upstream, self.server):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.threads.append(thread)

    def tearDown(self):
        for server in (self.server, self.upstream):
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join(timeout=2)
        self.stack.close()
        self.temp.cleanup()

    def call(self, method, path, body=None, token=None):
        connection = http.client.HTTPSConnection(*self.server.server_address,
            context=ssl._create_unverified_context(), timeout=3)
        connection.connect()
        self.assertEqual(hashlib.sha256(connection.sock.getpeercert(binary_form=True)).digest(), self.pin)
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        connection.request(method, path, json.dumps(body) if body is not None else None, headers)
        response = connection.getresponse()
        data = response.read()
        status = response.status
        connection.close()
        return status, json.loads(data) if data.startswith(b'{') else {}

    def issue(self):
        code = credentials.create_pairing()
        status, device = self.call('POST', '/pair/claim', {'code': code, 'name': 'Test phone'})
        self.assertEqual(status, 200)
        listed = credentials.list_devices()[0]
        self.assertEqual(listed['certificate_fingerprint'], self.pin.hex())
        self.assertEqual(listed['certificate_accepted_at'], device['certificate_accepted_at'])
        self.assertIsInstance(device['certificate_accepted_at'], int)
        return code, device

    def test_claim_replay_rotation_revoke_and_upstream_key_isolation(self):
        code, device = self.issue()
        self.assertEqual(self.call('POST', '/pair/claim', {'code': code, 'name': 'Replay'})[0], 403)
        self.assertEqual(self.call('GET', '/health')[0], 401)
        self.assertEqual(self.call('GET', '/health', token=self.server.master_key)[0], 401)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.call('GET', '/health', token=device['token'])[0], 200)
        self.assertEqual(self.upstream.received_auth, 'Bearer ' + self.server.master_key)
        status, rotated = self.call('POST', '/device/rotate', {}, device['token'])
        self.assertEqual(status, 200)
        self.assertEqual(credentials.authenticate(rotated['token']), device['device_id'])
        self.assertEqual(credentials.authenticate(device['token']), device['device_id'])
        credentials.revoke(device['device_id'])
        self.assertEqual(self.call('GET', '/health', token=rotated['token'])[0], 401)
        self.assertEqual(self.call('GET', '/health', token=device['token'])[0], 401)

    def test_route_allowlist_and_bad_claim_inputs(self):
        _, device = self.issue()
        self.assertEqual(self.call('POST', '/pair/claim', {'code': [], 'name': 'Phone'})[0], 400)
        self.assertEqual(self.call('POST', '/pair/claim', {'code': 'wrong', 'name': 'Phone'})[0], 403)
        self.assertEqual(self.call('DELETE', '/api/sessions', token=device['token'])[0], 404)
        self.assertEqual(self.call('GET', '/admin', token=device['token'])[0], 404)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.call('DELETE', '/api/sessions/disposable', token=device['token'])[0], 200)
        self.assertEqual(self.upstream.received_path, '/api/sessions/disposable')

    def test_truncated_upstream_stream_closes_without_appending_502(self):
        _, device = self.issue()
        connection = http.client.HTTPSConnection(*self.server.server_address,
            context=ssl._create_unverified_context(), timeout=3)
        connection.request('GET', '/api/sessions/truncated/messages',
                           headers={'Authorization': 'Bearer ' + device['token']})
        response = connection.getresponse()
        body = response.read()
        status = response.status
        connection.close()
        self.assertEqual(status, 200)
        self.assertIn(b'event: assistant.delta', body)
        self.assertNotIn(b'502 Bad Gateway', body)

    def test_oserror_after_stream_headers_never_appends_second_status(self):
        _, device = self.issue()

        class BrokenResponse:
            status = 200
            reason = 'OK'

            def __init__(self):
                self.first = True

            def getheaders(self):
                return [('Content-Type', 'text/event-stream')]

            def read1(self, _size):
                if self.first:
                    self.first = False
                    return b'event: assistant.delta\ndata: {"delta":"partial"}\n\n'
                raise OSError('isolated simulated upstream reset')

        class BrokenConnection:
            def __init__(self, *_args, **_kwargs):
                self.response = BrokenResponse()

            def request(self, *_args, **_kwargs):
                pass

            def getresponse(self):
                return self.response

            def close(self):
                pass

        with patch.object(relay.http.client, 'HTTPConnection', BrokenConnection):
            connection = http.client.HTTPSConnection(*self.server.server_address,
                context=ssl._create_unverified_context(), timeout=3)
            connection.request('GET', '/api/sessions/simulated/messages',
                               headers={'Authorization': 'Bearer ' + device['token']})
            response = connection.getresponse()
            body = response.read()
            status = response.status
            connection.close()
        self.assertEqual(status, 200)
        self.assertIn(b'event: assistant.delta', body)
        self.assertNotIn(b'502 Bad Gateway', body)


if __name__ == '__main__':
    unittest.main()
