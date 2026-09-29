#!/usr/bin/env python3
"""Isolated HTTPS checks using the real API code with only its endpoint guard widened to loopback in a temporary source copy."""

import hashlib
import http.server
import json
import os
import pathlib
import socket
import ssl
import subprocess
import tempfile
import threading
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST, PORT = "localhost", 8643


class Fixture(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    records = pathlib.Path()

    def log_message(self, *_):
        pass

    def do_POST(self):
        scenario = self.path.split("/")[-3]
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        record = {
            "method": self.command,
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
            "accept": self.headers.get("Accept"),
            "payload": json.loads(raw),
        }
        (self.records / f"{scenario}.json").write_text(json.dumps(record))

        if scenario == "http-401":
            self.reply(401, "application/json", b'{"detail":"unauthorized"}')
        elif scenario == "redirect":
            self.send_response(302)
            self.send_header("Location", f"https://{HOST}:{PORT}/redirect-target")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif scenario == "wrong-content-type":
            self.reply(200, "application/json", b'{"ok":true}')
        elif scenario == "sse-error":
            self.chunked(b'event: error\ndata: {"message":"fixture failure"}\n\nevent: run.completed\ndata: {"status":"done"}\n\nevent: done\ndata: {}\n\n')
        elif scenario == "truncated":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.write_chunk(b'event: run.started\ndata: {"run_id":"r1"}\n\n')
            self.write_chunk(b'event: assistant.delta\ndata: {"text":"partial"}\n\n')
            self.wfile.flush()
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
        elif scenario == "cancel":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.write_chunk(b'event: run.started\ndata: {"run_id":"r1"}\n\n')
            self.wfile.flush()
            time.sleep(3)
            try:
                self.write_chunk(b'event: run.completed\ndata: {"status":"done"}\n\nevent: done\ndata: {}\n\n')
                self.wfile.write(b"0\r\n\r\n")
            except OSError:
                pass
        else:
            self.valid()

    def reply(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def write_chunk(self, data):
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()

    def chunked(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        # Force a network chunk boundary between the two bytes of “é”.
        split = body.index(b"\xc3\xa9") + 1 if b"\xc3\xa9" in body else len(body) // 2
        chunks = [body[:split], body[split:split + 19], body[split + 19:]]
        for chunk in chunks:
            if chunk:
                self.write_chunk(chunk)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def valid(self):
        body = (
            b": heartbeat\r\n\r\n"
            b'event: run.started\r\ndata: {"run_id":"r1"}\r\n\r\n'
            b'event: assistant.delta\r\ndata: {"text":"caf\xc3\xa9"}\r\n\r\n'
            b'event: assistant.delta\ndata: {"text":\ndata: "multiline"}\n\n'
            b'event: assistant.completed\r\ndata: {}\r\n\r\n'
            b'event: run.completed\ndata: {"status":"done"}\n\n'
            b'event: done\ndata: {}\r\n\r\n'
        )
        self.chunked(body)


def main():
    with tempfile.TemporaryDirectory(prefix="hermes-stream-checks-") as temp:
        work = pathlib.Path(temp)
        records = work / "records"
        records.mkdir()
        cert, key = work / "cert.pem", work / "key.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key), "-out", str(cert), "-days", "1",
            "-subj", "/CN=localhost",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        der = ssl.PEM_cert_to_DER_cert(cert.read_text())
        fingerprint = hashlib.sha256(der).hexdigest()
        Fixture.records = records
        server = http.server.ThreadingHTTPServer((HOST, PORT), Fixture)
        server.daemon_threads = True
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=cert, keyfile=key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        swift_bin = work / "stream-transport-checks"
        api_source = (ROOT / "HermesPocket/HermesAPI.swift").read_text()
        production_guard = 'guard scheme == "https", url.port == 8643, PairingQR.isLocalHost(host) else { throw HermesError.invalidURL }'
        fixture_guard = 'guard scheme == "https", url.port == 8643, PairingQR.isLocalHost(host) || host == "localhost" else { throw HermesError.invalidURL }'
        assert production_guard in api_source, "Production HTTPS endpoint guard changed; review the isolated fixture carveout"
        api_fixture = work / "HermesAPI.fixture.swift"
        api_fixture.write_text(api_source.replace(production_guard, fixture_guard, 1))
        subprocess.run([
            "swiftc", "-parse-as-library",
            str(ROOT / "HermesPocket/Models.swift"),
            str(ROOT / "HermesPocket/KeychainStore.swift"),
            str(api_fixture),
            str(ROOT / "Tests/StreamTransportChecks.swift"),
            "-o", str(swift_bin),
        ], check=True)

        endpoint = f"https://{HOST}:{PORT}"
        try:
            print("Fixture-only endpoint exception: temporary HermesAPI copy admits localhost; trust, streaming, and parsing code are unchanged.")
            for scenario in ("wrong-pin", "http-401", "redirect", "wrong-content-type", "sse-error", "truncated", "valid", "cancel"):
                subprocess.run([str(swift_bin), scenario, endpoint, fingerprint], check=True, timeout=8)

            assert not (records / "wrong-pin.json").exists(), "wrong pin reached HTTP"
            request = json.loads((records / "valid.json").read_text())
            assert request["method"] == "POST"
            assert request["authorization"] == "Bearer fixture-only-token"
            assert request["accept"] == "text/event-stream"
            content = request["payload"]["input"]
            assert content[0] == {"type": "text", "text": "hello"}
            assert content[1] == {
                "type": "image_url",
                "image_url": {"url": "data:image/png;base64,AAH+/w==", "detail": "high"},
            }
            print("PASS request payload: text plus image bytes preserved; fixture-only authorization")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)


if __name__ == "__main__":
    main()
