from __future__ import annotations

import sys

from .auth import PairingManager
from .config import Settings
from .storage import SQLiteStore


def main() -> None:
    settings = Settings.from_environment()
    store = SQLiteStore(settings.database_path)
    store.initialize()
    pairing = PairingManager(store, ttl_seconds=settings.pairing_code_ttl_seconds)
    code = pairing.issue_code()
    if "--token" in sys.argv[1:]:
        # Bootstrap path: mint a device token without in-headset input. Used by
        # scripts/daemon_config.sh for a USB-seeded development pairing.
        result = pairing.redeem(code, "usb-bootstrap")
        if result is None:
            raise SystemExit("Could not issue a bootstrap token")
        token, _device = result
        print(token)
        return
    print(f"Pairing code: {code}")
    print(
        f"Valid for {int(settings.pairing_code_ttl_seconds)} seconds. "
        "Enter it on the headset under Daemon settings, then approve once."
    )


if __name__ == "__main__":
    main()
