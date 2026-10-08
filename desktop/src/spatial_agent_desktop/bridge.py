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

    # -- workspaces ----------------------------------------------------------
    def list_workspaces(self) -> list[dict[str, Any]]:
        return self._runtime.list_workspaces()

    def selected_workspace(self) -> dict[str, Any]:
        return self._runtime.selected_workspace()

    def add_workspace(self, path: str, name: str = "") -> dict[str, Any]:
        return self._runtime.add_workspace(str(path), str(name))

    def select_workspace(self, workspace_id: str) -> dict[str, Any]:
        return self._runtime.select_workspace(str(workspace_id))

    def remove_workspace(self, workspace_id: str) -> bool:
        return self._runtime.remove_workspace(str(workspace_id))

    def choose_folder(self) -> str:
        """Open the native folder picker and return the chosen path (or "")."""
        try:
            import webview

            window = webview.windows[0] if webview.windows else None
            if window is None:
                return ""
            result = window.create_file_dialog(webview.FOLDER_DIALOG)
            if result:
                return str(result[0])
        except Exception:  # noqa: BLE001 - picker is a convenience
            return ""
        return ""

    def issue_pairing_code(self) -> str:
        return self._runtime.issue_pairing_code()

    def pairing_payload(self) -> dict[str, Any]:
        return self._runtime.pairing_payload()

    def qr_data_uri(self, text: str) -> str:
        return self._runtime.qr_data_uri(str(text))

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

    # -- missions (fleet) ----------------------------------------------------
    def list_missions(self) -> list[dict[str, Any]]:
        return self._runtime.missions()

    def create_mission(
        self,
        goal: str,
        agent_count: int = 3,
        harness: str = "",
        workspace_id: str = "",
        budget_seconds: int = 0,
        budget_cost: float = 0.0,
        directed: bool = False,
    ) -> dict[str, Any]:
        return self._runtime.create_mission(
            str(goal),
            int(agent_count),
            str(harness),
            str(workspace_id),
            int(budget_seconds),
            float(budget_cost),
            bool(directed),
        )

    def mission_status(self, mission_id: str) -> dict[str, Any]:
        return self._runtime.mission_status(str(mission_id))

    def mission_compare(self, mission_id: str) -> list[dict[str, Any]]:
        return self._runtime.mission_compare(str(mission_id))

    def mission_merge(self, mission_id: str, run_id: str) -> dict[str, Any]:
        return self._runtime.mission_merge(str(mission_id), str(run_id))

    def mission_cancel(self, mission_id: str, agent_id: str = "") -> bool:
        return self._runtime.mission_cancel(str(mission_id), str(agent_id))
