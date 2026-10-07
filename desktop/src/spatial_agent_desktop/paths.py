from __future__ import annotations

from pathlib import Path


def app_support_dir() -> Path:
    """Writable per-user directory for the app's database, config and logs."""
    base = Path.home() / "Library" / "Application Support" / "SpatialAgent"
    base.mkdir(parents=True, exist_ok=True)
    return base


def web_dir() -> Path:
    return Path(__file__).parent / "web"
