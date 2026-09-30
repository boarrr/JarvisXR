from __future__ import annotations

import asyncio
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
from uuid import uuid4

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from spatial_agent_backend.config import Settings
from spatial_agent_backend.server import SpatialAgentServer
from spatial_agent_backend.thread_service import ThreadNotFoundError


def command(
    command_type: str,
    *,
    session_id: str = "",
    thread_id: str = "",
    payload: dict | None = None,
) -> str:
    return json.dumps(
        {
            "v": 2,
            "type": command_type,
            "event_id": f"cmd_{uuid4().hex[:12]}",
            "session_id": session_id,
            "thread_id": thread_id,
            "timestamp": "2026-09-16T12:00:00Z",
            "payload": payload or {},
        }
    )


async def receive_event(websocket) -> dict:
    return json.loads(await asyncio.wait_for(websocket.recv(), timeout=3.0))


async def receive_until(websocket, event_type: str) -> tuple[list[dict], dict]:
    events: list[dict] = []
    for _ in range(200):
        event = await receive_event(websocket)
        events.append(event)
        if event["type"] == event_type:
            return events, event
    raise AssertionError(f"Did not receive {event_type}")


def run_git(*arguments: str, cwd: Path) -> None:
    subprocess.run(["git", *arguments], cwd=cwd, check=True, capture_output=True)


class WorkspaceFlowTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.repo = Path(self.temporary_directory.name) / "repo"
        self.repo.mkdir()
        run_git("init", "-b", "main", cwd=self.repo)
        run_git("config", "user.name", "Test", cwd=self.repo)
        run_git("config", "user.email", "test@example.com", cwd=self.repo)
        (self.repo / "app.py").write_text("print('hello')\n", encoding="utf-8")
        run_git("add", "-A", cwd=self.repo)
        run_git("commit", "-m", "initial", cwd=self.repo)

        settings = Settings(
            database_path=Path(self.temporary_directory.name) / "flow.db",
            workspaces_file=Path(self.temporary_directory.name) / "workspaces.json",
            mcp_config_path=Path(self.temporary_directory.name) / "mcp.json",
            fake_chunk_delay_seconds=0.001,
        )
        self.application = SpatialAgentServer(settings)
        await self.application.initialize()
        self.workspace = self.application.workspaces.register("Demo", self.repo)
        self.websocket_server = await serve(
            self.application.handle_connection, "127.0.0.1", 0
        )
        self.port = self.websocket_server.sockets[0].getsockname()[1]

    async def asyncTearDown(self) -> None:
        self.websocket_server.close()
        await self.websocket_server.wait_closed()

    async def open_session(self, protocol_version: int = 2):
        websocket = await connect(f"ws://127.0.0.1:{self.port}/ws")
        await websocket.send(
            command(
                "session.hello",
                payload={"client": "flow-test", "protocol_version": protocol_version},
            )
        )
        ready = await receive_event(websocket)
        assert ready["type"] == "session.ready", ready
        return websocket, ready["session_id"]

    async def first_thread_id(self, websocket, session_id: str) -> str:
        await websocket.send(command("thread.list", session_id=session_id))
        snapshot = await receive_event(websocket)
        return snapshot["payload"]["threads"][0]["id"]

    async def test_v2_workspace_bind_run_diff_and_reject(self) -> None:
        websocket, session_id = await self.open_session()
        async with websocket:
            await websocket.send(command("workspace.list", session_id=session_id))
            snapshot = await receive_event(websocket)
            self.assertEqual(snapshot["type"], "workspace.snapshot")
            self.assertEqual(
                [workspace["id"] for workspace in snapshot["payload"]["workspaces"]],
                [self.workspace.id],
            )

            thread_id = await self.first_thread_id(websocket, session_id)
            await websocket.send(
                command(
                    "workspace.bind",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"workspace_id": self.workspace.id},
                )
            )
            updated = await receive_event(websocket)
            self.assertEqual(updated["type"], "thread.updated")
            self.assertEqual(
                updated["payload"]["thread"]["metadata"]["workspace_id"],
                self.workspace.id,
            )

            await websocket.send(
                command(
                    "message.send",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"content": "change the repo"},
                )
            )
            events, _ = await receive_until(websocket, "run.completed")
            workspace_event = next(
                event for event in events if event["type"] == "run.workspace"
            )
            run_id = workspace_event["payload"]["run_id"]
            self.assertEqual(workspace_event["payload"]["workspace_id"], self.workspace.id)
            self.assertTrue(workspace_event["payload"]["branch"].startswith("spatial/agent-"))

            worktree_path = (
                self.repo / ".spatial" / "worktrees" / run_id
            )
            self.assertTrue(worktree_path.is_dir())
            (worktree_path / "notes.txt").write_text("hello agent\n", encoding="utf-8")

            await websocket.send(
                command("file.list", session_id=session_id, thread_id=thread_id)
            )
            tree = await receive_event(websocket)
            self.assertEqual(tree["type"], "file.tree")
            self.assertIn("notes.txt", [entry["name"] for entry in tree["payload"]["entries"]])

            await websocket.send(
                command(
                    "file.read",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"path": "app.py"},
                )
            )
            content = await receive_event(websocket)
            self.assertEqual(content["type"], "file.content")
            self.assertIn("print('hello')", content["payload"]["content"])

            await websocket.send(
                command("diff.get", session_id=session_id, thread_id=thread_id)
            )
            proposed = await receive_event(websocket)
            self.assertEqual(proposed["type"], "diff.proposed")
            self.assertEqual(proposed["payload"]["run_id"], run_id)
            self.assertEqual(proposed["payload"]["files"][0]["path"], "notes.txt")
            self.assertEqual(proposed["payload"]["files"][0]["change"], "added")

            await websocket.send(
                command(
                    "diff.decision",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"run_id": run_id, "decision": "reject"},
                )
            )
            _, rejected = await receive_until(websocket, "diff.rejected")
            self.assertEqual(rejected["payload"]["run_id"], run_id)
            self.assertFalse(worktree_path.exists())

            await websocket.send(
                command("diff.get", session_id=session_id, thread_id=thread_id)
            )
            _, proposed_again = await receive_until(websocket, "diff.proposed")
            # With the worktree gone, the daemon falls back to diffing the bound
            # repository's working tree directly.
            self.assertTrue(str(proposed_again["payload"]["run_id"]).startswith("direct:"))

    async def test_v2_apply_commits_on_the_agent_branch_only(self) -> None:
        websocket, session_id = await self.open_session()
        async with websocket:
            thread_id = await self.first_thread_id(websocket, session_id)
            await websocket.send(
                command(
                    "workspace.bind",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"workspace_id": self.workspace.id},
                )
            )
            await receive_event(websocket)

            await websocket.send(
                command(
                    "message.send",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"content": "edit the repo"},
                )
            )
            events, _ = await receive_until(websocket, "run.completed")
            run_id = next(
                event for event in events if event["type"] == "run.workspace"
            )["payload"]["run_id"]
            worktree_path = self.repo / ".spatial" / "worktrees" / run_id
            (worktree_path / "app.py").write_text(
                "print('hello')\nprint('agent edit')\n", encoding="utf-8"
            )

            await websocket.send(
                command(
                    "diff.decision",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"run_id": run_id, "decision": "apply"},
                )
            )
            applied = await receive_event(websocket)
            self.assertEqual(applied["type"], "diff.applied")
            self.assertEqual(len(applied["payload"]["commit"]), 40)
            self.assertFalse(worktree_path.exists())

            # The user's checkout is untouched; the change lives on the agent branch.
            self.assertEqual(
                (self.repo / "app.py").read_text(encoding="utf-8"), "print('hello')\n"
            )
            branches = subprocess.run(
                ["git", "branch", "--list"], cwd=self.repo, capture_output=True, text=True
            ).stdout
            self.assertIn(f"spatial/agent-{run_id}", branches)

    async def test_v1_session_rejects_v2_commands(self) -> None:
        websocket, session_id = await self.open_session(protocol_version=1)
        async with websocket:
            await websocket.send(command("workspace.list", session_id=session_id))
            event = await receive_event(websocket)
            self.assertEqual(event["type"], "error")
            self.assertEqual(event["payload"]["code"], "unsupported_version")

    async def test_combine_creates_thread_with_both_contexts(self) -> None:
        websocket, session_id = await self.open_session()
        async with websocket:
            thread_id = await self.first_thread_id(websocket, session_id)
            await websocket.send(
                command(
                    "message.send",
                    session_id=session_id,
                    thread_id=thread_id,
                    payload={"content": "Alpha context marker"},
                )
            )
            await receive_until(websocket, "run.completed")

            await websocket.send(
                command("thread.create", session_id=session_id, payload={"title": "Second agent"})
            )
            created = await receive_event(websocket)
            self.assertEqual(created["type"], "thread.created")
            second_id = created["thread_id"]
            await websocket.send(
                command(
                    "message.send",
                    session_id=session_id,
                    thread_id=second_id,
                    payload={"content": "Beta context marker"},
                )
            )
            await receive_until(websocket, "run.completed")

            await websocket.send(
                command(
                    "thread.combine",
                    session_id=session_id,
                    payload={"thread_ids": [thread_id, second_id]},
                )
            )
            _, combined = await receive_until(websocket, "thread.created")
            payload = combined["payload"]["thread"]
            self.assertIn("combined", payload["title"])
            self.assertEqual(payload["parent_thread_id"], thread_id)
            self.assertEqual(payload["metadata"]["combined_from"], [thread_id, second_id])
            combined_message = payload["messages"][0]["content"]
            self.assertIn("Combined context", combined_message)
            self.assertIn("Alpha context marker", combined_message)
            self.assertIn("Beta context marker", combined_message)

            # The new thread is durable, not just an event.
            restored = await self.application.threads.get_thread(combined["thread_id"])
            self.assertEqual(restored.metadata["combined_from"], [thread_id, second_id])

            # The two originals are absorbed into the combined agent.
            with self.assertRaises(ThreadNotFoundError):
                await self.application.threads.get_thread(thread_id)
            with self.assertRaises(ThreadNotFoundError):
                await self.application.threads.get_thread(second_id)

    async def test_separate_restores_the_original_agents(self) -> None:
        websocket, session_id = await self.open_session()
        async with websocket:
            thread_id = await self.first_thread_id(websocket, session_id)
            await websocket.send(
                command("thread.create", session_id=session_id, payload={"title": "Second agent"})
            )
            created = await receive_event(websocket)
            second_id = created["thread_id"]

            await websocket.send(
                command(
                    "thread.combine",
                    session_id=session_id,
                    payload={"thread_ids": [thread_id, second_id]},
                )
            )
            _, combined = await receive_until(websocket, "thread.created")
            combined_id = combined["thread_id"]

            await websocket.send(
                command("thread.separate", session_id=session_id, thread_id=combined_id)
            )
            _, archived = await receive_until(websocket, "thread.archived")
            self.assertEqual(archived["thread_id"], combined_id)
            restored_ids = set()
            for _ in range(2):
                _, event = await receive_until(websocket, "thread.created")
                restored_ids.add(event["thread_id"])
            self.assertEqual(restored_ids, {thread_id, second_id})

            self.assertEqual(
                (await self.application.threads.get_thread(thread_id)).id, thread_id
            )
            with self.assertRaises(ThreadNotFoundError):
                await self.application.threads.get_thread(combined_id)

    async def test_archived_thread_can_be_restored(self) -> None:
        websocket, session_id = await self.open_session()
        async with websocket:
            thread_id = await self.first_thread_id(websocket, session_id)
            await websocket.send(
                command("thread.archive", session_id=session_id, thread_id=thread_id)
            )
            archived = await receive_event(websocket)
            self.assertEqual(archived["type"], "thread.archived")

            await websocket.send(
                command("thread.restore", session_id=session_id, thread_id=thread_id)
            )
            _, restored = await receive_until(websocket, "thread.created")
            self.assertEqual(restored["payload"]["thread"]["id"], thread_id)

            await websocket.send(command("thread.list", session_id=session_id))
            snapshot = await receive_event(websocket)
            self.assertIn(
                thread_id, [item["id"] for item in snapshot["payload"]["threads"]]
            )

    async def test_tool_catalog_reports_sources(self) -> None:
        websocket, session_id = await self.open_session()
        async with websocket:
            await websocket.send(command("tool.catalog", session_id=session_id))
            event = await receive_event(websocket)
            self.assertEqual(event["type"], "tool.catalog")
            sources = {tool["source"] for tool in event["payload"]["tools"]}
            self.assertEqual(sources, {"native"})
            self.assertEqual(event["payload"]["mcp_servers"], [])


if __name__ == "__main__":
    unittest.main()
