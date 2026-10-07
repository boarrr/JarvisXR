from __future__ import annotations

from typing import Any

from spatial_agent_backend import __version__
from spatial_agent_backend.config import Settings
from spatial_agent_backend.discovery import ca_fingerprint, local_ipv4_addresses
from spatial_agent_backend.server import _ca_certificate_path, _mdns_name, _update_version


def link_info(server: Any | None, settings: Settings) -> dict[str, Any]:
    """Everything useful for pairing a headset, as a JSON-serializable dict."""
    ips = local_ipv4_addresses()
    port = server.bound_port() if server is not None else settings.port
    tls = settings.tls_certificate_path is not None
    scheme = "wss" if tls else "ws"
    urls = [f"{scheme}://{ip}:{port}/ws" for ip in ips]
    cert = _ca_certificate_path(settings) if tls else None
    return {
        "ips": ips,
        "port": port,
        "scheme": scheme,
        "ws_urls": urls,
        "host_name": _mdns_name(),
        "ca_fingerprint": ca_fingerprint(cert),
        "version": _update_version(settings) or __version__,
        "auth_required": settings.auth_required,
        "discovery_enabled": settings.discovery_enabled,
        "discovery_port": settings.discovery_port,
    }
