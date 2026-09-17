from __future__ import annotations

from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory
import unittest

from spatial_agent_backend.auth import PairingManager, hash_secret
from spatial_agent_backend.storage import SQLiteStore


class PairingManagerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.database_path = Path(self.temporary_directory.name) / "auth.db"
        self.store = SQLiteStore(self.database_path)
        self.store.initialize()
        self.pairing = PairingManager(self.store, ttl_seconds=60.0)

    def test_pairing_code_redeems_once_and_issues_verifiable_token(self) -> None:
        code = self.pairing.issue_code()
        self.assertEqual(len(code), 8)
        self.assertIsNone(self.pairing.redeem("ZZZZZZZZ", "Wrong"))

        redeemed = self.pairing.redeem(code.lower(), "Quest 3S")
        self.assertIsNotNone(redeemed)
        token, device = redeemed
        self.assertTrue(token)
        self.assertEqual(device.name, "Quest 3S")

        self.assertIsNone(self.pairing.redeem(code, "Second use"))
        verified = self.pairing.verify(token)
        self.assertIsNotNone(verified)
        self.assertEqual(verified.id, device.id)
        self.assertIsNone(self.pairing.verify(token + "x"))
        self.assertIsNone(self.pairing.verify(""))

    def test_expired_code_is_rejected(self) -> None:
        self.store.insert_pairing_code(hash_secret("ABCD2345"), ttl_seconds=-1.0)
        self.assertIsNone(self.pairing.redeem("ABCD2345", "Late device"))

    def test_only_hashes_are_persisted(self) -> None:
        code = self.pairing.issue_code()
        token, device = self.pairing.redeem(code, "Quest")
        with sqlite3.connect(self.database_path) as connection:
            code_rows = connection.execute("SELECT code_hash FROM pairing_codes").fetchall()
            token_rows = connection.execute("SELECT token_hash FROM devices").fetchall()
        flattened = [value for row in code_rows + token_rows for value in row]
        self.assertNotIn(code, flattened)
        self.assertNotIn(token, flattened)
        self.assertIn(hash_secret(token), flattened)

    def test_revoked_device_cannot_verify(self) -> None:
        code = self.pairing.issue_code()
        token, device = self.pairing.redeem(code, "Quest")
        self.assertTrue(self.pairing.revoke(device.id))
        self.assertIsNone(self.pairing.verify(token))
        self.assertFalse(self.pairing.revoke(device.id))

    def test_issued_codes_are_unique(self) -> None:
        codes = {self.pairing.issue_code() for _ in range(16)}
        self.assertEqual(len(codes), 16)


if __name__ == "__main__":
    unittest.main()
