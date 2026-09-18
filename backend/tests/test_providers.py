from __future__ import annotations

import asyncio
import importlib.util
import os
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from spatial_agent_backend.domain import Message
from spatial_agent_backend.permissions import PermissionLevel, PermissionService, ToolDefinition
from spatial_agent_backend.providers import (
    ClaudeProvider,
    CouncilProvider,
    DeepSeekProvider,
    FakeProvider,
    OpenAIProvider,
    ProviderConfigurationError,
)
from spatial_agent_backend.providers.base import ToolSpec


class StubProvider:
    def __init__(self, name: str, model: str, chunks: list[str]) -> None:
        self._name = name
        self.model = model
        self.chunks = chunks
        self.seen_messages: list[Message] = []

    @property
    def name(self) -> str:
        return self._name

    async def stream_reply(self, messages, cancel_event):
        self.seen_messages = list(messages)
        for chunk in self.chunks:
            await asyncio.sleep(0)
            if cancel_event.is_set():
                return
            yield chunk


class FailingProvider:
    name = "failing"
    model = "failing-test"

    async def stream_reply(self, _messages, _cancel_event):
        if False:
            yield ""
        raise RuntimeError("provider failed")


class SlowProvider:
    name = "slow"
    model = "slow-test"

    def __init__(self) -> None:
        self.cancelled = False

    async def stream_reply(self, _messages, _cancel_event):
        try:
            await asyncio.sleep(10)
            yield "late"
        finally:
            self.cancelled = True


class FakeResponsesStream:
    def __init__(self) -> None:
        self.events = [
            SimpleNamespace(type="response.created"),
            SimpleNamespace(type="response.output_text.delta", delta="spatial "),
            SimpleNamespace(type="response.output_text.delta", delta="reply"),
            SimpleNamespace(type="response.completed"),
        ]

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args) -> None:
        return None

    def __aiter__(self):
        return self._iterate()

    async def _iterate(self):
        for event in self.events:
            yield event


class FakeResponsesResource:
    def __init__(self) -> None:
        self.request: dict = {}

    async def create(self, **request):
        self.request = request
        return FakeResponsesStream()


class FakeOpenAIClient:
    def __init__(self) -> None:
        self.responses = FakeResponsesResource()


class FakeChatCompletionsStream:
    def __init__(self, chunks: list) -> None:
        self._chunks = chunks

    def __aiter__(self):
        return self._iterate()

    async def _iterate(self):
        for chunk in self._chunks:
            yield chunk


class FakeChatCompletionsResource:
    def __init__(self, chunks: list) -> None:
        self.chunks = chunks
        self.request: dict = {}

    async def create(self, **request):
        self.request = request
        return FakeChatCompletionsStream(self.chunks)


class FakeChatClient:
    def __init__(self, chunks: list) -> None:
        self.chat = SimpleNamespace(
            completions=FakeChatCompletionsResource(chunks)
        )


def chat_chunk(content: str | None = None, tool_calls: list | None = None):
    delta = SimpleNamespace(content=content, tool_calls=tool_calls)
    return SimpleNamespace(choices=[SimpleNamespace(delta=delta)])


def tool_delta(index: int, call_id: str | None, name: str | None, arguments: str | None):
    return SimpleNamespace(
        index=index,
        id=call_id,
        function=SimpleNamespace(name=name, arguments=arguments),
    )


async def no_op_handler(_tool_input: dict) -> dict:
    return {}


class ProviderTests(unittest.IsolatedAsyncioTestCase):
    async def test_council_keeps_perspectives_explicit_and_separate(self) -> None:
        openai = StubProvider("openai", "openai-test", ["one ", "view"])
        claude = StubProvider("claude", "claude-test", ["other ", "view"])
        provider = CouncilProvider(openai, claude)
        messages = [Message.create("thread_test", "user", "compare safely")]

        reply = "".join([
            chunk async for chunk in provider.stream_reply(messages, asyncio.Event())
        ])

        self.assertEqual(provider.name, "council")
        self.assertEqual(provider.model, "openai-test + claude-test")
        self.assertIn("## OpenAI perspective", reply)
        self.assertIn("one view", reply)
        self.assertIn("## Claude perspective", reply)
        self.assertIn("other view", reply)
        self.assertIn("No automatic verdict", reply)
        self.assertEqual(openai.seen_messages, messages)
        self.assertEqual(claude.seen_messages, messages)

    async def test_council_honors_preflight_cancellation(self) -> None:
        provider = CouncilProvider(
            StubProvider("openai", "o", ["hidden"]),
            StubProvider("claude", "c", ["hidden"]),
        )
        cancelled = asyncio.Event()
        cancelled.set()
        chunks = [
            chunk
            async for chunk in provider.stream_reply(
                [Message.create("thread_test", "user", "do not send")],
                cancelled,
            )
        ]
        self.assertEqual(chunks, [])

    async def test_council_cancels_peer_when_one_provider_fails(self) -> None:
        slow = SlowProvider()
        provider = CouncilProvider(FailingProvider(), slow)
        with self.assertRaisesRegex(RuntimeError, "provider failed"):
            _ = [
                chunk
                async for chunk in provider.stream_reply(
                    [Message.create("thread_test", "user", "safe failure")],
                    asyncio.Event(),
                )
            ]
        self.assertTrue(slow.cancelled)

    async def test_fake_provider_streams_provider_neutral_text(self) -> None:
        provider = FakeProvider(chunk_delay_seconds=0.0, chunk_size=7)
        message = Message.create("thread_test", "user", "private prompt")
        chunks = [
            chunk
            async for chunk in provider.stream_reply([message], asyncio.Event())
        ]
        self.assertGreater(len(chunks), 1)
        self.assertIn("private prompt", "".join(chunks))

    async def test_fake_provider_honors_cancellation(self) -> None:
        provider = FakeProvider(chunk_delay_seconds=0.0)
        cancel_event = asyncio.Event()
        cancel_event.set()
        chunks = [
            chunk
            async for chunk in provider.stream_reply(
                [Message.create("thread_test", "user", "cancel")],
                cancel_event,
            )
        ]
        self.assertEqual(chunks, [])

    def test_claude_provider_requires_backend_only_secret(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ProviderConfigurationError):
                ClaudeProvider(model="claude-sonnet-5", max_output_tokens=128)

    def test_openai_provider_requires_backend_only_secret(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ProviderConfigurationError):
                OpenAIProvider(model="gpt-6-astra", max_output_tokens=128)

    async def test_openai_provider_normalizes_responses_stream(self) -> None:
        client = FakeOpenAIClient()
        provider = OpenAIProvider(
            model="gpt-6-astra",
            max_output_tokens=256,
            client=client,
        )
        messages = [
            Message.create("thread_test", "system", "Be precise"),
            Message.create("thread_test", "user", "Show the trace"),
            Message.create("thread_test", "tool", "private tool result"),
        ]
        chunks = [
            chunk
            async for chunk in provider.stream_reply(messages, asyncio.Event())
        ]
        self.assertEqual(chunks, ["spatial ", "reply"])
        self.assertEqual(client.responses.request["model"], "gpt-6-astra")
        self.assertEqual(client.responses.request["max_output_tokens"], 256)
        self.assertTrue(client.responses.request["stream"])
        self.assertEqual(
            client.responses.request["input"],
            [
                {"role": "system", "content": "Be precise"},
                {"role": "user", "content": "Show the trace"},
            ],
        )
        self.assertNotIn("temperature", client.responses.request)

    async def test_deepseek_provider_normalizes_chat_stream(self) -> None:
        client = FakeChatClient(
            [
                chat_chunk(content="deepseek "),
                chat_chunk(content="reply"),
            ]
        )
        provider = DeepSeekProvider(
            model="deepseek-chat", max_output_tokens=512, client=client
        )
        messages = [
            Message.create("thread_test", "system", "Be precise"),
            Message.create("thread_test", "user", "Show the trace"),
        ]
        chunks = [
            chunk async for chunk in provider.stream_reply(messages, asyncio.Event())
        ]
        self.assertEqual(chunks, ["deepseek ", "reply"])
        request = client.chat.completions.request
        self.assertEqual(request["model"], "deepseek-chat")
        self.assertEqual(request["max_tokens"], 512)
        self.assertTrue(request["stream"])
        self.assertEqual(
            request["messages"],
            [
                {"role": "system", "content": "Be precise"},
                {"role": "user", "content": "Show the trace"},
            ],
        )

    async def test_deepseek_provider_emits_tool_calls(self) -> None:
        client = FakeChatClient(
            [
                chat_chunk(
                    tool_calls=[
                        tool_delta(0, "call_1", "mcp.fixture.echo", '{"text": ')
                    ]
                ),
                chat_chunk(tool_calls=[tool_delta(0, None, None, '"hi"}')]),
            ]
        )
        provider = DeepSeekProvider(
            model="deepseek-chat", max_output_tokens=128, client=client
        )
        tools = [
            ToolSpec(
                name="mcp.fixture.echo",
                description="Echo",
                input_schema={"type": "object"},
            )
        ]
        events = [
            event
            async for event in provider.stream_turn(
                [Message.create("thread_test", "user", "echo this")],
                tools,
                asyncio.Event(),
            )
        ]
        tool_events = [event for event in events if event.kind == "tool_call"]
        self.assertEqual(len(tool_events), 1)
        call = tool_events[0].tool_call
        self.assertEqual(call.call_id, "call_1")
        self.assertEqual(call.tool_name, "mcp.fixture.echo")
        self.assertEqual(call.arguments, {"text": "hi"})
        self.assertEqual(events[-1].kind, "done")
        self.assertEqual(
            client.chat.completions.request["tools"],
            [
                {
                    "type": "function",
                    "function": {
                        "name": "mcp.fixture.echo",
                        "description": "Echo",
                        "parameters": {"type": "object"},
                    },
                }
            ],
        )

    def test_deepseek_maps_tool_history_to_chat_format(self) -> None:
        provider = DeepSeekProvider(
            model="deepseek-chat", max_output_tokens=64, client=FakeChatClient([])
        )
        assistant = Message.create("thread_test", "assistant", "")
        assistant.metadata = {
            "tool_calls": [
                {
                    "call_id": "call_1",
                    "name": "mcp.fixture.echo",
                    "arguments": {"text": "hi"},
                }
            ]
        }
        tool = Message.create("thread_test", "tool", "echo: hi")
        tool.metadata = {"tool_call_id": "call_1", "tool_name": "mcp.fixture.echo"}
        messages = provider._chat_messages([assistant, tool])
        self.assertEqual(messages[0]["tool_calls"][0]["id"], "call_1")
        self.assertIsNone(messages[0]["content"])
        self.assertEqual(
            messages[1],
            {"role": "tool", "tool_call_id": "call_1", "content": "echo: hi"},
        )

    def test_deepseek_provider_requires_backend_only_secret(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ProviderConfigurationError):
                DeepSeekProvider(model="deepseek-chat", max_output_tokens=128)

    @unittest.skipUnless(importlib.util.find_spec("openai"), "OpenAI extra is not installed")
    def test_installed_deepseek_adapter_constructs_without_network_access(self) -> None:
        with patch.dict(os.environ, {"DEEPSEEK_API_KEY": "test-only-key"}, clear=True):
            provider = DeepSeekProvider(model="deepseek-chat", max_output_tokens=128)
        self.assertEqual(provider.name, "deepseek")
        self.assertEqual(provider.model, "deepseek-chat")

    @unittest.skipUnless(importlib.util.find_spec("anthropic"), "Claude extra is not installed")
    def test_installed_claude_adapter_constructs_without_network_access(self) -> None:
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-only-key"}, clear=True):
            provider = ClaudeProvider(model="claude-sonnet-5", max_output_tokens=128)
        self.assertEqual(provider.name, "claude")
        self.assertEqual(provider.model, "claude-sonnet-5")

    @unittest.skipUnless(importlib.util.find_spec("openai"), "OpenAI extra is not installed")
    def test_installed_openai_adapter_constructs_without_network_access(self) -> None:
        with patch.dict(os.environ, {"OPENAI_API_KEY": "test-only-key"}, clear=True):
            provider = OpenAIProvider(model="gpt-6-astra", max_output_tokens=128)
        self.assertEqual(provider.name, "openai")
        self.assertEqual(provider.model, "gpt-6-astra")


class PermissionTests(unittest.TestCase):
    def test_sensitive_and_write_tools_require_approval(self) -> None:
        service = PermissionService()
        for level in (
            PermissionLevel.SENSITIVE_READ,
            PermissionLevel.WRITE_REVERSIBLE,
            PermissionLevel.WRITE_EXTERNAL,
            PermissionLevel.DESTRUCTIVE,
        ):
            tool = ToolDefinition("test", "test", {}, level, no_op_handler)
            self.assertTrue(service.requires_approval(tool))

    def test_forbidden_tools_cannot_execute(self) -> None:
        tool = ToolDefinition(
            "forbidden",
            "test",
            {},
            PermissionLevel.FORBIDDEN,
            no_op_handler,
        )
        self.assertFalse(PermissionService().may_execute(tool))


if __name__ == "__main__":
    unittest.main()
