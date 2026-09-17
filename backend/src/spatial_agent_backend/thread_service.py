from __future__ import annotations

import asyncio
from typing import Any

from .domain import Message, Thread
from .storage import SQLiteStore


class ThreadNotFoundError(LookupError):
    pass


class ThreadService:
    def __init__(self, store: SQLiteStore) -> None:
        self.store = store
        self._threads: dict[str, Thread] = {}
        self._lock = asyncio.Lock()

    async def initialize(self) -> None:
        await asyncio.to_thread(self.store.initialize)
        threads = await asyncio.to_thread(self.store.list_threads)
        self._threads = {thread.id: thread for thread in threads}
        if not self._threads:
            await self.create_thread("General Assistant")

    async def list_threads(self) -> list[Thread]:
        async with self._lock:
            return list(self._threads.values())

    async def get_thread(self, thread_id: str) -> Thread:
        async with self._lock:
            thread = self._threads.get(thread_id)
            if thread is None:
                raise ThreadNotFoundError(thread_id)
            return thread

    async def create_thread(self, title: str = "New thread") -> Thread:
        clean_title = title.strip()[:120] or "New thread"
        thread = Thread.create(clean_title)
        async with self._lock:
            self._threads[thread.id] = thread
            await asyncio.to_thread(self.store.save_thread, thread)
        return thread

    async def rename_thread(self, thread_id: str, title: str) -> Thread:
        async with self._lock:
            thread = self._require_thread(thread_id)
            thread.title = title.strip()[:120]
            thread.touch()
            await asyncio.to_thread(self.store.save_thread, thread)
            return thread

    async def archive_thread(self, thread_id: str) -> bool:
        async with self._lock:
            self._require_thread(thread_id)
            archived = await asyncio.to_thread(self.store.archive_thread, thread_id)
            if archived:
                self._threads.pop(thread_id, None)
            return archived

    async def add_message(
        self,
        thread_id: str,
        role: str,
        content: str = "",
        *,
        streaming: bool = False,
        metadata: dict[str, Any] | None = None,
    ) -> Message:
        async with self._lock:
            thread = self._require_thread(thread_id)
            message = Message.create(thread_id, role, content, streaming=streaming)
            if metadata:
                message.metadata.update(metadata)
            thread.add_message(message)
            await asyncio.to_thread(self.store.save_thread, thread)
            return message

    async def record_tool_calls(
        self, thread_id: str, message_id: str, tool_calls: list[dict[str, Any]]
    ) -> Message:
        async with self._lock:
            thread = self._require_thread(thread_id)
            message = next((item for item in thread.messages if item.id == message_id), None)
            if message is None:
                raise LookupError(message_id)
            existing = message.metadata.setdefault("tool_calls", [])
            existing.extend(tool_calls)
            thread.touch()
            await asyncio.to_thread(self.store.save_thread, thread)
            return message

    async def set_status(self, thread_id: str, status: str, *, persist: bool = True) -> Thread:
        async with self._lock:
            thread = self._require_thread(thread_id)
            thread.set_status(status)
            if persist:
                await asyncio.to_thread(self.store.save_thread, thread)
            return thread

    async def append_delta(self, thread_id: str, message_id: str, delta: str) -> Message:
        async with self._lock:
            thread = self._require_thread(thread_id)
            message = next((item for item in thread.messages if item.id == message_id), None)
            if message is None:
                raise LookupError(message_id)
            message.content += delta
            thread.touch()
            return message

    async def complete_message(self, thread_id: str, message_id: str, *, cancelled: bool = False) -> Message:
        async with self._lock:
            thread = self._require_thread(thread_id)
            message = next((item for item in thread.messages if item.id == message_id), None)
            if message is None:
                raise LookupError(message_id)
            message.is_streaming = False
            message.metadata["cancelled"] = cancelled
            thread.touch()
            await asyncio.to_thread(self.store.save_thread, thread)
            return message

    async def persist_thread(self, thread_id: str) -> Thread:
        async with self._lock:
            thread = self._require_thread(thread_id)
            await asyncio.to_thread(self.store.save_thread, thread)
            return thread

    def _require_thread(self, thread_id: str) -> Thread:
        thread = self._threads.get(thread_id)
        if thread is None:
            raise ThreadNotFoundError(thread_id)
        return thread
