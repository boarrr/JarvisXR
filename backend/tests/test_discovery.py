from __future__ import annotations

import unittest
from pathlib import Path

from spatial_agent_backend import discovery


class DiscoveryBeaconTests(unittest.TestCase):
    def test_build_beacon_has_addresses_and_app_id(self) -> None:
        beacon = discovery.build_beacon(ws_port=8787)
        self.assertEqual(beacon["app"], discovery.APP_ID)
        self.assertEqual(beacon["ws_port"], 8787)
        self.assertEqual(beacon["protocol"], discovery.PROTOCOL_VERSION)
        self.assertIsInstance(beacon["ips"], list)

    def test_encode_decode_round_trip(self) -> None:
        beacon = discovery.build_beacon(ws_port=9123, host_name="Midnight-2.local")
        decoded = discovery.decode_beacon(discovery.encode_beacon(beacon))
        self.assertIsNotNone(decoded)
        assert decoded is not None
        self.assertEqual(decoded["ws_port"], 9123)
        self.assertEqual(decoded["host"], "Midnight-2.local")

    def test_decode_rejects_foreign_payloads(self) -> None:
        self.assertIsNone(discovery.decode_beacon(b"not json"))
        self.assertIsNone(discovery.decode_beacon(b'{"app": "someone-else"}'))

    def test_websocket_urls_prefers_ips_then_host(self) -> None:
        payload = {
            "app": discovery.APP_ID,
            "ws_port": 8787,
            "ips": ["192.168.0.202", "10.0.0.5"],
            "host": "Midnight-2.local",
        }
        urls = discovery.beacon_websocket_urls(payload)
        self.assertEqual(
            urls,
            [
                "wss://192.168.0.202:8787/ws",
                "wss://10.0.0.5:8787/ws",
                "wss://Midnight-2.local:8787/ws",
            ],
        )

    def test_ca_fingerprint_from_certificate(self) -> None:
        cert = Path(__file__).resolve().parents[2] / "certs" / "ca.crt"
        if not cert.is_file():
            self.skipTest("dev CA not generated yet")
        fingerprint = discovery.ca_fingerprint(cert)
        self.assertEqual(len(fingerprint), 64)
        self.assertTrue(all(character in "0123456789abcdef" for character in fingerprint))

    def test_ca_fingerprint_missing_file_is_empty(self) -> None:
        self.assertEqual(discovery.ca_fingerprint(Path("/nonexistent/ca.crt")), "")


if __name__ == "__main__":
    unittest.main()
