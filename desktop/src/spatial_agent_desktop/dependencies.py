from __future__ import annotations

"""Starts and stops the agent dependencies (opencode, whisper) the daemon needs.

This is what lets a double-clicked app "just work": instead of asking the user
to run `opencode serve` in another shell, the app owns the subprocess and tears
it down on quit.
"""

import os
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse


def _host_port(url: str, default_port: int) -> tuple[str, int]:
    parsed = urlparse(url)
    return (parsed.hostname or "127.0.0.1", parsed.port or default_port)


def _reachable(host: str, port: int, timeout: float = 0.3) -> bool:
    with socket.socket() as sock:
        sock.settimeout(timeout)
        return sock.connect_ex((host, port)) == 0


class DependencySupervisor:
    def __init__(self, log_dir: Path) -> None:
        self.log_dir = log_dir
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self._processes: list[subprocess.Popen] = []
        self._children: list[subprocess.Popen] = []

    # -- opencode ------------------------------------------------------------
    def ensure_opencode(self, url: str, password: str, binary: str = "opencode") -> bool:
        """Return True if an opencode server is (now) available."""
        host, port = _host_port(url, 4096)
        if _reachable(host, port):
            return True
        executable = shutil.which(binary)
        if executable is None:
            return False
        log = open(self.log_dir / "opencode.log", "ab")
        env = dict(os.environ)
        if password:
            env["OPENCODE_SERVER_PASSWORD"] = password
        process = subprocess.Popen(
            [executable, "serve", "--hostname", host, "--port", str(port)],
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env,
        )
        self._processes.append(process)
        self._children.append(process)
        for _ in range(60):
            if _reachable(host, port):
                return True
            if process.poll() is not None:
                return False
            time.sleep(0.1)
        return _reachable(host, port)

    # -- whisper -------------------------------------------------------------
    def ensure_whisper(
        self, model_path: str, url: str, binary: str = "whisper-server"
    ) -> bool:
        if not model_path or not Path(model_path).is_file():
            return False
        host, port = _host_port(url, 8081)
        if _reachable(host, port):
            return True
        executable = shutil.which(binary)
        if executable is None:
            return False
        log = open(self.log_dir / "whisper.log", "ab")
        # CPU-only (-ng): the Metal/GPU path hangs or dies while loading the
        # model on this machine, so voice never came up.
        process = subprocess.Popen(
            [executable, "-m", model_path, "-ng", "--host", host, "--port", str(port)],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        self._processes.append(process)
        self._children.append(process)
        return True

    def stop(self) -> None:
        for process in self._children:
            if process.poll() is None:
                process.terminate()
        for process in self._children:
            try:
                process.wait(timeout=5)
            except Exception:  # noqa: BLE001
                process.kill()
        self._children.clear()
        self._processes.clear()
