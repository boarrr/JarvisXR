from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import re


_ENV_KEY = re.compile(r"^[A-Z][A-Z0-9_]*$")


def load_local_environment(path: Path) -> None:
    """Load literal KEY=VALUE pairs without invoking a shell.

    Existing process variables win. This intentionally supports only the small,
    predictable subset needed by the backend; command substitution and variable
    expansion are never evaluated.
    """

    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line.removeprefix("export ").strip()
        key, separator, value = line.partition("=")
        key = key.strip()
        if not separator or not _ENV_KEY.fullmatch(key):
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        os.environ.setdefault(key, value)


LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "localhost"})


def _truthy(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _optional_path(value: str) -> Path | None:
    stripped = value.strip()
    return Path(stripped) if stripped else None


def _is_loopback(host: str) -> bool:
    normalized = host.strip().lower()
    return normalized in LOOPBACK_HOSTS or normalized.startswith("127.")


@dataclass(frozen=True, slots=True)
class Settings:
    host: str = "127.0.0.1"
    port: int = 8787
    database_path: Path = Path("data/spatial_agent.db")
    provider: str = "fake"
    anthropic_model: str = "claude-sonnet-5"
    openai_model: str = "gpt-6-astra"
    deepseek_model: str = "deepseek-chat"
    opencode_url: str = "http://127.0.0.1:4096"
    opencode_password: str = ""
    opencode_username: str = "opencode"
    opencode_directory: str = ""
    opencode_model: str = ""
    test_command: str = ""
    workspace_path: str = ""
    workspace_name: str = ""
    workspace_branch: str = "main"
    max_output_tokens: int = 1024
    max_packet_bytes: int = 1_048_576
    commands_per_minute: int = 120
    fake_chunk_delay_seconds: float = 0.015
    workspaces_file: Path = Path("data/workspaces.json")
    mcp_config_path: Path = Path("data/mcp.json")
    update_manifest_path: Path = Path("../build/quest/manifest.json")
    auth_required: bool = False
    tls_certificate_path: Path | None = None
    tls_private_key_path: Path | None = None
    pairing_code_ttl_seconds: float = 600.0
    discovery_enabled: bool = True
    discovery_port: int = 8789
    shell_allowlist: tuple[str, ...] = ()

    @classmethod
    def from_environment(cls) -> "Settings":
        load_local_environment(Path(os.getenv("SPATIAL_AGENT_ENV_FILE", ".env")))
        allowlist = tuple(
            item.strip()
            for item in os.getenv("SPATIAL_AGENT_SHELL_ALLOWLIST", "").split(",")
            if item.strip()
        )
        return cls(
            host=os.getenv("SPATIAL_AGENT_HOST", "127.0.0.1"),
            port=int(os.getenv("SPATIAL_AGENT_PORT", "8787")),
            database_path=Path(os.getenv("SPATIAL_AGENT_DB", "data/spatial_agent.db")),
            provider=os.getenv("SPATIAL_AGENT_PROVIDER", "fake").strip().lower(),
            anthropic_model=os.getenv("ANTHROPIC_MODEL", "claude-sonnet-5"),
            openai_model=os.getenv("OPENAI_MODEL", "gpt-6-astra"),
            deepseek_model=os.getenv("DEEPSEEK_MODEL", "deepseek-chat"),
            opencode_url=os.getenv("SPATIAL_AGENT_OPENCODE_URL", "http://127.0.0.1:4096"),
            opencode_password=os.getenv("SPATIAL_AGENT_OPENCODE_PASSWORD", ""),
            opencode_username=os.getenv("SPATIAL_AGENT_OPENCODE_USERNAME", "opencode"),
            opencode_directory=os.getenv("SPATIAL_AGENT_OPENCODE_DIR", ""),
            opencode_model=os.getenv("SPATIAL_AGENT_OPENCODE_MODEL", ""),
            test_command=os.getenv("SPATIAL_AGENT_TEST_COMMAND", ""),
            workspace_path=os.getenv("SPATIAL_AGENT_WORKSPACE_PATH", ""),
            workspace_name=os.getenv("SPATIAL_AGENT_WORKSPACE_NAME", ""),
            workspace_branch=os.getenv("SPATIAL_AGENT_WORKSPACE_BRANCH", "main"),
            max_output_tokens=int(os.getenv("SPATIAL_AGENT_MAX_OUTPUT_TOKENS", "1024")),
            max_packet_bytes=int(os.getenv("SPATIAL_AGENT_MAX_PACKET_BYTES", "1048576")),
            commands_per_minute=int(os.getenv("SPATIAL_AGENT_COMMANDS_PER_MINUTE", "120")),
            fake_chunk_delay_seconds=float(os.getenv("SPATIAL_AGENT_FAKE_DELAY", "0.015")),
            workspaces_file=Path(os.getenv("SPATIAL_AGENT_WORKSPACES_FILE", "data/workspaces.json")),
            mcp_config_path=Path(os.getenv("SPATIAL_AGENT_MCP_CONFIG", "data/mcp.json")),
            update_manifest_path=Path(
                os.getenv(
                    "SPATIAL_AGENT_UPDATE_MANIFEST",
                    str(Path(__file__).resolve().parents[3] / "build" / "quest" / "manifest.json"),
                )
            ),
            auth_required=_truthy(os.getenv("SPATIAL_AGENT_AUTH_REQUIRED", "0")),
            tls_certificate_path=_optional_path(os.getenv("SPATIAL_AGENT_TLS_CERT", "")),
            tls_private_key_path=_optional_path(os.getenv("SPATIAL_AGENT_TLS_KEY", "")),
            pairing_code_ttl_seconds=float(
                os.getenv("SPATIAL_AGENT_PAIRING_TTL_SECONDS", "600")
            ),
            discovery_enabled=_truthy(os.getenv("SPATIAL_AGENT_DISCOVERY", "1")),
            discovery_port=int(os.getenv("SPATIAL_AGENT_DISCOVERY_PORT", "8789")),
            shell_allowlist=allowlist,
        )

    def validate(self) -> None:
        if self.provider not in {"fake", "claude", "openai", "deepseek", "council", "opencode"}:
            raise ValueError(
                "SPATIAL_AGENT_PROVIDER must be 'fake', 'claude', 'openai', "
                "'deepseek', or 'council'"
            )
        if not 1 <= self.port <= 65535:
            raise ValueError("SPATIAL_AGENT_PORT must be between 1 and 65535")
        if self.max_packet_bytes < 1024:
            raise ValueError("SPATIAL_AGENT_MAX_PACKET_BYTES must be at least 1024")
        if self.commands_per_minute < 1:
            raise ValueError("SPATIAL_AGENT_COMMANDS_PER_MINUTE must be positive")
        if (self.tls_certificate_path is None) != (self.tls_private_key_path is None):
            raise ValueError(
                "SPATIAL_AGENT_TLS_CERT and SPATIAL_AGENT_TLS_KEY must be set together"
            )
        if self.pairing_code_ttl_seconds < 30:
            raise ValueError("SPATIAL_AGENT_PAIRING_TTL_SECONDS must be at least 30")
        if not 1 <= self.discovery_port <= 65535:
            raise ValueError("SPATIAL_AGENT_DISCOVERY_PORT must be between 1 and 65535")
        if not _is_loopback(self.host):
            if not self.auth_required:
                raise ValueError(
                    "Refusing to bind a non-loopback host without "
                    "SPATIAL_AGENT_AUTH_REQUIRED=1"
                )
            if self.tls_certificate_path is None:
                raise ValueError(
                    "Refusing to bind a non-loopback host without TLS; set "
                    "SPATIAL_AGENT_TLS_CERT and SPATIAL_AGENT_TLS_KEY"
                )
