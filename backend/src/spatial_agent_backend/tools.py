from __future__ import annotations

import asyncio
from time import monotonic
from typing import Any

from .permissions import PermissionLevel, ToolDefinition
from .protocol import utc_now


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
        self._tools = {
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
            )
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

    def get(self, tool_id: str) -> ToolDefinition | None:
        return self._tools.get(tool_id)

    def list_tools(self) -> list[ToolDefinition]:
        return list(self._tools.values())
