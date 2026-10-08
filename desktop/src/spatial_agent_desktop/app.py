from __future__ import annotations

import dataclasses
import os
import secrets
import shutil
import sys
from pathlib import Path

from spatial_agent_backend.config import Settings
from spatial_agent_backend.observability import configure_logging

from .bridge import Bridge
from .paths import app_support_dir, web_dir
from .runtime import DaemonRuntime

_CONFIG_TEMPLATE = """\
# Spatial Agent app configuration (KEY=VALUE). Lines starting with # are ignored.
# Uncomment + edit to run real agents from a double-clicked app. Without these,
# the app runs a UI demo with the deterministic "fake" provider.
#
# SPATIAL_AGENT_PROVIDER=opencode
# SPATIAL_AGENT_OPENCODE_URL=http://127.0.0.1:4096
# SPATIAL_AGENT_OPENCODE_PASSWORD=change-me
# SPATIAL_AGENT_HARNESS=opencode
# SPATIAL_AGENT_WORKSPACE_PATH=/absolute/path/to/your/repo
# SPATIAL_AGENT_WORKSPACE_BRANCH=main
# SPATIAL_AGENT_FS_ROOT=/Users/you
"""


def _load_config_env() -> None:
    """Apply ~/Library/Application Support/SpatialAgent/config.env (if present)."""
    base = app_support_dir()
    config = base / "config.env"
    if not config.is_file():
        config.write_text(_CONFIG_TEMPLATE, encoding="utf-8")
        return
    for line in config.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


def build_settings() -> Settings:
    base = app_support_dir()
    settings = Settings.from_environment()
    # Prefer real agents when opencode is installed (the app starts it itself).
    if "SPATIAL_AGENT_PROVIDER" not in os.environ and shutil.which("opencode"):
        settings = dataclasses.replace(settings, provider="opencode")
    if settings.provider == "opencode":
        password = settings.opencode_password or secrets.token_hex(16)
        directory = (
            settings.opencode_directory or settings.workspace_path or str(Path.home())
        )
        settings = dataclasses.replace(
            settings, opencode_password=password, opencode_directory=directory
        )
    # A double-clicked .app has CWD "/", so pin the relative defaults to a
    # writable per-user directory.
    return dataclasses.replace(
        settings,
        database_path=base / "spatial_agent.db",
        workspaces_file=base / "workspaces.json",
        mcp_config_path=base / "mcp.json",
    )


def main() -> int:
    _load_config_env()
    configure_logging()
    settings = build_settings()
    try:
        settings.validate()
    except ValueError as error:
        print(f"[desktop] invalid configuration: {error}", file=sys.stderr)
        return 2
    runtime = DaemonRuntime(settings)
    runtime.start()
    if not runtime.wait_ready():
        print(f"[desktop] daemon failed to start: {runtime.status().get('error')}", file=sys.stderr)
        return 1

    try:
        import webview  # noqa: PLC0415 - optional at import time
    except ImportError:
        print(
            "[desktop] pywebview is not installed. Install with: pip install pywebview",
            file=sys.stderr,
        )
        runtime.stop()
        return 1

    index = (web_dir() / "index.html").as_uri()
    window = webview.create_window(
        "Spatial Agent",
        index,
        js_api=Bridge(runtime),
        width=1240,
        height=820,
        min_size=(900, 640),
    )
    try:
        webview.start()
    finally:
        runtime.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
