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


@dataclass(frozen=True, slots=True)
class Settings:
    host: str = "127.0.0.1"
    port: int = 8787
    database_path: Path = Path("data/spatial_agent.db")
    provider: str = "fake"
    anthropic_model: str = "claude-sonnet-5"
    openai_model: str = "gpt-6-astra"
    max_output_tokens: int = 1024
    max_packet_bytes: int = 1_048_576
    commands_per_minute: int = 120
    fake_chunk_delay_seconds: float = 0.015

    @classmethod
    def from_environment(cls) -> "Settings":
        load_local_environment(Path(os.getenv("SPATIAL_AGENT_ENV_FILE", ".env")))
        return cls(
            host=os.getenv("SPATIAL_AGENT_HOST", "127.0.0.1"),
            port=int(os.getenv("SPATIAL_AGENT_PORT", "8787")),
            database_path=Path(os.getenv("SPATIAL_AGENT_DB", "data/spatial_agent.db")),
            provider=os.getenv("SPATIAL_AGENT_PROVIDER", "fake").strip().lower(),
            anthropic_model=os.getenv("ANTHROPIC_MODEL", "claude-sonnet-5"),
            openai_model=os.getenv("OPENAI_MODEL", "gpt-6-astra"),
            max_output_tokens=int(os.getenv("SPATIAL_AGENT_MAX_OUTPUT_TOKENS", "1024")),
            max_packet_bytes=int(os.getenv("SPATIAL_AGENT_MAX_PACKET_BYTES", "1048576")),
            commands_per_minute=int(os.getenv("SPATIAL_AGENT_COMMANDS_PER_MINUTE", "120")),
            fake_chunk_delay_seconds=float(os.getenv("SPATIAL_AGENT_FAKE_DELAY", "0.015")),
        )

    def validate(self) -> None:
        if self.provider not in {"fake", "claude", "openai", "council"}:
            raise ValueError(
                "SPATIAL_AGENT_PROVIDER must be 'fake', 'claude', 'openai', or 'council'"
            )
        if not 1 <= self.port <= 65535:
            raise ValueError("SPATIAL_AGENT_PORT must be between 1 and 65535")
        if self.max_packet_bytes < 1024:
            raise ValueError("SPATIAL_AGENT_MAX_PACKET_BYTES must be at least 1024")
        if self.commands_per_minute < 1:
            raise ValueError("SPATIAL_AGENT_COMMANDS_PER_MINUTE must be positive")
