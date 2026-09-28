"""Rotate the Mac-only Hermes API key after a phone has a device credential."""

import http.client
import os
import secrets
import subprocess
import tempfile
import time
from pathlib import Path

import credentials
from relay import HERMES, PRIVATE


ENV = PRIVATE / ".env"


def replace_key(original, replacement):
    lines = original.splitlines(keepends=True)
    matches = [i for i, line in enumerate(lines) if line.startswith("API_SERVER_KEY=")]
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one API_SERVER_KEY entry")
    old = lines[matches[0]].split("=", 1)[1].strip().strip("\"'")
    lines[matches[0]] = "API_SERVER_KEY=" + replacement + "\n"
    return old, "".join(lines)


def write_env(contents):
    if ENV.is_symlink() or ENV.stat().st_uid != os.getuid():
        raise RuntimeError("Refusing to replace an unowned or linked .env file")
    fd, temporary = tempfile.mkstemp(prefix=".env-", dir=ENV.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, ENV)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def restart():
    domain = f"gui/{os.getuid()}"
    for label in ("ai.hermes.gateway", "com.agentos.relay"):
        subprocess.run(["launchctl", "kickstart", "-k", f"{domain}/{label}"], check=True,
                       stdout=subprocess.DEVNULL)


def backend_status(key):
    connection = http.client.HTTPConnection(*HERMES, timeout=3)
    try:
        connection.request("GET", "/api/sessions?limit=1", headers={"Authorization": "Bearer " + key})
        response = connection.getresponse()
        response.read()
        return response.status
    finally:
        connection.close()


def wait_for(key, expected):
    until = time.monotonic() + 90
    while time.monotonic() < until:
        try:
            if backend_status(key) == expected:
                return
        except OSError:
            pass
        time.sleep(2)
    raise RuntimeError("Hermes API did not accept the expected credential after restart")


def main():
    if not credentials.list_devices():
        raise RuntimeError("Pair a phone before rotating the Mac key")
    original = ENV.read_text()
    new = secrets.token_urlsafe(48)
    old, updated = replace_key(original, new)
    if backend_status(old) != 200:
        raise RuntimeError("Current Hermes key failed the preflight check")
    try:
        write_env(updated)
        restart()
        wait_for(new, 200)
        if backend_status(old) != 401:
            raise RuntimeError("The previous key is still accepted")
    except Exception:
        write_env(original)
        restart()
        wait_for(old, 200)
        raise
    print("Mac-only Hermes key rotated. The previous key is rejected; paired phones keep working.")


if __name__ == "__main__":
    main()
