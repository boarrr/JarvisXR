from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any, Awaitable, Callable


class PermissionLevel(StrEnum):
    SAFE_READ = "safe_read"
    SENSITIVE_READ = "sensitive_read"
    WRITE_REVERSIBLE = "write_reversible"
    WRITE_EXTERNAL = "write_external"
    DESTRUCTIVE = "destructive"
    FORBIDDEN = "forbidden"


ToolHandler = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]


@dataclass(frozen=True, slots=True)
class ToolDefinition:
    tool_id: str
    description: str
    input_schema: dict[str, Any]
    permission_level: PermissionLevel
    handler: ToolHandler
    timeout_seconds: float = 10.0
    audit_category: str = "development"
    impact_preview: dict[str, Any] = field(default_factory=dict)
    source: str = "native"
    server_id: str = ""
    annotations: dict[str, Any] = field(default_factory=dict)


def map_mcp_permission(
    annotations: dict[str, Any] | None,
    *,
    configured: str | None = None,
    server_default: str | None = None,
) -> PermissionLevel:
    """Resolve an MCP tool's permission level.

    Explicit configuration wins. Otherwise the tool's own annotations decide,
    and anything that does not claim to be read-only requires approval.
    """
    for candidate in (configured, server_default):
        if candidate:
            return PermissionLevel(candidate)
    annotations = annotations or {}
    if annotations.get("readOnlyHint") is True:
        return PermissionLevel.SAFE_READ
    if annotations.get("destructiveHint") is True:
        return PermissionLevel.DESTRUCTIVE
    if annotations.get("openWorldHint") is True:
        return PermissionLevel.WRITE_EXTERNAL
    return PermissionLevel.WRITE_REVERSIBLE


def build_mcp_impact_preview(
    server_id: str,
    tool_name: str,
    level: PermissionLevel,
    annotations: dict[str, Any] | None,
) -> dict[str, Any]:
    annotations = annotations or {}
    read_only = level is PermissionLevel.SAFE_READ
    external = bool(annotations.get("openWorldHint")) or level in {
        PermissionLevel.WRITE_EXTERNAL,
        PermissionLevel.DESTRUCTIVE,
    }
    if read_only:
        reversibility = "read only"
    elif level is PermissionLevel.WRITE_REVERSIBLE:
        reversibility = "local change, revertible"
    elif level is PermissionLevel.WRITE_EXTERNAL:
        reversibility = "depends on the external system"
    elif level is PermissionLevel.DESTRUCTIVE:
        reversibility = "not guaranteed"
    else:
        reversibility = "review required"
    return {
        "route": ["gesture", "local mcp", server_id],
        "scope": f"{tool_name} on server {server_id}",
        "side_effect": (
            "read only"
            if read_only
            else ("external system change" if external else "local change")
        ),
        "reversibility": reversibility,
        "external": external,
    }


class PermissionService:
    _APPROVAL_LEVELS = {
        PermissionLevel.SENSITIVE_READ,
        PermissionLevel.WRITE_REVERSIBLE,
        PermissionLevel.WRITE_EXTERNAL,
        PermissionLevel.DESTRUCTIVE,
    }

    def may_execute(self, tool: ToolDefinition) -> bool:
        return tool.permission_level is not PermissionLevel.FORBIDDEN

    def requires_approval(self, tool: ToolDefinition) -> bool:
        return tool.permission_level in self._APPROVAL_LEVELS
