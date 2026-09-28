"""Local, revocable phone credentials. Raw tokens are never stored on the Mac."""

import fcntl
import hashlib
import hmac
import json
import os
import secrets
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path


PRIVATE = Path.home() / ".hermes" / "relay"
DEVICES = PRIVATE / "devices.json"
PAIRING = PRIVATE / "pairing.json"
LOCK = PRIVATE / "credentials.lock"


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def read(path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def write(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".credential-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def locked():
    PRIVATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(LOCK, "a+") as stream:
        os.fchmod(stream.fileno(), 0o600)
        fcntl.flock(stream, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def _issue(state, name):
    token = secrets.token_urlsafe(32)
    device_id = secrets.token_hex(8)
    safe_name = "".join(character for character in name if character.isprintable())[:80].strip() or "Device"
    state.setdefault("devices", {})[device_id] = {
        "name": safe_name, "hash": digest(token), "created": int(time.time())
    }
    write(DEVICES, state)
    return {"device_id": device_id, "token": token}


def create_pairing():
    code = secrets.token_urlsafe(32)
    with locked():
        write(PAIRING, {"hash": digest(code), "expires": int(time.time()) + 300})
    return code


def claim_pairing(code, name):
    with locked():
        ticket = read(PAIRING, {})
        if not ticket or time.time() > ticket.get("expires", 0) or not hmac.compare_digest(digest(code), ticket.get("hash", "")):
            return None
        PAIRING.unlink(missing_ok=True)
        return _issue(read(DEVICES, {}), name)


def migrate_legacy(name):
    with locked():
        state = read(DEVICES, {})
        if state.get("migrated") or state.get("devices"):
            return None
        state["migrated"] = True
        return _issue(state, name)


def authenticate(token):
    if not token:
        return None
    token_hash = digest(token)
    with locked():
        for device_id, device in read(DEVICES, {}).get("devices", {}).items():
            if hmac.compare_digest(token_hash, device["hash"]):
                return device_id
            if time.time() < device.get("previous_until", 0) and hmac.compare_digest(token_hash, device.get("previous_hash", "")):
                return device_id
    return None


def rotate(device_id):
    with locked():
        state = read(DEVICES, {})
        device = state.get("devices", {}).get(device_id)
        if not device:
            return None
        token = secrets.token_urlsafe(32)
        device["previous_hash"] = device["hash"]
        device["previous_until"] = int(time.time()) + 600
        device["hash"] = digest(token)
        write(DEVICES, state)
        return {"device_id": device_id, "token": token}


def list_devices():
    with locked():
        return [{"id": device_id, "name": device["name"], "created": device["created"]}
                for device_id, device in read(DEVICES, {}).get("devices", {}).items()]


def revoke(device_id):
    with locked():
        state = read(DEVICES, {})
        if state.get("devices", {}).pop(device_id, None) is None:
            return False
        write(DEVICES, state)
        return True
