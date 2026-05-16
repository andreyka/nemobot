"""Unit tests for render-state.py."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_script_utils import load_script


class RenderStateTest(unittest.TestCase):
    """Covers the pure transformation logic in render-state.py."""

    def test_sanitize_provider_id_uses_host_and_port(self) -> None:
        module = load_script("render-state.py")

        provider_id = module.sanitize_provider_id("https://model.example.internal:9002/v1")

        self.assertEqual(provider_id, "custom-model-example-internal-9002")

    def test_main_renders_native_anthropic_config_and_writes_auth_env(self) -> None:
        module = load_script("render-state.py")

        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "openclaw.json"
            state_path.write_text(
                json.dumps(
                    {
                        "models": {
                            "providers": {
                                "anthropic": {
                                    "api": "openai-completions",
                                    "baseUrl": "__REPLACE_MODEL_API_BASE_URL__",
                                    "apiKey": "__REPLACE_OR_USE_DEFAULT_API_KEY__",
                                    "models": [{"id": "__REPLACE_MODEL_API_MODEL_ID__"}],
                                }
                            }
                        },
                        "agents": {
                            "defaults": {
                                "model": {"primary": "__REPLACE_PROVIDER_ID__/__REPLACE_MODEL_API_MODEL_ID__"}
                            },
                            "list": [
                                {"id": "communicator"},
                                {"id": "general_assistant"},
                                {"id": "vuln_researcher"},
                            ],
                        },
                        "gateway": {"auth": {"token": "__REPLACE_GATEWAY_TOKEN__"}},
                    }
                )
            )

            env_updates = {
                "ANTHROPIC_AUTH_MODE": "api-key",
                "ANTHROPIC_API_KEY": "sk-ant-test",
                "ANTHROPIC_MODEL": "claude-opus-4-7",
                "SLACK_BOT_TOKEN": "xoxb-test",
                "SLACK_APP_TOKEN": "xapp-test",
            }
            with mock.patch.dict(os.environ, env_updates, clear=False):
                with mock.patch("sys.argv", ["render-state.py", str(state_path)]):
                    self.assertEqual(module.main(), 0)

            rendered = json.loads(state_path.read_text())
            self.assertEqual(
                rendered["agents"]["defaults"]["model"]["primary"],
                "anthropic/claude-opus-4-7",
            )
            self.assertEqual(
                rendered["agents"]["defaults"]["subagents"]["model"],
                "anthropic/claude-opus-4-7",
            )
            self.assertNotIn("anthropic", rendered.get("models", {}).get("providers", {}))

            runtime_env = (Path(temp_dir) / "runtime.env").read_text()
            self.assertIn("SLACK_APP_TOKEN=xapp-test", runtime_env)
            self.assertIn("SLACK_BOT_TOKEN=xoxb-test", runtime_env)

            model_auth_env = (Path(temp_dir) / "model-auth.env").read_text()
            self.assertIn("ANTHROPIC_API_KEY=sk-ant-test", model_auth_env)
            self.assertIn("ANTHROPIC_AUTH_MODE=api-key", model_auth_env)


if __name__ == "__main__":
    unittest.main()
