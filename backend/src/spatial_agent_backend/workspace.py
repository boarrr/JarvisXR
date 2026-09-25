from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
from typing import Any

from contextlib import suppress

from .observability import log_record

MAX_DIFF_BYTES = 512 * 1024
MAX_DIFF_FILES = 64
MAX_FILE_BYTES = 256 * 1024
MAX_TREE_ENTRIES = 500
MAX_STATUS_FILES = 200
DEFAULT_GIT_TIMEOUT_SECONDS = 30.0
WORKTREE_DIRECTORY_NAME = ".spatial/worktrees"
BRANCH_PREFIX = "spatial/agent-"
SKIPPED_TREE_ENTRIES = {".git", ".spatial"}

_DIFF_HEADER = re.compile(r"^diff --git a/(.*) b/(.*)$")
_HUNK_HEADER = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$")


class WorkspaceError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class Workspace:
    id: str
    name: str
    path: Path
    base_branch: str = "main"

    def to_wire(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "path": str(self.path),
            "base_branch": self.base_branch,
        }


@dataclass(slots=True)
class Worktree:
    run_id: str
    workspace_id: str
    path: Path
    branch: str
    base_commit: str

    def to_wire(self) -> dict[str, Any]:
        return {
            "run_id": self.run_id,
            "workspace_id": self.workspace_id,
            "branch": self.branch,
            "base_commit": self.base_commit,
        }


@dataclass(slots=True)
class DiffHunk:
    header: str
    old_start: int
    new_start: int
    lines: list[str] = field(default_factory=list)

    def to_wire(self) -> dict[str, Any]:
        return {
            "header": self.header,
            "old_start": self.old_start,
            "new_start": self.new_start,
            "lines": list(self.lines),
        }


@dataclass(slots=True)
class FileDiff:
    path: str
    change: str
    additions: int = 0
    deletions: int = 0
    hunks: list[DiffHunk] = field(default_factory=list)

    def to_wire(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "change": self.change,
            "additions": self.additions,
            "deletions": self.deletions,
            "hunks": [hunk.to_wire() for hunk in self.hunks],
        }


class WorkspaceManager:
    """Owns the registered repositories and their isolated agent worktrees.

    Every agent run works inside ``git worktree`` on its own branch, so agent
    changes never touch the user's checkout until an explicit apply/commit.
    """

    def __init__(
        self,
        registry_path: Path,
        *,
        git_timeout_seconds: float = DEFAULT_GIT_TIMEOUT_SECONDS,
        worktree_directory_name: str = WORKTREE_DIRECTORY_NAME,
        branch_prefix: str = BRANCH_PREFIX,
    ) -> None:
        self.registry_path = registry_path
        self.git_timeout_seconds = git_timeout_seconds
        self.worktree_directory_name = worktree_directory_name
        self.branch_prefix = branch_prefix
        self._workspaces: dict[str, Workspace] = {}

    def load(self) -> None:
        if not self.registry_path.is_file():
            return
        try:
            payload = json.loads(self.registry_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            log_record("workspace_registry_unreadable", path=str(self.registry_path))
            return
        workspaces: dict[str, Workspace] = {}
        for entry in payload.get("workspaces", []):
            if not isinstance(entry, dict):
                continue
            workspace_id = str(entry.get("id", ""))
            path_value = str(entry.get("path", ""))
            if not workspace_id or not path_value:
                continue
            workspaces[workspace_id] = Workspace(
                id=workspace_id,
                name=str(entry.get("name", workspace_id)),
                path=Path(path_value),
                base_branch=str(entry.get("base_branch", "main")),
            )
        self._workspaces = workspaces

    def save(self) -> None:
        self.registry_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"workspaces": [workspace.to_wire() for workspace in self._workspaces.values()]}
        self.registry_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    def register(self, name: str, path: Path, base_branch: str = "main") -> Workspace:
        resolved = path.expanduser().resolve()
        if not resolved.is_dir():
            raise WorkspaceError(f"Workspace path is not a directory: {resolved}")
        for existing in self._workspaces.values():
            if existing.path == resolved:
                raise WorkspaceError(f"Workspace already registered: {existing.id}")
        if self._is_git_worktree(resolved) is False:
            raise WorkspaceError(f"Workspace is not a git repository: {resolved}")
        workspace = Workspace(
            id=f"ws_{secrets.token_hex(6)}",
            name=(name.strip() or resolved.name)[:80],
            path=resolved,
            base_branch=base_branch.strip() or "main",
        )
        self._workspaces[workspace.id] = workspace
        self.save()
        return workspace

    def unregister(self, workspace_id: str) -> bool:
        if workspace_id not in self._workspaces:
            return False
        del self._workspaces[workspace_id]
        self.save()
        return True

    def list_workspaces(self) -> list[Workspace]:
        return list(self._workspaces.values())

    def get(self, workspace_id: str) -> Workspace | None:
        return self._workspaces.get(workspace_id)

    async def create_worktree(self, workspace_id: str, run_id: str, base_ref: str = "") -> Worktree:
        workspace = self._require_workspace(workspace_id)
        reference = base_ref.strip() or workspace.base_branch
        base_commit = await self._git(
            workspace.path, "rev-parse", "--verify", f"{reference}^{{commit}}"
        )
        base_commit = base_commit.strip()
        worktree_path = workspace.path / self.worktree_directory_name / run_id
        if worktree_path.exists():
            raise WorkspaceError(f"Worktree path already exists: {worktree_path}")
        worktree_path.parent.mkdir(parents=True, exist_ok=True)
        self._ensure_excluded(workspace.path, f"/{self.worktree_directory_name}/")
        branch = f"{self.branch_prefix}{run_id}"
        await self._git(
            workspace.path,
            "worktree",
            "add",
            "-b",
            branch,
            str(worktree_path),
            base_commit,
        )
        log_record(
            "worktree_created",
            workspace_id=workspace_id,
            run_id=run_id,
            branch=branch,
        )
        return Worktree(
            run_id=run_id,
            workspace_id=workspace_id,
            path=worktree_path,
            branch=branch,
            base_commit=base_commit,
        )

    async def remove_worktree(self, worktree: Worktree) -> None:
        await self.remove_worktree_directory(worktree)
        workspace = self._require_workspace(worktree.workspace_id)
        try:
            await self._git(workspace.path, "branch", "-D", worktree.branch)
        except WorkspaceError:
            pass
        log_record(
            "worktree_removed",
            workspace_id=worktree.workspace_id,
            run_id=worktree.run_id,
        )

    async def remove_worktree_directory(self, worktree: Worktree) -> None:
        """Remove the worktree checkout while keeping its branch and commits."""
        workspace = self._require_workspace(worktree.workspace_id)
        if worktree.path.exists():
            await self._git(
                workspace.path, "worktree", "remove", "--force", str(worktree.path)
            )

    async def diff(self, worktree: Worktree) -> tuple[list[FileDiff], bool]:
        await self._git(worktree.path, "add", "-A")
        raw = await self._git(
            worktree.path,
            "diff",
            "--cached",
            "--no-color",
            "--find-renames",
            "--unified=3",
        )
        truncated = len(raw.encode("utf-8")) > MAX_DIFF_BYTES
        if truncated:
            raw = raw[:MAX_DIFF_BYTES]
        return _parse_unified_diff(raw), truncated

    async def diff_lines(self, worktree: Worktree) -> str:
        await self._git(worktree.path, "add", "-A")
        raw = await self._git(
            worktree.path,
            "diff",
            "--cached",
            "--no-color",
            "--find-renames",
            "--unified=3",
        )
        if len(raw.encode("utf-8")) > MAX_DIFF_BYTES:
            raw = raw[:MAX_DIFF_BYTES]
        return raw

    async def run_tests(
        self, worktree: Worktree, command: str, timeout_seconds: float = 900.0
    ) -> tuple[bool, str]:
        """Run the operator-provided test command inside the worktree."""
        try:
            proc = await asyncio.create_subprocess_shell(
                command,
                cwd=str(worktree.path),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
        except Exception as error:  # noqa: BLE001
            return False, str(error)
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), timeout_seconds)
        except asyncio.TimeoutError:
            with suppress(Exception):
                proc.kill()
            return False, "test command timed out"
        text = (out or b"").decode("utf-8", errors="replace")
        return proc.returncode == 0, text[:4000]

    async def commit(self, worktree: Worktree, message: str) -> str:
        await self._git(worktree.path, "add", "-A")
        status = await self._git(worktree.path, "status", "--porcelain")
        if not status.strip():
            raise WorkspaceError("No changes to apply")
        await self._git(
            worktree.path,
            "-c",
            "user.name=Spatial Agent",
            "-c",
            "user.email=spatial-agent@local",
            "commit",
            "--no-gpg-sign",
            "-m",
            message.strip() or f"spatial agent run {worktree.run_id}",
        )
        commit_sha = (await self._git(worktree.path, "rev-parse", "HEAD")).strip()
        log_record("worktree_committed", run_id=worktree.run_id, commit=commit_sha[:12])
        return commit_sha

    async def status(self, worktree: Worktree) -> dict[str, Any]:
        raw = await self._git(worktree.path, "status", "--porcelain=v1", "--branch")
        branch = ""
        files: list[dict[str, str]] = []
        for line in raw.splitlines():
            if line.startswith("## "):
                branch = line[3:].split("...")[0].strip()
                continue
            if len(files) >= MAX_STATUS_FILES:
                continue
            if len(line) > 3:
                files.append({"status": line[:2].strip(), "path": line[3:].strip()})
        return {"branch": branch, "dirty": bool(files), "files": files}

    async def read_file(self, workspace_id: str, relative_path: str) -> dict[str, Any]:
        workspace = self._require_workspace(workspace_id)
        return read_file_bounded(workspace.path, relative_path)

    def list_tree(self, workspace_id: str, relative_path: str = "") -> list[dict[str, Any]]:
        workspace = self._require_workspace(workspace_id)
        return list_directory(workspace.path, relative_path)

    async def _git(self, cwd: Path, *arguments: str) -> str:
        process = await asyncio.create_subprocess_exec(
            "git",
            "-C",
            str(cwd),
            *arguments,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        )
        try:
            stdout, stderr = await asyncio.wait_for(
                process.communicate(), timeout=self.git_timeout_seconds
            )
        except asyncio.TimeoutError as error:
            process.kill()
            await process.wait()
            raise WorkspaceError("git command timed out") from error
        if process.returncode != 0:
            detail = stderr.decode("utf-8", errors="replace").strip()[:400]
            raise WorkspaceError(f"git {arguments[0] if arguments else ''} failed: {detail}")
        return stdout.decode("utf-8", errors="replace")

    def _require_workspace(self, workspace_id: str) -> Workspace:
        workspace = self._workspaces.get(workspace_id)
        if workspace is None:
            raise WorkspaceError(f"Unknown workspace: {workspace_id}")
        return workspace

    def _ensure_excluded(self, repository: Path, pattern: str) -> None:
        exclude_path = repository / ".git" / "info" / "exclude"
        try:
            existing = exclude_path.read_text(encoding="utf-8") if exclude_path.is_file() else ""
            if pattern not in existing.splitlines():
                exclude_path.parent.mkdir(parents=True, exist_ok=True)
                exclude_path.write_text(existing + ("" if existing.endswith("\n") or not existing else "\n") + pattern + "\n", encoding="utf-8")
        except OSError:
            pass

    def _is_git_worktree(self, path: Path) -> bool:
        try:
            result = subprocess.run(
                ["git", "-C", str(path), "rev-parse", "--is-inside-work-tree"],
                capture_output=True,
                text=True,
                timeout=self.git_timeout_seconds,
                env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        return result.returncode == 0 and result.stdout.strip() == "true"


def _resolve_inside(root: Path, relative_path: str) -> Path:
    if not relative_path or relative_path.startswith(("/", "\\")) or ".." in Path(relative_path).parts:
        raise WorkspaceError("Path must be a relative path inside the workspace")
    resolved_root = root.resolve()
    candidate = (resolved_root / relative_path).resolve()
    if candidate != resolved_root and resolved_root not in candidate.parents:
        raise WorkspaceError("Path escapes the workspace")
    return candidate


def read_file_bounded(root: Path, relative_path: str) -> dict[str, Any]:
    target = _resolve_inside(root, relative_path)
    if not target.is_file():
        raise WorkspaceError("File does not exist")
    size = target.stat().st_size
    data = target.read_bytes()[:MAX_FILE_BYTES]
    if b"\x00" in data[:8192]:
        return {"path": relative_path, "size": size, "binary": True, "content": ""}
    return {
        "path": relative_path,
        "size": size,
        "binary": False,
        "truncated": size > MAX_FILE_BYTES,
        "content": data.decode("utf-8", errors="replace"),
    }


def list_directory(root: Path, relative_path: str = "") -> list[dict[str, Any]]:
    base = _resolve_inside(root, relative_path) if relative_path else root
    if not base.is_dir():
        raise WorkspaceError("Directory does not exist")
    entries: list[dict[str, Any]] = []
    for entry in sorted(base.iterdir(), key=lambda item: (item.is_file(), item.name.lower())):
        if entry.name in SKIPPED_TREE_ENTRIES or entry.is_symlink():
            continue
        if len(entries) >= MAX_TREE_ENTRIES:
            break
        relative = str(entry.relative_to(root))
        entry_type = "dir" if entry.is_dir() else "file"
        size = entry.stat().st_size if entry_type == "file" else 0
        entries.append({"name": entry.name, "path": relative, "type": entry_type, "size": size})
    return entries


def _parse_unified_diff(raw: str) -> list[FileDiff]:
    files: list[FileDiff] = []
    current: FileDiff | None = None
    current_hunk: DiffHunk | None = None
    for line in raw.splitlines():
        header = _DIFF_HEADER.match(line)
        if header:
            if len(files) >= MAX_DIFF_FILES:
                break
            new_path, old_path = header.group(2), header.group(1)
            path = new_path if new_path != "/dev/null" else old_path
            current = FileDiff(path=path, change="modified")
            files.append(current)
            current_hunk = None
            continue
        if current is None:
            continue
        if line.startswith("new file mode"):
            current.change = "added"
            continue
        if line.startswith("deleted file mode"):
            current.change = "deleted"
            continue
        if line.startswith("rename from"):
            current.change = "renamed"
            continue
        if line.startswith("Binary files") or line.startswith("GIT binary patch"):
            current.change = "binary"
            continue
        hunk = _HUNK_HEADER.match(line)
        if hunk:
            current_hunk = DiffHunk(
                header=line,
                old_start=int(hunk.group(1)),
                new_start=int(hunk.group(2)),
            )
            current.hunks.append(current_hunk)
            continue
        if current_hunk is not None and line[:1] in {"+", "-", " "}:
            current_hunk.lines.append(line)
            if line.startswith("+"):
                current.additions += 1
            elif line.startswith("-"):
                current.deletions += 1
    return files
