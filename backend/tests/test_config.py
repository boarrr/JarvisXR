from __future__ import annotations

import os
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from spatial_agent_backend.config import Settings, load_local_environment


class ConfigurationTests(unittest.TestCase):
    def test_literal_env_loader_never_expands_shell_syntax(self) -> None:
        with TemporaryDirectory() as directory:
            env_path = Path(directory) / ".env"
            env_path.write_text(
                "SPATIAL_AGENT_PROVIDER=openai\n"
                "OPENAI_API_KEY='literal-$(must-not-run)'\n"
                "OPENAI_MODEL=gpt-test\n",
                encoding="utf-8",
            )
            with patch.dict(os.environ, {}, clear=True):
                load_local_environment(env_path)
                self.assertEqual(os.environ["OPENAI_API_KEY"], "literal-$(must-not-run)")
                self.assertEqual(Settings.from_environment().provider, "openai")
                self.assertEqual(Settings.from_environment().openai_model, "gpt-test")

    def test_process_environment_wins_over_env_file(self) -> None:
        with TemporaryDirectory() as directory:
            env_path = Path(directory) / ".env"
            env_path.write_text("SPATIAL_AGENT_PROVIDER=claude\n", encoding="utf-8")
            with patch.dict(
                os.environ,
                {
                    "SPATIAL_AGENT_ENV_FILE": str(env_path),
                    "SPATIAL_AGENT_PROVIDER": "fake",
                },
                clear=True,
            ):
                self.assertEqual(Settings.from_environment().provider, "fake")

    def test_all_supported_providers_validate(self) -> None:
        for provider in ("fake", "claude", "openai", "deepseek", "council"):
            Settings(provider=provider).validate()

    def test_non_loopback_bind_requires_auth_and_tls(self) -> None:
        with self.assertRaises(ValueError):
            Settings(host="0.0.0.0").validate()
        with self.assertRaises(ValueError):
            Settings(host="0.0.0.0", auth_required=True).validate()
        Settings(
            host="0.0.0.0",
            auth_required=True,
            tls_certificate_path=Path("cert.pem"),
            tls_private_key_path=Path("key.pem"),
        ).validate()
        with self.assertRaises(ValueError):
            Settings(tls_certificate_path=Path("cert.pem")).validate()

    def test_pairing_ttl_is_bounded(self) -> None:
        with self.assertRaises(ValueError):
            Settings(pairing_code_ttl_seconds=5.0).validate()


if __name__ == "__main__":
    unittest.main()
