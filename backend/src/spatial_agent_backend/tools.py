from __future__ import annotations

import asyncio
from time import monotonic
from typing import Any

from .mcp_host import McpCallResult, McpHost, McpTool
from .permissions import (
    PermissionLevel,
    ToolDefinition,
    build_mcp_impact_preview,
    map_mcp_permission,
)
from .protocol import utc_now

MAX_TOOL_RESULT_CHARS = 16_000
MAX_REGISTERED_MCP_TOOLS = 100


class ToolCallError(RuntimeError):
    pass


async def _demo_note_handler(tool_input: dict[str, Any]) -> dict[str, Any]:
    await asyncio.sleep(0)
    text = str(tool_input.get("text", "Demonstration note"))[:500]
    return {
        "status": "simulated",
        "message": f"Approved simulated note: {text}",
        "external_side_effect": False,
    }


async def _clock_handler(_tool_input: dict[str, Any]) -> dict[str, Any]:
    await asyncio.sleep(0)
    return {
        "status": "ok",
        "message": f"Chronometer synchronized: {utc_now()}",
        "external_side_effect": False,
    }


class ToolRegistry:
    def __init__(self) -> None:
        self._started_at = monotonic()
        self._tools: dict[str, ToolDefinition] = {
            "system.clock": ToolDefinition(
                tool_id="system.clock",
                description="Read the backend's current UTC clock.",
                input_schema={"type": "object", "additionalProperties": False},
                permission_level=PermissionLevel.SAFE_READ,
                handler=_clock_handler,
                audit_category="local_telemetry",
                impact_preview={
                    "route": ["gesture", "local backend", "clock"],
                    "scope": "local process",
                    "side_effect": "none",
                    "reversibility": "read only",
                    "external": False,
                },
            ),
            "system.diagnostics": ToolDefinition(
                tool_id="system.diagnostics",
                description="Read non-sensitive service health and uptime.",
                input_schema={"type": "object", "additionalProperties": False},
                permission_level=PermissionLevel.SAFE_READ,
                handler=self._diagnostics_handler,
                audit_category="local_telemetry",
                impact_preview={
                    "route": ["gesture", "local backend", "health metrics"],
                    "scope": "local process",
                    "side_effect": "none",
                    "reversibility": "read only",
                    "external": False,
                },
            ),
            "demo.write_note": ToolDefinition(
                tool_id="demo.write_note",
                description="Simulate writing a note without changing any external system.",
                input_schema={
                    "type": "object",
                    "properties": {"text": {"type": "string", "maxLength": 500}},
                    "additionalProperties": False,
                },
                permission_level=PermissionLevel.WRITE_REVERSIBLE,
                handler=_demo_note_handler,
                audit_category="simulated_write",
                impact_preview={
                    "route": ["gesture", "local backend", "simulation buffer"],
                    "scope": "one in-memory demonstration note",
                    "side_effect": "no external write",
                    "reversibility": "discarded with process state",
                    "external": False,
                },
            ),
        }

    async def _diagnostics_handler(self, _tool_input: dict[str, Any]) -> dict[str, Any]:
        await asyncio.sleep(0)
        uptime_seconds = max(0, round(monotonic() - self._started_at))
        return {
            "status": "nominal",
            "message": (
                "System scan nominal: protocol=v1, transport=websocket, "
                f"tools={len(self._tools)}, uptime={uptime_seconds}s"
            ),
            "external_side_effect": False,
        }

    def register_mcp_server(
        self,
        host: McpHost,
        server_id: str,
        tools: list[McpTool],
    ) -> int:
        registered = 0
        tool_levels = host.tool_levels(server_id)
        for tool in tools:
            if len(self._tools) >= MAX_REGISTERED_MCP_TOOLS + 3:
                break
            tool_id = f"mcp.{server_id}.{tool.name}"
            level = map_mcp_permission(
                tool.annotations,
                configured=tool_levels.get(tool.name),
                server_default=host.server_default_level(server_id),
            )
            self._tools[tool_id] = ToolDefinition(
                tool_id=tool_id,
                description=(
                    tool.description or f"{tool.name} provided by MCP server {server_id}"
                ),
                input_schema=tool.input_schema
                or {"type": "object", "properties": {}},
                permission_level=level,
                handler=self._make_mcp_handler(host, server_id, tool.name, level),
                timeout_seconds=host.tool_timeout_seconds(server_id),
                audit_category=f"mcp:{server_id}",
                impact_preview=build_mcp_impact_preview(
                    server_id, tool.name, level, tool.annotations
                ),
                source="mcp",
                server_id=server_id,
                annotations=dict(tool.annotations),
            )
            registered += 1
        return registered

    def _make_mcp_handler(
        self,
        host: McpHost,
        server_id: str,
        tool_name: str,
        level: PermissionLevel,
    ):
        async def handler(tool_input: dict[str, Any]) -> dict[str, Any]:
            result: McpCallResult = await host.call_tool(server_id, tool_name, tool_input)
            text = result.text[:MAX_TOOL_RESULT_CHARS]
            if result.is_error:
                raise ToolCallError(text or f"MCP tool {tool_name} failed")
            return {
                "status": "ok",
                "message": text or f"{tool_name} completed",
                "external_side_effect": level is not PermissionLevel.SAFE_READ,
                "server_id": server_id,
                "tool_name": tool_name,
                "truncated": result.truncated,
            }

        return handler

    def get(self, tool_id: str) -> ToolDefinition | None:
        return self._tools.get(tool_id)

    def list_tools(self) -> list[ToolDefinition]:
        return list(self._tools.values())

    def list_tool_specs(self) -> list:
        from .providers.base import ToolSpec

        return [
            ToolSpec(
                name=tool.tool_id,
                description=tool.description,
                input_schema=tool.input_schema,
            )
            for tool in self._tools.values()
        ]

    def counts_by_source(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for tool in self._tools.values():
            counts[tool.source] = counts.get(tool.source, 0) + 1
        return counts
