"""JSON stdio interface for the native macOS companion app.

Run once per request: ``python3 companion.py``. Exactly one JSON object is read
from stdin and one sanitized JSON object is written to stdout. Never log ticket
codes, API credentials, request payloads, or agent content.
"""

import hashlib
import http.client
import json
import re
import ssl
import sys
import subprocess
import setup_connection
from urllib.parse import urlencode

import credentials
import relay


MAX_REQUEST = 4096
DEVICE_ID = re.compile(r"^[0-9a-f]{16}$")


def _certificate_fingerprint():
    pem = (relay.PRIVATE / "relay" / "relay.crt").read_text()
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()


def _endpoint():
    host, port = relay.listen_address()
    return f"https://{host}:{port}"


def _backend_health():
    connection = None
    try:
        key = relay.api_key()
        connection = http.client.HTTPConnection(*relay.HERMES, timeout=3)
        connection.request("GET", "/api/sessions?limit=1",
                           headers={"Authorization": "Bearer " + key})
        status = connection.getresponse().status
        return {"available": 200 <= status < 300,
                "detail": "ready" if 200 <= status < 300 else "unauthorized" if status in (401, 403) else "unavailable"}
    except (OSError, ValueError, RuntimeError, http.client.HTTPException):
        return {"available": False, "detail": "unavailable"}
    finally:
        if connection:
            connection.close()


def _relay_health(fingerprint):
    connection = None
    try:
        context = ssl._create_unverified_context()
        connection = http.client.HTTPSConnection(*relay.listen_address(), context=context, timeout=3)
        connection.connect()
        observed = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest()
        if observed != fingerprint:
            return {"available": False, "detail": "certificate_mismatch"}
        connection.request("GET", "/health")
        status = connection.getresponse().status
        # Relay endpoints require per-device credentials; 401 proves it is live.
        return {"available": status == 401, "detail": "ready" if status == 401 else "unavailable"}
    except (OSError, ValueError, ssl.SSLError, http.client.HTTPException):
        return {"available": False, "detail": "unavailable"}
    finally:
        if connection:
            connection.close()


def status():
    fingerprint = None
    try:
        fingerprint = _certificate_fingerprint()
    except (OSError, ValueError, ssl.SSLError):
        pass
    relay_state = _relay_health(fingerprint) if fingerprint else {"available": False, "detail": "not_configured"}
    try:
        endpoint = _endpoint()
    except (OSError, ValueError):
        endpoint = None
        relay_state = {"available": False, "detail": "not_configured"}
    result = {
        "ok": True,
        "hermes_installed": setup_connection.hermes_executable() is not None,
        "backend": _backend_health(),
        "relay": {
            "available": relay_state["available"],
            "endpoint": endpoint,
            "fingerprint": fingerprint,
        },
        "pending_pairing": credentials.pending_pairing(),
    }
    result["relay"]["detail"] = relay_state["detail"]
    return result


def dispatch(request):
    if not isinstance(request, dict):
        return {"ok": False, "error": "invalid_request"}
    action = request.get("action")
    if action == "prepare_connection":
        return setup_connection.prepare()
    if action == "status":
        return status()
    if action == "create_pairing":
        fingerprint = _certificate_fingerprint()
        endpoint = _endpoint()
        if not _relay_health(fingerprint)["available"]:
            return {"ok": False, "error": "relay_unavailable"}
        ticket = credentials.create_pairing_ticket()
        qr_url = "hermespocket://pair?" + urlencode({
            "v": "2", "endpoint": endpoint, "fingerprint": fingerprint,
            "code": ticket["code"],
        })
        return {"ok": True, "ticket_id": ticket["ticket_id"],
                "expires_at": ticket["expires_at"], "qr_url": qr_url,
                "endpoint": endpoint, "fingerprint": fingerprint}
    if action == "cancel_pairing":
        ticket_id = request.get("ticket_id")
        if not isinstance(ticket_id, str):
            return {"ok": False, "error": "invalid_request"}
        return {"ok": True, "cancelled": credentials.cancel_pairing(ticket_id)}
    if action == "list_devices":
        return {"ok": True, "devices": credentials.list_devices()}
    if action == "revoke":
        device_id = request.get("device_id")
        if not isinstance(device_id, str) or not DEVICE_ID.fullmatch(device_id):
            return {"ok": False, "error": "invalid_request"}
        return {"ok": True, "revoked": credentials.revoke(device_id)}
    return {"ok": False, "error": "unknown_action"}


def main():
    raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
    if len(raw) > MAX_REQUEST:
        response = {"ok": False, "error": "request_too_large"}
    else:
        try:
            request = json.loads(raw)
            response = dispatch(request)
        except (json.JSONDecodeError, UnicodeDecodeError):
            response = {"ok": False, "error": "invalid_json"}
        except (OSError, ValueError, RuntimeError, ssl.SSLError, subprocess.SubprocessError):
            response = {"ok": False, "error": "operation_unavailable"}
    sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
