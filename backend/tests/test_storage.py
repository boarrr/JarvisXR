from __future__ import annotations

import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from spatial_agent_backend.thread_service import ThreadNotFoundError, ThreadService
from spatial_agent_backend.storage import SQLiteStore


class StorageTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        database_path = Path(self.temporary_directory.name) / "state.db"
        self.service = ThreadService(SQLiteStore(database_path))
        await self.service.initialize()

    async def asyncTearDown(self) -> None:
        self.temporary_directory.cleanup()

    async def test_default_thread_and_message_persist(self) -> None:
        threads = await self.service.list_threads()
        self.assertEqual(len(threads), 1)
        thread = threads[0]
        message = await self.service.add_message(thread.id, "user", "Persistent hello")

        restored = ThreadService(self.service.store)
        await restored.initialize()
        restored_thread = await restored.get_thread(thread.id)
        self.assertEqual(restored_thread.messages[0].id, message.id)
        self.assertEqual(restored_thread.messages[0].content, "Persistent hello")

    async def test_archive_removes_active_thread(self) -> None:
        thread = await self.service.create_thread("Temporary")
        self.assertTrue(await self.service.archive_thread(thread.id))
        with self.assertRaises(ThreadNotFoundError):
            await self.service.get_thread(thread.id)

        restored = ThreadService(self.service.store)
        await restored.initialize()
        self.assertNotIn(thread.id, {item.id for item in await restored.list_threads()})


if __name__ == "__main__":
    unittest.main()
