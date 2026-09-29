import io
import json
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import companion
import credentials


class TemporaryCredentials(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.patches = [patch.object(credentials, name, root / name.lower())
                        for name in ("DEVICES", "PAIRING", "LOCK")]
        self.patches.append(patch.object(credentials, "PRIVATE", root))
        self.patches.append(patch.object(companion, "_endpoint", return_value="https://fixture-mac.local:8643"))
        for change in self.patches:
            change.start()

    def tearDown(self):
        for change in reversed(self.patches):
            change.stop()
        self.directory.cleanup()


class TicketLifecycle(TemporaryCredentials):
    def test_expiry_cancellation_stale_window_and_replay(self):
        first = credentials.create_pairing_ticket()
        self.assertTrue(credentials.cancel_pairing(first["ticket_id"]))
        self.assertIsNone(credentials.claim_pairing(first["code"], "Phone"))
        second = credentials.create_pairing_ticket()
        third = credentials.create_pairing_ticket()
        self.assertFalse(credentials.cancel_pairing(second["ticket_id"]))
        self.assertEqual(credentials.pending_pairing()["ticket_id"], third["ticket_id"])
        with patch.object(credentials.time, "time", return_value=third["expires_at"]):
            self.assertIsNone(credentials.claim_pairing(third["code"], "Phone"))
            self.assertIsNone(credentials.pending_pairing())

        ticket = credentials.create_pairing_ticket()
        device = credentials.claim_pairing(ticket["code"], "Phone")
        self.assertIsNotNone(device)
        self.assertIsNone(credentials.claim_pairing(ticket["code"], "Other"))

    def test_claim_is_serialized_and_exactly_one_thread_wins(self):
        ticket = credentials.create_pairing_ticket()
        barrier = threading.Barrier(8)
        results = []
        lock = threading.Lock()

        def claim(index):
            barrier.wait()
            result = credentials.claim_pairing(ticket["code"], f"Phone {index}")
            with lock:
                results.append(result)

        threads = [threading.Thread(target=claim, args=(index,)) for index in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=5)
        self.assertTrue(all(not thread.is_alive() for thread in threads))
        winners = [result for result in results if result]
        self.assertEqual(len(winners), 1)
        self.assertEqual(len(credentials.list_devices()), 1)

    def test_parallel_rotation_tokens_and_revoke(self):
        ticket = credentials.create_pairing_ticket()
        device = credentials.claim_pairing(ticket["code"], "Phone")
        barrier = threading.Barrier(2)
        rotated = []

        def rotate():
            barrier.wait()
            rotated.append(credentials.rotate(device["device_id"]))

        threads = [threading.Thread(target=rotate) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=5)
        self.assertEqual(len(rotated), 2)
        self.assertTrue(all(credentials.authenticate(item["token"]) == device["device_id"] for item in rotated))
        self.assertTrue(credentials.revoke(device["device_id"]))
        self.assertTrue(all(credentials.authenticate(item["token"]) is None for item in rotated))

    def test_input_validation(self):
        self.assertIsNone(credentials.claim_pairing([], "Phone"))
        self.assertIsNone(credentials.claim_pairing("code", "\n\t"))
        self.assertIsNone(credentials.claim_pairing("x" * 129, "Phone"))
        self.assertFalse(credentials.cancel_pairing("x"))
        self.assertFalse(credentials.revoke("../../bad"))
        self.assertIsNone(credentials.rotate("../../bad"))

    def test_companion_pairing_url_contains_v2_pinned_endpoint_but_no_duplicate_code(self):
        fingerprint = "a" * 64
        with patch.object(companion, "_certificate_fingerprint", return_value=fingerprint), \
             patch.object(companion, "_relay_health", return_value={"available": True, "detail": "ready"}):
            result = companion.dispatch({"action": "create_pairing"})
        self.assertNotIn("code", result)
        self.assertEqual(result["fingerprint"], fingerprint)
        query = parse_qs(urlsplit(result["qr_url"]).query)
        self.assertEqual(query["v"], ["2"])
        self.assertEqual(query["endpoint"], [result["endpoint"]])
        self.assertEqual(query["fingerprint"], [fingerprint])
        code = query["code"][0]
        self.assertRegex(code, r"^[A-Za-z0-9_-]{43}$")
        issued = credentials.claim_pairing(code, "agentOS iPhone")
        self.assertIsNotNone(issued)
        self.assertIsNone(credentials.claim_pairing(code, "Replay"))

    def test_unavailable_relay_does_not_issue_a_ticket(self):
        with patch.object(companion, "_certificate_fingerprint", return_value="c" * 64), \
             patch.object(companion, "_relay_health", return_value={"available": False, "detail": "unavailable"}):
            response = companion.dispatch({"action": "create_pairing"})
        self.assertEqual(response, {"ok": False, "error": "relay_unavailable"})
        self.assertIsNone(credentials.pending_pairing())

    def test_status_is_read_only_and_never_includes_credentials(self):
        with patch.object(companion, "_certificate_fingerprint", return_value="b" * 64), \
             patch.object(companion, "_relay_health", return_value={"available": True, "detail": "ready"}), \
             patch.object(companion, "_backend_health", return_value={"available": True, "detail": "ready"}), \
             patch.object(credentials, "create_pairing_ticket", side_effect=AssertionError):
            response = companion.dispatch({"action": "status"})
        self.assertTrue(response["ok"])
        serialized = json.dumps(response)
        self.assertNotIn("token", serialized)
        self.assertNotIn("code", serialized)
        self.assertIsNone(response["pending_pairing"])

    def test_invalid_json_and_request_size_are_sanitized(self):
        class BinaryStdin:
            def __init__(self, value):
                self.buffer = io.BytesIO(value)

        for payload, expected in ((b"{broken", "invalid_json"),
                                  (b" " * (companion.MAX_REQUEST + 1), "request_too_large")):
            output = io.StringIO()
            with patch.object(companion.sys, "stdin", BinaryStdin(payload)), \
                 patch.object(companion.sys, "stdout", output):
                companion.main()
            self.assertEqual(json.loads(output.getvalue()), {"ok": False, "error": expected})

    def test_action_validation_does_not_echo_input(self):
        response = companion.dispatch({"action": "revoke", "device_id": "secret-value"})
        self.assertEqual(response, {"ok": False, "error": "invalid_request"})
        self.assertNotIn("secret-value", json.dumps(response))


if __name__ == "__main__":
    unittest.main()
