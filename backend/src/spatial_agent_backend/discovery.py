from __future__ import annotations

"""LAN discovery for the Spatial Agent daemon.

The daemon announces itself on the local network over UDP so a headset on the
same Wi-Fi can find it without any hand-pushed config. The beacon carries only
addresses and the CA fingerprint (no secrets); trust still comes from TLS plus
the pairing code.
"""

from dataclasses import dataclass
from contextlib import contextmanager
from pathlib import Path
import hashlib
import json
import socket
import ssl
import threading
import time
from typing import Any


@contextmanager
def suppress_oserror():
    try:
        yield
    except OSError:
        pass

APP_ID = "spatial-agent"
PROTOCOL_VERSION = 2
DEFAULT_DISCOVERY_PORT = 8789
BEACON_INTERVAL_SECONDS = 1.0
DISCOVER_MAGIC = b"spatial-agent-discover"


def local_ipv4_addresses() -> list[str]:
    addresses: set[str] = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addresses.add(info[4][0])
    except OSError:
        pass
    # The address used to reach the outside is the one a peer on the LAN sees.
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("8.8.8.8", 80))
            addresses.add(probe.getsockname()[0])
        finally:
            probe.close()
    except OSError:
        pass
    return sorted(address for address in addresses if not address.startswith("127."))


def ca_fingerprint(cert_path: Path | None) -> str:
    if cert_path is None or not cert_path.is_file():
        return ""
    try:
        pem = cert_path.read_text(encoding="utf-8")
        der = ssl.PEM_cert_to_DER_cert(pem)
    except (OSError, ValueError):
        return ""
    return hashlib.sha256(der).hexdigest()


def build_beacon(
    *,
    ws_port: int,
    discovery_port: int = DEFAULT_DISCOVERY_PORT,
    host_name: str = "",
    cert_path: Path | None = None,
    version: str = "",
) -> dict[str, Any]:
    return {
        "app": APP_ID,
        "protocol": PROTOCOL_VERSION,
        "ws_port": int(ws_port),
        "discovery_port": int(discovery_port),
        "host": host_name,
        "ips": local_ipv4_addresses(),
        "ca_fingerprint": ca_fingerprint(cert_path),
        "version": version,
    }


def encode_beacon(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def decode_beacon(data: bytes) -> dict[str, Any] | None:
    try:
        parsed = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(parsed, dict) or parsed.get("app") != APP_ID:
        return None
    return parsed


def beacon_websocket_urls(payload: dict[str, Any]) -> list[str]:
    port = int(payload.get("ws_port", 0) or 0)
    if port <= 0:
        return []
    urls: list[str] = []
    for ip in payload.get("ips", []):
        url = "wss://%s:%d/ws" % (ip, port)
        if url not in urls:
            urls.append(url)
    host = str(payload.get("host", "")).strip()
    if host:
        urls.append("wss://%s:%d/ws" % (host, port))
    return urls


def _broadcast_targets(addresses: list[str], port: int) -> list[tuple[str, int]]:
    targets: set[str] = {"255.255.255.255"}
    for address in addresses:
        parts = address.split(".")
        if len(parts) == 4:
            targets.add(".".join(parts[:3] + ["255"]))
    return [(target, port) for target in sorted(targets)]


@dataclass(slots=True)
class DiscoveryAdvertiser:
    """Periodically broadcast a beacon and answer direct discover probes."""

    payload: dict[str, Any]
    port: int = DEFAULT_DISCOVERY_PORT
    interval: float = BEACON_INTERVAL_SECONDS
    enabled: bool = True

    def start(self) -> None:
        if not self.enabled:
            return
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="discovery", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if not self.enabled:
            return
        self._stop.set()
        thread = getattr(self, "_thread", None)
        if thread is not None:
            thread.join(timeout=2.0)

    _stop: threading.Event | None = None
    _thread: threading.Thread | None = None

    def _run(self) -> None:
        data = encode_beacon(self.payload)
        targets = _broadcast_targets(list(self.payload.get("ips", [])), self.port)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if hasattr(socket, "SO_REUSEPORT"):
                with suppress_oserror():
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.bind(("", self.port))
            sock.settimeout(0.5)
            last_broadcast = 0.0
            while not (self._stop is not None and self._stop.is_set()):
                now = time.monotonic()
                if now - last_broadcast >= self.interval:
                    for target in targets:
                        try:
                            sock.sendto(data, target)
                        except OSError:
                            continue
                    last_broadcast = now
                try:
                    message, address = sock.recvfrom(2048)
                except socket.timeout:
                    continue
                except OSError:
                    continue
                if message.strip() == DISCOVER_MAGIC:
                    try:
                        sock.sendto(data, address)
                    except OSError:
                        continue
        finally:
            sock.close()
