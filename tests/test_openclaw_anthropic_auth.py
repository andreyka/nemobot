"""Unit tests for openclaw-anthropic-auth.py."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_script_utils import load_script


class OpenClawAnthropicAuthTest(unittest.TestCase):
    """Covers setup-token auth import behavior."""

    def test_anthropic_in_use_detects_agent_models(self) -> None:
        module = load_script("openclaw-anthropic-auth.py")
        config = {
            "agents": {
                "defaults": {"model": {"primary": "openai/gpt-5"}},
                "list": [{"id": "communicator", "model": {"primary": "anthropic/claude-opus-4-7"}}],
            }
        }

        self.assertTrue(module.anthropic_in_use(config))

    def test_main_imports_setup_token_into_agent_state_dirs(self) -> None:
        module = load_script("openclaw-anthropic-auth.py")

        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = Path(temp_dir) / "openclaw.json"
            config_path.write_text(
                json.dumps(
                    {
                        "agents": {
                            "defaults": {"model": {"primary": "anthropic/claude-opus-4-7"}},
                            "list": [{"id": "communicator"}, {"id": "vuln_researcher"}],
                        }
                    }
                )
            )

            module.CONFIG_PATH = config_path
            module.STATE_DIR = config_path.parent

            env_updates = {
                "ANTHROPIC_AUTH_MODE": "setup-token",
                "ANTHROPIC_SETUP_TOKEN": "setup-token-value",
            }
            with mock.patch.dict(os.environ, env_updates, clear=False):
                self.assertEqual(module.main(), 0)

            updated_config = json.loads(config_path.read_text())
            self.assertEqual(
                updated_config["auth"]["order"]["anthropic"],
                [module.PROFILE_ID],
            )

            for agent_id in ("main", "communicator", "vuln_researcher"):
                auth_profile_path = (
                    config_path.parent
                    / "agents"
                    / agent_id
                    / "agent"
                    / "auth-profiles.json"
                )
                auth_profiles = json.loads(auth_profile_path.read_text())
                self.assertEqual(
                    auth_profiles["profiles"][module.PROFILE_ID]["token"],
                    "setup-token-value",
                )


if __name__ == "__main__":
    unittest.main()
