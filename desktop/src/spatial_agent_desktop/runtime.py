from __future__ import annotations

import asyncio
import json
import os
import threading
from pathlib import Path
from typing import Any

from spatial_agent_backend.config import Settings
from spatial_agent_backend.qr import pairing_payload
from spatial_agent_backend.server import SpatialAgentServer
from spatial_agent_backend.workspace import WorkspaceError

from .dependencies import DependencySupervisor
from .linkinfo import link_info
from .paths import app_support_dir


class DaemonRuntime:
    """Runs the daemon on a background asyncio loop and exposes a sync API.

    The desktop app is one process: pywebview owns the main thread, this class
    owns a daemon thread running the server's event loop. It also starts and
    stops the agent dependencies (opencode, whisper) so there is nothing else to
    launch.
    """

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self._server: SpatialAgentServer | None = None
        self._ready = threading.Event()
        self._error = ""
        self._deps = DependencySupervisor(app_support_dir() / "logs")
        self._state_path = app_support_dir() / "state.json"
        self._selected_workspace_id = ""
        self._load_state()

    def _load_state(self) -> None:
        try:
            data = json.loads(self._state_path.read_text(encoding="utf-8"))
            self._selected_workspace_id = str(data.get("workspace_id", ""))
        except (OSError, ValueError):
            self._selected_workspace_id = ""

    def _save_state(self) -> None:
        try:
            self._state_path.write_text(
                json.dumps({"workspace_id": self._selected_workspace_id}, indent=2),
                encoding="utf-8",
            )
        except OSError:
            pass

    def _ensure_dependencies(self) -> None:
        if self.settings.provider == "opencode":
            self._deps.ensure_opencode(
                self.settings.opencode_url, self.settings.opencode_password
            )
        model = os.environ.get("SPATIAL_AGENT_WHISPER_MODEL", "")
        if model:
            self._deps.ensure_whisper(model, self.settings.whisper_server_url)

    # -- lifecycle -----------------------------------------------------------
    def start(self) -> None:
        if self._thread is not None:
            return
        self._ensure_dependencies()
        self._thread = threading.Thread(target=self._run, name="spatial-daemon", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        loop = asyncio.new_event_loop()
        self._loop = loop
        asyncio.set_event_loop(loop)
        try:
            self._server = SpatialAgentServer(self.settings)
            loop.run_until_complete(self._server.start())
            loop.run_until_complete(self._server.wait_until_ready())
        except Exception as error:  # noqa: BLE001 - surfaced to the UI
            self._error = str(error)
            self._ready.set()
            return
        self._ready.set()
        try:
            loop.run_forever()
        finally:
            try:
                loop.run_until_complete(self._server.stop())
            finally:
                loop.close()

    def wait_ready(self, timeout: float = 20.0) -> bool:
        self._ready.wait(timeout)
        return not self._error and self._server is not None

    def stop(self) -> None:
        if self._loop is not None and self._loop.is_running():
            self._loop.call_soon_threadsafe(self._loop.stop)
        if self._thread is not None:
            self._thread.join(timeout=10)
        self._deps.stop()

    def _submit(self, coro: Any) -> Any:
        assert self._loop is not None, "runtime is not started"
        return asyncio.run_coroutine_threadsafe(coro, self._loop)

    # -- status / control ----------------------------------------------------
    def status(self) -> dict[str, Any]:
        server = self._server
        running = self._loop is not None and self._loop.is_running()
        return {
            "running": running and server is not None,
            "paused": server.coordinator.is_paused() if server is not None else False,
            "provider": server.provider.name if server is not None else "",
            "harness": self.settings.harness,
            "port": server.bound_port() if server is not None else self.settings.port,
            "auth_required": self.settings.auth_required,
            "error": self._error,
        }

    def set_paused(self, value: bool) -> dict[str, Any]:
        if self._server is not None:
            self._server.coordinator.set_paused(bool(value))
        return self.status()

    def link_info(self) -> dict[str, Any]:
        return link_info(self._server, self.settings)

    # -- workspaces ----------------------------------------------------------
    def list_workspaces(self) -> list[dict[str, Any]]:
        server = self._server
        if server is None:
            return []
        return [
            {
                "id": workspace.id,
                "name": workspace.name,
                "path": str(workspace.path),
                "base_branch": workspace.base_branch,
            }
            for workspace in server.workspaces.list_workspaces()
        ]

    def selected_workspace(self) -> dict[str, Any]:
        server = self._server
        if server is None:
            return {}
        workspace = None
        if self._selected_workspace_id:
            workspace = server.workspaces.get(self._selected_workspace_id)
        if workspace is None:
            registered = server.workspaces.list_workspaces()
            workspace = registered[0] if registered else None
        if workspace is None:
            return {}
        if workspace.id != self._selected_workspace_id:
            self._apply_workspace(workspace)
        return {"id": workspace.id, "name": workspace.name, "path": str(workspace.path)}

    def add_workspace(self, path: str, name: str = "") -> dict[str, Any]:
        server = self._server
        if server is None or not path.strip():
            return {}
        candidate = Path(path).expanduser()
        if not candidate.is_dir():
            return {"error": "Not a directory: %s" % candidate}
        try:
            workspace = server.workspaces.register(name.strip() or candidate.name, candidate)
        except WorkspaceError as error:
            return {"error": str(error)}
        self._apply_workspace(workspace)
        return {"id": workspace.id, "name": workspace.name, "path": str(workspace.path)}

    def select_workspace(self, workspace_id: str) -> dict[str, Any]:
        server = self._server
        if server is None:
            return {}
        workspace = server.workspaces.get(workspace_id)
        if workspace is None:
            return {}
        self._apply_workspace(workspace)
        return {"id": workspace.id, "name": workspace.name, "path": str(workspace.path)}

    def remove_workspace(self, workspace_id: str) -> bool:
        server = self._server
        if server is None:
            return False
        removed = server.workspaces.unregister(workspace_id)
        if removed and self._selected_workspace_id == workspace_id:
            self._selected_workspace_id = ""
            self._save_state()
        return bool(removed)

    def _apply_workspace(self, workspace) -> None:
        self._selected_workspace_id = workspace.id
        self._save_state()
        os.environ["SPATIAL_AGENT_WORKSPACE_PATH"] = str(workspace.path)
        if self._server is not None:
            self._server.coordinator.opencode_directory = str(workspace.path)

    # -- pairing -------------------------------------------------------------
    def issue_pairing_code(self) -> str:
        if self._server is None:
            return ""
        return self._server.pairing.issue_code()

    def pairing_payload(self) -> dict[str, Any]:
        """A fresh pairing code plus the join payload + QR a headset can scan."""
        link = self.link_info()
        urls = link.get("ws_urls") or [""]
        url = str(urls[0]) if urls else ""
        code = self.issue_pairing_code()
        payload = pairing_payload(url, code, str(link.get("ca_fingerprint", "")))
        return {"code": code, "url": url, "payload": payload, "qr": self.qr_data_uri(payload)}

    def qr_data_uri(self, text: str) -> str:
        if not text:
            return ""
        try:
            import base64
            import io

            import segno

            buffer = io.BytesIO()
            segno.make(text, micro=False).save(buffer, kind="png", scale=4, border=2)
            return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode("ascii")
        except Exception:  # noqa: BLE001 - QR is a nicety
            return ""

    def devices(self) -> list[dict[str, Any]]:
        if self._server is None:
            return []
        return [device.to_wire() for device in self._server.pairing.list_devices()]

    def revoke_device(self, device_id: str) -> bool:
        if self._server is None:
            return False
        return self._server.pairing.revoke(device_id)

    # -- agents --------------------------------------------------------------
    def threads(self) -> list[dict[str, Any]]:
        server = self._server
        if server is None:
            return []
        threads = self._submit(server.threads.list_threads()).result(timeout=5)
        return [
            {
                "id": thread.id,
                "title": thread.title,
                "status": thread.status,
                "mission_id": str(thread.metadata.get("mission_id", "")),
                "messages": [message.to_wire() for message in thread.messages],
            }
            for thread in threads
        ]

    def create_thread(self, title: str, workspace_id: str = "") -> dict[str, Any]:
        server = self._server
        if server is None:
            return {}
        selected = workspace_id or str(self.selected_workspace().get("id", ""))

        async def _create() -> dict[str, Any]:
            thread = await server.threads.create_thread(title or "New agent")
            if selected:
                metadata = dict(thread.metadata)
                metadata["workspace_id"] = selected
                thread.metadata = metadata
                await server.threads.persist_thread(thread.id)
            return {"id": thread.id, "title": thread.title}

        return self._submit(_create()).result(timeout=5)

    def rename_thread(self, thread_id: str, title: str) -> dict[str, Any]:
        server = self._server
        if server is None:
            return {}
        thread = self._submit(server.threads.rename_thread(thread_id, title)).result(timeout=5)
        return {"id": thread.id, "title": thread.title}

    def archive_thread(self, thread_id: str) -> bool:
        server = self._server
        if server is None:
            return False
        return bool(self._submit(server.threads.archive_thread(thread_id)).result(timeout=5))

    def send_message(self, thread_id: str, content: str) -> bool:
        server = self._server
        if server is None:
            return False

        async def _noop(event_type: str, tid: str, payload: dict[str, Any]) -> None:
            return None

        return bool(
            self._submit(
                server.coordinator.submit_message(
                    session_id="desktop-app",
                    thread_id=thread_id,
                    content=content,
                    emit=_noop,
                )
            ).result(timeout=10)
        )

    def cancel_run(self, thread_id: str) -> bool:
        server = self._server
        if server is None:
            return False
        return bool(
            self._submit(
                server.coordinator.cancel(session_id="desktop-app", thread_id=thread_id)
            ).result(timeout=5)
        )

    # -- missions (fleet) ----------------------------------------------------
    async def _noop_emit(self, event_type: str, thread_id: str, payload: dict[str, Any]) -> None:
        return None

    def missions(self) -> list[dict[str, Any]]:
        server = self._server
        if server is None:
            return []
        return server.missions.list_missions()

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
        server = self._server
        if server is None or not goal.strip():
            return {}

        async def _create() -> dict[str, Any]:
            wsid = workspace_id or str(self.selected_workspace().get("id", ""))
            if not wsid and server.workspaces is not None:
                registered = server.workspaces.list_workspaces()
                if registered:
                    wsid = registered[0].id
            mission = await server.missions.create(
                session_id="desktop-app",
                workspace_id=wsid,
                goal=goal,
                agent_count=agent_count,
                harness=harness or self.settings.harness,
                budget_seconds=int(budget_seconds),
                budget_cost=float(budget_cost),
                directed=bool(directed),
            )
            await server.missions.spawn(mission["id"], self._noop_emit)
            return await server.missions.status(mission["id"])

        return self._submit(_create()).result(timeout=15)

    def mission_status(self, mission_id: str) -> dict[str, Any]:
        server = self._server
        if server is None:
            return {}
        return self._submit(server.missions.status(mission_id)).result(timeout=5)

    def mission_compare(self, mission_id: str) -> list[dict[str, Any]]:
        server = self._server
        if server is None:
            return []
        return self._submit(server.missions.compare(mission_id)).result(timeout=10)

    def mission_merge(self, mission_id: str, run_id: str) -> dict[str, Any]:
        server = self._server
        if server is None:
            return {}
        return self._submit(server.missions.merge(mission_id, run_id)).result(timeout=30)

    def mission_cancel(self, mission_id: str, agent_id: str = "") -> bool:
        server = self._server
        if server is None:
            return False
        return bool(
            self._submit(server.missions.cancel(mission_id, agent_id)).result(timeout=5)
        )
