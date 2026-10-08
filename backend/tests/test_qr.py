from __future__ import annotations

import io
import unittest
from urllib.parse import parse_qs, urlparse

import segno

from spatial_agent_backend.qr import decode_qr, pairing_payload


class QrTests(unittest.TestCase):
    def test_pairing_payload_round_trips_fields(self) -> None:
        payload = pairing_payload(
            "wss://192.168.0.17:8787/ws", "CODE123", "abc123fingerprint"
        )
        self.assertTrue(payload.startswith("spatialagent://pair?"))
        query = parse_qs(urlparse(payload).query)
        self.assertEqual(query["url"], ["wss://192.168.0.17:8787/ws"])
        self.assertEqual(query["code"], ["CODE123"])
        self.assertEqual(query["ca"], ["abc123fingerprint"])

    def test_decode_qr_round_trips(self) -> None:
        payload = pairing_payload("wss://10.0.0.5:8787/ws", "HELLO99", "deadbeef")
        buffer = io.BytesIO()
        segno.make(payload, micro=False).save(buffer, kind="png", scale=4, border=2)
        decoded = decode_qr(buffer.getvalue())
        self.assertEqual(decoded, payload)

    def test_decode_qr_returns_empty_for_blank(self) -> None:
        # A 1x1 white PNG has no QR.
        blank = io.BytesIO()
        segno.make("x", micro=False).save(blank, kind="png", scale=1, border=0)
        self.assertEqual(decode_qr(b""), "")


if __name__ == "__main__":
    unittest.main()
