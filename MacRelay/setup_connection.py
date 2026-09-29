"""Prepare the local bridge for an existing Hermes installation; never install Hermes."""
import fcntl
import ipaddress
import os
import plistlib
import secrets
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path

import credentials

HOME = Path.home()
ROOT = HOME / '.hermes'
BRIDGE = ROOT / 'relay'
AGENTS = HOME / 'Library' / 'LaunchAgents'
LABEL = 'com.agentos.relay'


def hermes_executable():
    choices = [shutil.which('hermes'), HOME / '.local/bin/hermes',
               ROOT / 'hermes-agent/.hermes/bin/hermes', ROOT / 'hermes-agent/.venv/bin/hermes']
    return next((str(p) for p in choices if p and Path(p).is_file() and os.access(p, os.X_OK)), None)


def local_address():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
        connection.connect(('fixture-mac.local', 9))  # Route lookup only; no packet is sent.
        address = connection.getsockname()[0]
    value = ipaddress.ip_address(address)
    if not value.is_private or value.is_loopback or value.is_link_local or value.is_unspecified or value.is_multicast:
        raise RuntimeError('local_network_required')
    return address


def run(arguments, timeout=60):
    subprocess.run(arguments, check=True, timeout=timeout, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def owned_file(path):
    if path.is_symlink() or (path.exists() and path.stat().st_uid != os.getuid()):
        raise RuntimeError('unsafe_setup_path')


def ensure_api_key():
    path = ROOT / '.env'
    owned_file(path)
    original = path.read_text() if path.exists() else ''
    entries = [line for line in original.splitlines() if line.startswith('API_SERVER_KEY=')]
    if len(entries) > 1:
        raise RuntimeError('ambiguous_api_configuration')
    if entries:
        if len(entries[0].split('=', 1)[1].strip().strip('"\'')) < 16:
            raise RuntimeError('existing_api_key_needs_attention')
        return
    fd, temporary = tempfile.mkstemp(prefix='.agentos-env-', dir=ROOT)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(original + ('\n' if original and not original.endswith('\n') else '')
                         + 'API_SERVER_KEY=' + secrets.token_urlsafe(32) + '\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def prepare():
    executable = hermes_executable()
    if not executable:
        return {'ok': False, 'error': 'hermes_not_installed'}
    address = local_address()
    owned_file(ROOT)
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    BRIDGE.mkdir(mode=0o700, parents=True, exist_ok=True)
    owned_file(BRIDGE)
    owned_file(BRIDGE / 'setup.lock')
    with open(BRIDGE / 'setup.lock', 'a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        ensure_api_key()
        # Healthy Hermes instances need no configuration changes or restart.
        import companion
        if not companion._backend_health()['available']:
            for key, value in [('enabled', 'true'), ('host', 'localhost'), ('port', '8642')]:
                run([executable, 'config', 'set', 'platforms.api_server.' + key, value])
            if not (AGENTS / 'ai.hermes.gateway.plist').exists():
                run([executable, 'gateway', 'install'])
            run([executable, 'gateway', 'restart'], timeout=120)
        cert, key = BRIDGE / 'relay.crt', BRIDGE / 'relay.key'
        owned_file(cert); owned_file(key)
        if cert.exists() != key.exists():
            raise RuntimeError('incomplete_certificate')
        if not cert.exists():
            with tempfile.TemporaryDirectory(dir=BRIDGE) as temporary:
                config = Path(temporary) / 'openssl.cnf'
                config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n'
                                  '[dn]\nCN=agentOS Relay\n[ext]\nsubjectAltName=IP:' + address + '\n')
                run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650',
                     '-config', str(config), '-keyout', str(Path(temporary)/'relay.key'),
                     '-out', str(Path(temporary)/'relay.crt')])
                for target in [key, cert]:
                    shutil.move(str(Path(temporary)/target.name), target)
                    target.chmod(0o600)
        source = Path(__file__).parent
        for name in ['relay.py', 'credentials.py']:
            target = BRIDGE / name
            owned_file(target)
            if target.resolve() != (source/name).resolve():
                shutil.copyfile(source/name, target)
                target.chmod(0o600)
        owned_file(BRIDGE / 'config.json')
        credentials.write(BRIDGE / 'config.json', {'listen_host': address, 'listen_port': 8643})
        AGENTS.mkdir(parents=True, exist_ok=True)
        launch = AGENTS / (LABEL + '.plist')
        owned_file(launch)
        definition = {'Label': LABEL, 'ProgramArguments': ['/usr/bin/python3', str(BRIDGE/'relay.py')],
                      'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 5,
                      'StandardOutPath': str(BRIDGE/'relay.log'), 'StandardErrorPath': str(BRIDGE/'relay.error.log')}
        launch.write_bytes(plistlib.dumps(definition)); launch.chmod(0o600)
        domain = 'gui/' + str(os.getuid())
        subprocess.run(['launchctl', 'bootout', domain + '/' + LABEL], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(['launchctl', 'bootstrap', domain, str(launch)])
        return {'ok': True, 'prepared': True}
