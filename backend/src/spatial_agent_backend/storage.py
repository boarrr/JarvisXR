from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import time
from contextlib import closing
from typing import Any

from .domain import Device, Message, Thread
from .protocol import utc_now


class SQLiteStore:
    def __init__(self, database_path: Path) -> None:
        self.database_path = database_path

    def initialize(self) -> None:
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        with closing(self._connect()) as connection, connection:
            connection.executescript(
                """
                PRAGMA journal_mode=WAL;
                PRAGMA foreign_keys=ON;

                CREATE TABLE IF NOT EXISTS threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    status TEXT NOT NULL,
                    unread_count INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    parent_thread_id TEXT NOT NULL DEFAULT '',
                    tags_json TEXT NOT NULL DEFAULT '[]',
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    is_pinned INTEGER NOT NULL DEFAULT 0,
                    archived INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY,
                    thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    is_streaming INTEGER NOT NULL DEFAULT 0,
                    metadata_json TEXT NOT NULL DEFAULT '{}'
                );

                CREATE INDEX IF NOT EXISTS messages_thread_created
                ON messages(thread_id, created_at);

                CREATE TABLE IF NOT EXISTS pairing_codes (
                    code_hash TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    expires_at REAL NOT NULL,
                    used INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    token_hash TEXT NOT NULL UNIQUE,
                    created_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL,
                    revoked INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE IF NOT EXISTS runs (
                    run_id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL DEFAULT '',
                    thread_id TEXT NOT NULL DEFAULT '',
                    workspace_id TEXT NOT NULL DEFAULT '',
                    worktree_path TEXT NOT NULL DEFAULT '',
                    branch TEXT NOT NULL DEFAULT '',
                    base_commit TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'active',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS audit_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp TEXT NOT NULL,
                    session_id TEXT NOT NULL DEFAULT '',
                    device_id TEXT NOT NULL DEFAULT '',
                    thread_id TEXT NOT NULL DEFAULT '',
                    run_id TEXT NOT NULL DEFAULT '',
                    event_type TEXT NOT NULL,
                    detail_json TEXT NOT NULL DEFAULT '{}'
                );
                """
            )

    def list_threads(self) -> list[Thread]:
        with closing(self._connect()) as connection, connection:
            rows = connection.execute(
                "SELECT * FROM threads WHERE archived = 0 ORDER BY created_at, rowid"
            ).fetchall()
            return [self._thread_from_row(connection, row) for row in rows]

    def get_thread(self, thread_id: str) -> Thread | None:
        with closing(self._connect()) as connection, connection:
            row = connection.execute(
                "SELECT * FROM threads WHERE id = ? AND archived = 0", (thread_id,)
            ).fetchone()
            return self._thread_from_row(connection, row) if row is not None else None

    def save_thread(self, thread: Thread) -> None:
        with closing(self._connect()) as connection, connection:
            connection.execute(
                """
                INSERT INTO threads (
                    id, title, status, unread_count, created_at, updated_at,
                    parent_thread_id, tags_json, metadata_json, is_pinned, archived
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    status = excluded.status,
                    unread_count = excluded.unread_count,
                    updated_at = excluded.updated_at,
                    parent_thread_id = excluded.parent_thread_id,
                    tags_json = excluded.tags_json,
                    metadata_json = excluded.metadata_json,
                    is_pinned = excluded.is_pinned,
                    archived = 0
                """,
                (
                    thread.id,
                    thread.title,
                    thread.status,
                    thread.unread_count,
                    thread.created_at,
                    thread.updated_at,
                    thread.parent_thread_id,
                    json.dumps(thread.tags),
                    json.dumps(thread.metadata),
                    int(thread.is_pinned),
                ),
            )
            for message in thread.messages:
                connection.execute(
                    """
                    INSERT INTO messages (
                        id, thread_id, role, content, created_at, is_streaming, metadata_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        role = excluded.role,
                        content = excluded.content,
                        is_streaming = excluded.is_streaming,
                        metadata_json = excluded.metadata_json
                    """,
                    (
                        message.id,
                        message.thread_id,
                        message.role,
                        message.content,
                        message.created_at,
                        int(message.is_streaming),
                        json.dumps(message.metadata),
                    ),
                )

    def archive_thread(self, thread_id: str) -> bool:
        with closing(self._connect()) as connection, connection:
            cursor = connection.execute(
                "UPDATE threads SET archived = 1 WHERE id = ? AND archived = 0", (thread_id,)
            )
            return cursor.rowcount > 0

    def insert_pairing_code(self, code_hash: str, ttl_seconds: float) -> bool:
        now = time.time()
        with closing(self._connect()) as connection, connection:
            connection.execute(
                "DELETE FROM pairing_codes WHERE used = 1 OR expires_at <= ?", (now,)
            )
            outstanding = connection.execute(
                "SELECT COUNT(*) FROM pairing_codes"
            ).fetchone()[0]
            if outstanding >= 200:
                return False
            connection.execute(
                "INSERT INTO pairing_codes (code_hash, created_at, expires_at, used) "
                "VALUES (?, ?, ?, 0)",
                (code_hash, utc_now(), now + ttl_seconds),
            )
            return True

    def purge_pairing_codes(self) -> None:
        now = time.time()
        with closing(self._connect()) as connection, connection:
            connection.execute(
                "DELETE FROM pairing_codes WHERE used = 1 OR expires_at <= ?", (now,)
            )

    def consume_pairing_code(self, code_hash: str) -> bool:
        now = time.time()
        with closing(self._connect()) as connection, connection:
            cursor = connection.execute(
                "UPDATE pairing_codes SET used = 1 "
                "WHERE code_hash = ? AND used = 0 AND expires_at > ?",
                (code_hash, now),
            )
            return cursor.rowcount > 0

    def create_device(self, device_id: str, name: str, token_hash: str) -> Device:
        timestamp = utc_now()
        with closing(self._connect()) as connection, connection:
            connection.execute(
                "INSERT INTO devices (id, name, token_hash, created_at, last_seen_at, revoked) "
                "VALUES (?, ?, ?, ?, ?, 0)",
                (device_id, name, token_hash, timestamp, timestamp),
            )
        return Device(id=device_id, name=name, created_at=timestamp, last_seen_at=timestamp)

    def find_device_by_token_hash(self, token_hash: str) -> Device | None:
        with closing(self._connect()) as connection, connection:
            row = connection.execute(
                "SELECT * FROM devices WHERE token_hash = ? AND revoked = 0", (token_hash,)
            ).fetchone()
        return self._device_from_row(row) if row is not None else None

    def touch_device(self, device_id: str) -> None:
        with closing(self._connect()) as connection, connection:
            connection.execute(
                "UPDATE devices SET last_seen_at = ? WHERE id = ?", (utc_now(), device_id)
            )

    def revoke_device(self, device_id: str) -> bool:
        with closing(self._connect()) as connection, connection:
            cursor = connection.execute(
                "UPDATE devices SET revoked = 1 WHERE id = ? AND revoked = 0", (device_id,)
            )
            return cursor.rowcount > 0

    def list_devices(self) -> list[Device]:
        with closing(self._connect()) as connection, connection:
            rows = connection.execute(
                "SELECT * FROM devices WHERE revoked = 0 ORDER BY created_at"
            ).fetchall()
        return [self._device_from_row(row) for row in rows]

    def record_run(
        self,
        run_id: str,
        *,
        session_id: str = "",
        thread_id: str = "",
        workspace_id: str = "",
        worktree_path: str = "",
        branch: str = "",
        base_commit: str = "",
        status: str = "active",
    ) -> None:
        timestamp = utc_now()
        with closing(self._connect()) as connection, connection:
            connection.execute(
                """
                INSERT INTO runs (
                    run_id, session_id, thread_id, workspace_id, worktree_path,
                    branch, base_commit, status, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(run_id) DO UPDATE SET
                    workspace_id = excluded.workspace_id,
                    worktree_path = excluded.worktree_path,
                    branch = excluded.branch,
                    base_commit = excluded.base_commit,
                    status = excluded.status,
                    updated_at = excluded.updated_at
                """,
                (
                    run_id,
                    session_id,
                    thread_id,
                    workspace_id,
                    worktree_path,
                    branch,
                    base_commit,
                    status,
                    timestamp,
                    timestamp,
                ),
            )

    def update_run_status(self, run_id: str, status: str) -> None:
        with closing(self._connect()) as connection, connection:
            connection.execute(
                "UPDATE runs SET status = ?, updated_at = ? WHERE run_id = ?",
                (status, utc_now(), run_id),
            )

    def get_run(self, run_id: str) -> dict[str, Any] | None:
        with closing(self._connect()) as connection, connection:
            row = connection.execute(
                "SELECT * FROM runs WHERE run_id = ?", (run_id,)
            ).fetchone()
        return dict(row) if row is not None else None

    def record_audit(
        self,
        event_type: str,
        *,
        session_id: str = "",
        device_id: str = "",
        thread_id: str = "",
        run_id: str = "",
        detail: dict[str, Any] | None = None,
    ) -> None:
        with closing(self._connect()) as connection, connection:
            connection.execute(
                """
                INSERT INTO audit_events (
                    timestamp, session_id, device_id, thread_id, run_id, event_type, detail_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    utc_now(),
                    session_id,
                    device_id,
                    thread_id,
                    run_id,
                    event_type,
                    json.dumps(detail or {}),
                ),
            )

    def list_audit(self, limit: int = 100) -> list[dict[str, Any]]:
        safe_limit = max(1, min(limit, 1000))
        with closing(self._connect()) as connection, connection:
            rows = connection.execute(
                "SELECT * FROM audit_events ORDER BY id DESC LIMIT ?", (safe_limit,)
            ).fetchall()
        return [
            {
                "id": row["id"],
                "timestamp": row["timestamp"],
                "session_id": row["session_id"],
                "device_id": row["device_id"],
                "thread_id": row["thread_id"],
                "run_id": row["run_id"],
                "event_type": row["event_type"],
                "detail": json.loads(row["detail_json"]),
            }
            for row in rows
        ]

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=5.0)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        return connection

    def _device_from_row(self, row: sqlite3.Row) -> Device:
        return Device(
            id=row["id"],
            name=row["name"],
            created_at=row["created_at"],
            last_seen_at=row["last_seen_at"],
        )

    def _thread_from_row(self, connection: sqlite3.Connection, row: sqlite3.Row) -> Thread:
        messages = [
            Message(
                id=message_row["id"],
                thread_id=message_row["thread_id"],
                role=message_row["role"],
                content=message_row["content"],
                created_at=message_row["created_at"],
                is_streaming=bool(message_row["is_streaming"]),
                metadata=json.loads(message_row["metadata_json"]),
            )
            for message_row in connection.execute(
                "SELECT * FROM messages WHERE thread_id = ? ORDER BY created_at, rowid",
                (row["id"],),
            ).fetchall()
        ]
        return Thread(
            id=row["id"],
            title=row["title"],
            status=row["status"],
            messages=messages,
            unread_count=row["unread_count"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            parent_thread_id=row["parent_thread_id"],
            tags=json.loads(row["tags_json"]),
            metadata=json.loads(row["metadata_json"]),
            is_pinned=bool(row["is_pinned"]),
        )
