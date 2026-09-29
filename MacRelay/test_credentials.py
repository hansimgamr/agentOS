import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import credentials
from rotate_master import replace_key


class CredentialLifecycle(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.patches = [patch.object(credentials, name, root / name.lower())
                        for name in ("DEVICES", "PAIRING", "LOCK")]
        self.patches.append(patch.object(credentials, "PRIVATE", root))
        for change in self.patches:
            change.start()

    def tearDown(self):
        for change in reversed(self.patches):
            change.stop()
        self.directory.cleanup()

    def test_pair_rotate_and_revoke(self):
        code = credentials.create_pairing()
        self.assertIsNone(credentials.claim_pairing("wrong", "Phone"))
        first = credentials.claim_pairing(code, "Phone")
        self.assertIsNotNone(first)
        self.assertIsNone(credentials.claim_pairing(code, "Other"))
        self.assertEqual(credentials.authenticate(first["token"]), first["device_id"])
        self.assertNotIn(first["token"], credentials.DEVICES.read_text())
        second = credentials.rotate(first["device_id"])
        self.assertEqual(credentials.authenticate(second["token"]), first["device_id"])
        self.assertEqual(credentials.authenticate(first["token"]), first["device_id"])
        with patch.object(credentials.time, "time", return_value=credentials.read(credentials.DEVICES, {})["devices"][first["device_id"]]["previous_until"] + 1):
            self.assertIsNone(credentials.authenticate(first["token"]))
        self.assertTrue(credentials.revoke(first["device_id"]))
        self.assertIsNone(credentials.authenticate(second["token"]))
        self.assertEqual(credentials.DEVICES.stat().st_mode & 0o777, 0o600)

    def test_certificate_acceptance_survives_rotation_and_legacy_is_unknown(self):
        code = credentials.create_pairing()
        fingerprint = "a" * 64
        with patch.object(credentials.time, "time", return_value=1800000000):
            # The ticket must be current at this controlled server time.
            code = credentials.create_pairing()
            result = credentials.claim_pairing(code, "Phone", fingerprint)
        self.assertEqual(result["certificate_accepted_at"], 1800000000)
        credentials.rotate(result["device_id"])
        device = credentials.list_devices()[0]
        self.assertEqual(device["certificate_accepted_at"], 1800000000)
        self.assertEqual(device["certificate_fingerprint"], fingerprint)
        with credentials.locked():
            credentials._issue(credentials.read(credentials.DEVICES, {}), "Legacy")
        self.assertIsNone(credentials.list_devices()[1]["certificate_accepted_at"])

    def test_legacy_migration_only_once(self):
        self.assertIsNotNone(credentials.migrate_legacy("First iPhone"))
        self.assertIsNone(credentials.migrate_legacy("Second iPhone"))

    def test_master_key_replacement_preserves_other_configuration(self):
        old, updated = replace_key("MODEL=one\nAPI_SERVER_KEY='old'\nOTHER=two\n", "new")
        self.assertEqual(old, "old")
        self.assertEqual(updated, "MODEL=one\nAPI_SERVER_KEY=new\nOTHER=two\n")


if __name__ == "__main__":
    unittest.main()
