from __future__ import annotations

import dataclasses
import sys

from spatial_agent_backend.config import Settings

from .bridge import Bridge
from .paths import app_support_dir, web_dir
from .runtime import DaemonRuntime


def build_settings() -> Settings:
    base = app_support_dir()
    settings = Settings.from_environment()
    # A double-clicked .app has CWD "/", so pin the relative defaults to a
    # writable per-user directory.
    return dataclasses.replace(
        settings,
        database_path=base / "spatial_agent.db",
        workspaces_file=base / "workspaces.json",
        mcp_config_path=base / "mcp.json",
    )


def main() -> int:
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
