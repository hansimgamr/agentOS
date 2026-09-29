"""Small HTTPS bridge from the iPhone to Hermes' localhost API."""

import hashlib
import hmac
import http.client
import ipaddress
import json
import re
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import credentials


HERMES = ("localhost", 8642)
PRIVATE = Path.home() / ".hermes"

def listen_address():
    path = PRIVATE / "relay" / "config.json"
    if not path.exists():
        raise ValueError("Prepare connection before starting the relay")
    config = json.loads(path.read_text())
    host = config.get("listen_host", "")
    address = ipaddress.ip_address(host)
    if not address.is_private or address.is_loopback or address.is_link_local or address.is_unspecified or address.is_multicast or config.get("listen_port") != 8643:
        raise ValueError("Invalid relay listener")
    return host, 8643

SKIP = {"connection", "content-length", "host", "keep-alive", "proxy-connection", "transfer-encoding"}
ROUTES = {
    "DELETE": (r"/api/sessions/[A-Za-z0-9_.-]+",),
    "GET": (r"/health", r"/api/sessions", r"/api/sessions/[A-Za-z0-9_.-]+/messages"),
    "POST": (r"/api/sessions", r"/api/sessions/[A-Za-z0-9_.-]+/chat/stream",
             r"/v1/runs/[A-Za-z0-9_.-]+/approval"),
}


def api_key():
    for line in (PRIVATE / ".env").read_text().splitlines():
        if line.startswith("API_SERVER_KEY="):
            return line.split("=", 1)[1].strip().strip("\"'")
    raise RuntimeError("API_SERVER_KEY is missing")


class Bridge(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass  # Paths and headers may contain private agent data.

    def do_GET(self):
        self.forward()

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == "/pair/claim":
            self.pair()
        elif path == "/pair/migrate":
            self.migrate()
        elif path == "/device/rotate":
            device_id = self.device_id()
            if device_id:
                result = credentials.rotate(device_id)
                self.json_response(200, result) if result else self.send_error(401)
        else:
            self.forward()

    def do_PUT(self):
        self.send_error(405)

    def do_DELETE(self):
        self.forward()

    def json_response(self, status, value):
        data = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def body_json(self):
        if self.headers.get("Transfer-Encoding"):
            self.send_error(400)
            return None
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 2048:
                raise ValueError
            value = json.loads(self.rfile.read(length))
            if isinstance(value, dict):
                return value
        except (ValueError, json.JSONDecodeError):
            pass
        self.send_error(400)
        return None

    def device_id(self):
        authorization = self.headers.get("Authorization", "")
        token = authorization[7:] if authorization.startswith("Bearer ") else ""
        device_id = credentials.authenticate(token)
        if not device_id:
            self.send_error(401)
        return device_id

    def pair(self):
        body = self.body_json()
        if body is None:
            return
        code, name = body.get("code"), body.get("name")
        if not isinstance(code, str) or not isinstance(name, str) or not name.strip():
            self.send_error(400)
            return
        result = credentials.claim_pairing(code, name.strip(), getattr(self.server, "certificate_fingerprint", None))
        self.json_response(200, result) if result else self.send_error(403)

    def migrate(self):
        if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + self.server.master_key):
            self.send_error(401)
            return
        result = credentials.migrate_legacy("iPhone (upgraded)")
        self.json_response(200, result) if result else self.send_error(403)

    def forward(self):
        self.close_connection = True
        if not self.device_id():
            return
        path = urlsplit(self.path).path
        if not any(re.fullmatch(route, path) for route in ROUTES.get(self.command, ())):
            self.send_error(404)
            return
        if self.headers.get("Transfer-Encoding"):
            self.send_error(400)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        if not 0 <= length <= 25_000_000:
            self.send_error(413)
            return
        body = self.rfile.read(length) if length else None
        headers = {"Host": f"{HERMES[0]}:{HERMES[1]}",
                   "Authorization": "Bearer " + self.server.master_key,
                   "Connection": "close"}
        for name in ("Accept", "Content-Type"):
            if self.headers.get(name):
                headers[name] = self.headers[name]
        connection = http.client.HTTPConnection(*HERMES, timeout=120)
        response_started = False
        try:
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            # Once a response status line is on the client socket, a later upstream
            # stream error must close the truncated response. Appending a fresh 502
            # would corrupt SSE data and falsely look like part of the original body.
            response_started = True
            self.send_response_only(response.status, response.reason)
            for name, value in response.getheaders():
                if name.lower() not in SKIP:
                    self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()
            print(f"{self.command} {response.status}", flush=True)
            while chunk := response.read1(16384):
                self.wfile.write(chunk)
                self.wfile.flush()
        except (http.client.HTTPException, OSError):
            if not response_started:
                try:
                    self.send_error(502)
                except OSError:
                    pass
        finally:
            connection.close()


def main():
    address = listen_address()
    server = ThreadingHTTPServer(address, Bridge)
    server.master_key = api_key()
    certificate = (PRIVATE / "relay" / "relay.crt").read_text()
    server.certificate_fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(certificate)).hexdigest()
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain(PRIVATE / "relay" / "relay.crt", PRIVATE / "relay" / "relay.key")
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    print(f"Hermes HTTPS relay listening on {address[0]}:{address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
