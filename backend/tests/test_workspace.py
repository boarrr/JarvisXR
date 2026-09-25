from __future__ import annotations

from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest

from spatial_agent_backend.workspace import WorkspaceError, WorkspaceManager


def run_git(*arguments: str, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *arguments],
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
    )


class WorkspaceManagerTests(unittest.IsolatedAsyncioTestCase):
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
        self.manager = WorkspaceManager(
            Path(self.temporary_directory.name) / "workspaces.json"
        )
        self.workspace = self.manager.register("Demo", self.repo)

    async def test_worktree_lifecycle_diff_and_commit(self) -> None:
        worktree = await self.manager.create_worktree(self.workspace.id, "run_lifecycle")
        self.assertTrue(worktree.path.is_dir())
        self.assertEqual(worktree.branch, f"spatial/agent-run_lifecycle")

        (worktree.path / "app.py").write_text(
            "print('hello')\nprint('agent')\n", encoding="utf-8"
        )
        (worktree.path / "notes.txt").write_text("agent output\n", encoding="utf-8")

        diffs, truncated = await self.manager.diff(worktree)
        self.assertFalse(truncated)
        by_path = {diff.path: diff for diff in diffs}
        self.assertIn("app.py", by_path)
        self.assertIn("notes.txt", by_path)
        self.assertEqual(by_path["notes.txt"].change, "added")
        self.assertGreaterEqual(by_path["app.py"].additions, 1)
        self.assertTrue(
            any(
                line.startswith("+print('agent')")
                for hunk in by_path["app.py"].hunks
                for line in hunk.lines
            )
        )

        commit = await self.manager.commit(worktree, "agent change")
        self.assertEqual(len(commit), 40)
        status = await self.manager.status(worktree)
        self.assertFalse(status["dirty"])
        self.assertEqual(status["branch"], worktree.branch)

        await self.manager.remove_worktree(worktree)
        self.assertFalse(worktree.path.exists())
        branches = run_git("branch", "--list", cwd=self.repo).stdout
        self.assertNotIn(worktree.branch, branches)

    async def test_run_tests_in_worktree(self) -> None:
        worktree = await self.manager.create_worktree(self.workspace.id, "run_tests")
        passed, output = await self.manager.run_tests(
            worktree, "python3 -c 'print(42)'"
        )
        self.assertTrue(passed)
        self.assertIn("42", output)
        failed, _output = await self.manager.run_tests(
            worktree, "python3 -c 'import sys; sys.exit(3)'"
        )
        self.assertFalse(failed)
        await self.manager.remove_worktree(worktree)

    async def test_commit_without_changes_fails(self) -> None:
        worktree = await self.manager.create_worktree(self.workspace.id, "run_nochange")
        with self.assertRaises(WorkspaceError):
            await self.manager.commit(worktree, "nothing to apply")
        await self.manager.remove_worktree(worktree)

    async def test_worktrees_do_not_touch_the_main_checkout(self) -> None:
        worktree = await self.manager.create_worktree(self.workspace.id, "run_isolated")
        (worktree.path / "app.py").write_text("print('changed')\n", encoding="utf-8")
        await self.manager.commit(worktree, "isolated change")
        main_content = (self.repo / "app.py").read_text(encoding="utf-8")
        self.assertEqual(main_content, "print('hello')\n")
        await self.manager.remove_worktree(worktree)

    def test_registry_rejects_duplicates_and_non_repositories(self) -> None:
        with self.assertRaises(WorkspaceError):
            self.manager.register("Duplicate", self.repo)
        with self.assertRaises(WorkspaceError):
            self.manager.register("NotGit", Path(self.temporary_directory.name))

    async def test_path_traversal_is_rejected(self) -> None:
        with self.assertRaises(WorkspaceError):
            await self.manager.read_file(self.workspace.id, "../outside.txt")
        with self.assertRaises(WorkspaceError):
            await self.manager.read_file(self.workspace.id, "/etc/hosts")

    async def test_tree_and_file_reads_are_bounded_and_skip_internal_dirs(self) -> None:
        entries = self.manager.list_tree(self.workspace.id)
        names = {entry["name"] for entry in entries}
        self.assertIn("app.py", names)
        self.assertNotIn(".git", names)

        content = await self.manager.read_file(self.workspace.id, "app.py")
        self.assertIn("hello", content["content"])
        self.assertFalse(content["binary"])

        worktree = await self.manager.create_worktree(self.workspace.id, "run_tree")
        names_after = {entry["name"] for entry in self.manager.list_tree(self.workspace.id)}
        self.assertNotIn(".spatial", names_after)
        await self.manager.remove_worktree(worktree)


if __name__ == "__main__":
    unittest.main()
