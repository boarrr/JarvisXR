from __future__ import annotations

import hashlib
import secrets

from .domain import Device
from .storage import SQLiteStore


PAIRING_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
PAIRING_CODE_LENGTH = 8
DEFAULT_PAIRING_TTL_SECONDS = 600.0
DEVICE_TOKEN_BYTES = 32
MAX_OUTSTANDING_CODES = 200


def hash_secret(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def normalize_pairing_code(code: str) -> str:
    return code.strip().upper().replace(" ", "").replace("-", "")


class PairingManager:
    """Short-lived pairing codes exchanged for durable per-device tokens.

    Only hashes of codes and tokens are persisted. Codes are single use and
    time limited, and are issued through the same daemon process that validates
    them so a stale database cannot grant access on its own.
    """

    def __init__(self, store: SQLiteStore, *, ttl_seconds: float = DEFAULT_PAIRING_TTL_SECONDS) -> None:
        self.store = store
        self.ttl_seconds = ttl_seconds

    def issue_code(self) -> str:
        self.store.purge_pairing_codes()
        for _ in range(16):
            code = "".join(secrets.choice(PAIRING_CODE_ALPHABET) for _ in range(PAIRING_CODE_LENGTH))
            if self.store.insert_pairing_code(hash_secret(code), self.ttl_seconds):
                return code
        raise RuntimeError("Could not allocate a pairing code; too many outstanding codes")

    def redeem(self, code: str, device_name: str) -> tuple[str, Device] | None:
        normalized = normalize_pairing_code(code)
        if not normalized:
            return None
        if not self.store.consume_pairing_code(hash_secret(normalized)):
            return None
        token = secrets.token_urlsafe(DEVICE_TOKEN_BYTES)
        device = self.store.create_device(
            f"dev_{secrets.token_hex(8)}",
            (device_name.strip() or "Unnamed device")[:80],
            hash_secret(token),
        )
        return token, device

    def verify(self, token: str) -> Device | None:
        if not token or len(token) > 256:
            return None
        device = self.store.find_device_by_token_hash(hash_secret(token))
        if device is not None:
            self.store.touch_device(device.id)
        return device

    def revoke(self, device_id: str) -> bool:
        return self.store.revoke_device(device_id)

    def list_devices(self) -> list[Device]:
        return self.store.list_devices()
