from __future__ import annotations

from typing import Any

from .runtime import DaemonRuntime


class Bridge:
    """pywebview JS API: the office UI calls these; they delegate to the daemon.

    Every method returns JSON-serializable data. pywebview invokes them on the
    GUI thread, so they must be quick and thread-safe (the runtime marshals work
    onto the daemon loop).
    """

    def __init__(self, runtime: DaemonRuntime) -> None:
        self._runtime = runtime

    def get_status(self) -> dict[str, Any]:
        return self._runtime.status()

    def set_paused(self, value: bool) -> dict[str, Any]:
        return self._runtime.set_paused(bool(value))

    def get_link_info(self) -> dict[str, Any]:
        return self._runtime.link_info()

    def issue_pairing_code(self) -> str:
        return self._runtime.issue_pairing_code()

    def list_devices(self) -> list[dict[str, Any]]:
        return self._runtime.devices()

    def revoke_device(self, device_id: str) -> bool:
        return self._runtime.revoke_device(str(device_id))

    def list_threads(self) -> list[dict[str, Any]]:
        return self._runtime.threads()

    def create_thread(self, title: str, workspace_id: str = "") -> dict[str, Any]:
        return self._runtime.create_thread(str(title), str(workspace_id))

    def rename_thread(self, thread_id: str, title: str) -> dict[str, Any]:
        return self._runtime.rename_thread(str(thread_id), str(title))

    def archive_thread(self, thread_id: str) -> bool:
        return self._runtime.archive_thread(str(thread_id))

    def send_message(self, thread_id: str, content: str) -> bool:
        return self._runtime.send_message(str(thread_id), str(content))

    def cancel_run(self, thread_id: str) -> bool:
        return self._runtime.cancel_run(str(thread_id))
