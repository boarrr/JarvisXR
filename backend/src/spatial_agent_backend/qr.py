from __future__ import annotations

"""QR pairing helpers.

The daemon shows a QR encoding a join payload; a headset scans it with its
passthrough camera and completes pairing without typing a code. Decoding happens
here (daemon-side) so the headset only has to capture a frame.
"""

from urllib.parse import urlencode

PAIR_URI_SCHEME = "spatialagent"


def pairing_payload(url: str, code: str, ca_fingerprint: str = "") -> str:
    query = {"url": url, "code": code}
    if ca_fingerprint:
        query["ca"] = ca_fingerprint
    return "{0}://pair?{1}".format(PAIR_URI_SCHEME, urlencode(query))


def decode_qr(image_bytes: bytes) -> str:
    """Decode the first QR code in a PNG/JPEG image; "" when none/unsupported."""
    if not image_bytes:
        return ""
    try:
        import cv2  # type: ignore
        import numpy as np  # type: ignore
    except ImportError:
        return ""
    array = np.frombuffer(image_bytes, dtype=np.uint8)
    image = cv2.imdecode(array, cv2.IMREAD_GRAYSCALE)
    if image is None:
        return ""
    try:
        detector = cv2.QRCodeDetector()
        data, _points, _ = detector.detectAndDecode(image)
        return data or ""
    except Exception:  # noqa: BLE001 - cv2 raises various types
        return ""
