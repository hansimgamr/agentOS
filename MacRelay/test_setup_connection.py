import socket
import ipaddress
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import setup_connection as setup
import companion
import credentials
import relay


FIXTURE_HOST = ".".join(map(str, [192, 168, 50, 7]))


class SetupChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.hermes = self.root / 'hermes'
        self.bridge = self.hermes / 'relay'
        self.agents = self.root / 'agents'
        self.patches = [patch.object(setup, 'ROOT', self.hermes), patch.object(setup, 'BRIDGE', self.bridge),
                        patch.object(setup, 'AGENTS', self.agents)]
        for item in self.patches: item.start()

    def tearDown(self):
        for item in reversed(self.patches): item.stop()
        self.tmp.cleanup()

    def test_route_lookup_and_missing_interface(self):
        with patch.object(setup.subprocess, 'check_output', side_effect=[
                '   interface: en0\n', FIXTURE_HOST + '\n']) as output:
            self.assertEqual(setup.local_address(), FIXTURE_HOST)
            self.assertEqual(output.call_args_list[1].args[0],
                             ['/usr/sbin/ipconfig', 'getifaddr', 'en0'])
        with patch.object(setup.subprocess, 'check_output', return_value='no interface'):
            with self.assertRaises(RuntimeError): setup.local_address()
        with patch.object(setup.subprocess, 'check_output', side_effect=[
                'interface: en0', str(ipaddress.IPv4Address(0))]):
            with self.assertRaises(RuntimeError): setup.local_address()

    def test_missing_listener_requires_setup_and_status_still_loads(self):
        with patch.object(relay, 'PRIVATE', self.hermes), \
             patch.object(companion, '_backend_health', return_value={'available': False}), \
             patch.object(credentials, 'pending_pairing', return_value=None):
            with self.assertRaises(ValueError): relay.listen_address()
            result = companion.status()
        self.assertTrue(result['ok'])
        self.assertFalse(result['relay']['available'])
        self.assertIsNone(result['relay']['endpoint'])
        self.assertEqual(result['relay']['detail'], 'not_configured')

    def test_missing_hermes_does_not_write_files(self):
        with patch.object(setup, 'hermes_executable', return_value=None):
            self.assertEqual(setup.prepare()['error'], 'hermes_not_installed')
        self.assertFalse(self.hermes.exists())

    def test_key_creation_preservation_and_symlink_rejection(self):
        self.hermes.mkdir()
        path = self.hermes / '.env'
        path.write_text('MODEL=fixture\n')
        setup.ensure_api_key()
        first = path.read_bytes()
        self.assertIn(b'MODEL=fixture\n', first)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        setup.ensure_api_key()
        self.assertEqual(path.read_bytes(), first)
        path.unlink()
        target = self.root/'outside'; target.write_text('untouched')
        path.symlink_to(target)
        with self.assertRaises(RuntimeError): setup.ensure_api_key()
        self.assertEqual(target.read_text(), 'untouched')

    def test_first_setup_creates_certificate_without_exposing_secrets(self):
        original_run = setup.run
        calls = []
        def isolated_run(arguments, timeout=60):
            calls.append(arguments)
            if arguments[0] == '/usr/bin/openssl': original_run(arguments, timeout)
        with patch.object(setup, 'hermes_executable', return_value='/fixture/hermes'), \
             patch.object(setup, 'local_address', return_value=FIXTURE_HOST), \
             patch.object(companion, '_backend_health', return_value={'available': False}), \
             patch.object(setup, 'run', side_effect=isolated_run):
            # Only launchctl bootout uses subprocess.run directly; avoid changing services.
            original_subprocess_run = setup.subprocess.run
            def isolated_subprocess(arguments, **kwargs):
                if arguments[0] == 'launchctl': return None
                return original_subprocess_run(arguments, **kwargs)
            with patch.object(setup.subprocess, 'run', side_effect=isolated_subprocess):
                self.assertEqual(setup.prepare(), {'ok': True, 'prepared': True})
        self.assertIn(['/fixture/hermes', 'config', 'set', 'platforms.api_server.host', socket.gethostbyname('localhost')], calls)
        self.assertEqual((self.bridge/'relay.key').stat().st_mode & 0o777, 0o600)
        self.assertTrue((self.bridge/'relay.crt').read_text().startswith('-----BEGIN CERTIFICATE-----'))
        self.assertTrue((self.agents/(setup.LABEL+'.plist')).exists())

    def test_prepare_preserves_certificate_and_healthy_hermes(self):
        self.bridge.mkdir(parents=True)
        (self.bridge/'relay.crt').write_text('fixture-certificate')
        (self.bridge/'relay.key').write_text('fixture-private-key')
        with patch.object(setup, 'hermes_executable', return_value='/fixture/hermes'), \
             patch.object(setup, 'local_address', return_value=FIXTURE_HOST), \
             patch.object(companion, '_backend_health', return_value={'available': True}), \
             patch.object(setup, 'run') as run, patch.object(setup.subprocess, 'run'):
            self.assertTrue(setup.prepare()['prepared'])
            self.assertFalse(any(call.args[0][0] == '/fixture/hermes' for call in run.call_args_list))
        self.assertEqual((self.bridge/'relay.crt').read_text(), 'fixture-certificate')
        self.assertEqual((self.bridge/'relay.key').read_text(), 'fixture-private-key')
        self.assertEqual(credentials.read(self.bridge/'config.json', {})['listen_host'], FIXTURE_HOST)
        with patch.object(relay, 'PRIVATE', self.hermes):
            self.assertEqual(relay.listen_address(), (FIXTURE_HOST, 8643))
            credentials.write(self.bridge/'config.json', {'listen_host': str(ipaddress.IPv4Address(0)), 'listen_port': 8643})
            with self.assertRaises(ValueError): relay.listen_address()


if __name__ == '__main__': unittest.main()
