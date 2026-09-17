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
