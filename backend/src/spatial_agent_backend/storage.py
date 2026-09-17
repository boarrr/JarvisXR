from __future__ import annotations

import json
from pathlib import Path
import sqlite3
from contextlib import closing

from .domain import Message, Thread


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

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=5.0)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        return connection

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
