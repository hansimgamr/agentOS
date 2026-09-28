import re
import unittest
from relay import ROUTES


class DeleteRouteTests(unittest.TestCase):
    def test_only_single_session_deletion_is_forwarded(self):
        def allowed(path):
            return any(re.fullmatch(pattern, path) for pattern in ROUTES['DELETE'])
        self.assertTrue(allowed('/api/sessions/test-session_1'))
        for path in ('/api/sessions', '/api/sessions/a/messages', '/v1/runs/a', '/api/sessions/a/b'):
            self.assertFalse(allowed(path))
