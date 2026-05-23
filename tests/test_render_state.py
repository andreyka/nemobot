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
                "ANTHROPIC_API_KEY": "dummy-anthropic-key",
                "ANTHROPIC_MODEL": "claude-opus-4-7",
                "SLACK_BOT_TOKEN": "dummy-slack-bot-token",
                "SLACK_APP_TOKEN": "dummy-slack-app-token",
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
            self.assertIn("SLACK_APP_TOKEN=dummy-slack-app-token", runtime_env)
            self.assertIn("SLACK_BOT_TOKEN=dummy-slack-bot-token", runtime_env)

            model_auth_env = (Path(temp_dir) / "model-auth.env").read_text()
            self.assertIn("ANTHROPIC_API_KEY=dummy-anthropic-key", model_auth_env)
            self.assertIn("ANTHROPIC_AUTH_MODE=api-key", model_auth_env)

    def test_main_renders_openai_codex_config_and_writes_auth_env(self) -> None:
        module = load_script("render-state.py")

        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "openclaw.json"
            state_path.write_text(
                json.dumps(
                    {
                        "models": {
                            "providers": {
                                "__REPLACE_PROVIDER_ID__": {
                                    "api": "openai-completions",
                                    "baseUrl": "__REPLACE_MODEL_API_BASE_URL__",
                                    "apiKey": "__REPLACE_OR_USE_DEFAULT_API_KEY__",
                                    "models": [
                                        {
                                            "id": "__REPLACE_MODEL_API_MODEL_ID__",
                                            "name": "__REPLACE_MODEL_API_MODEL_NAME__",
                                        }
                                    ],
                                }
                            }
                        },
                        "agents": {
                            "defaults": {
                                "model": {
                                    "primary": "__REPLACE_PROVIDER_ID__/__REPLACE_MODEL_API_MODEL_ID__"
                                }
                            },
                            "list": [{"id": "communicator"}, {"id": "vuln_researcher"}],
                        },
                        "gateway": {"auth": {"token": "__REPLACE_GATEWAY_TOKEN__"}},
                    }
                )
            )

            env_updates = {
                "OPENAI_API_KEY": "dummy-openai-key",
                "SLACK_BOT_TOKEN": "dummy-slack-bot-token",
                "SLACK_APP_TOKEN": "dummy-slack-app-token",
            }
            with mock.patch.dict(os.environ, env_updates, clear=True):
                with mock.patch("sys.argv", ["render-state.py", str(state_path)]):
                    self.assertEqual(module.main(), 0)

            rendered = json.loads(state_path.read_text())
            self.assertEqual(
                rendered["agents"]["defaults"]["model"]["primary"],
                "openai/gpt-5.3-codex",
            )
            self.assertEqual(
                rendered["agents"]["defaults"]["subagents"]["model"],
                "openai/gpt-5.3-codex",
            )
            provider = rendered["models"]["providers"]["openai"]
            self.assertEqual(provider["baseUrl"], "https://api.openai.com/v1")
            self.assertEqual(provider["apiKey"], "${OPENAI_API_KEY}")
            self.assertEqual(provider["models"][0]["contextWindow"], 400000)
            self.assertEqual(provider["models"][0]["maxTokens"], 32000)

            model_auth_env = (Path(temp_dir) / "model-auth.env").read_text()
            self.assertIn("OPENAI_API_KEY=dummy-openai-key", model_auth_env)

    def test_main_respects_anthropic_backend_with_persisted_codex_auth(self) -> None:
        module = load_script("render-state.py")

        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "openclaw.json"
            state_path.write_text(
                json.dumps(
                    {
                        "auth": {
                            "profiles": {
                                "openai-codex:dummy-user": {
                                    "provider": "openai-codex",
                                    "mode": "oauth",
                                }
                            }
                        },
                        "agents": {
                            "defaults": {
                                "model": {"primary": "openai-codex/gpt-5.5"},
                                "models": {"openai-codex/gpt-5.5": {}},
                            },
                            "list": [{"id": "communicator"}],
                        },
                        "gateway": {"auth": {"token": "test-token"}},
                    }
                )
            )
            (Path(temp_dir) / "openclaw-auth.tar").write_bytes(b"dummy")

            env_updates = {
                "MODEL_BACKEND": "anthropic",
                "ANTHROPIC_AUTH_MODE": "api-key",
                "ANTHROPIC_API_KEY": "dummy-anthropic-key",
                "ANTHROPIC_MODEL": "claude-opus-4-7",
            }
            with mock.patch.dict(os.environ, env_updates, clear=True):
                with mock.patch("sys.argv", ["render-state.py", str(state_path)]):
                    self.assertEqual(module.main(), 0)

            rendered = json.loads(state_path.read_text())
            self.assertEqual(
                rendered["agents"]["defaults"]["model"]["primary"],
                "anthropic/claude-opus-4-7",
            )
            self.assertEqual(
                rendered["agents"]["list"][0]["model"]["primary"],
                "anthropic/claude-opus-4-7",
            )

            model_auth_env = (Path(temp_dir) / "model-auth.env").read_text()
            self.assertIn("ANTHROPIC_API_KEY=dummy-anthropic-key", model_auth_env)

    def test_main_respects_codex_api_backend_with_persisted_codex_auth(self) -> None:
        module = load_script("render-state.py")

        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "openclaw.json"
            state_path.write_text(
                json.dumps(
                    {
                        "auth": {
                            "profiles": {
                                "openai-codex:dummy-user": {
                                    "provider": "openai-codex",
                                    "mode": "oauth",
                                }
                            }
                        },
                        "models": {
                            "providers": {
                                "__REPLACE_PROVIDER_ID__": {
                                    "api": "openai-completions",
                                    "baseUrl": "__REPLACE_MODEL_API_BASE_URL__",
                                    "apiKey": "__REPLACE_OR_USE_DEFAULT_API_KEY__",
                                    "models": [{"id": "__REPLACE_MODEL_API_MODEL_ID__"}],
                                }
                            }
                        },
                        "agents": {
                            "defaults": {
                                "model": {"primary": "openai-codex/gpt-5.5"},
                                "models": {"openai-codex/gpt-5.5": {}},
                            },
                            "list": [{"id": "communicator"}],
                        },
                        "gateway": {"auth": {"token": "test-token"}},
                    }
                )
            )
            (Path(temp_dir) / "openclaw-auth.tar").write_bytes(b"dummy")

            env_updates = {
                "MODEL_BACKEND": "codex-api",
                "OPENAI_API_KEY": "dummy-openai-key",
            }
            with mock.patch.dict(os.environ, env_updates, clear=True):
                with mock.patch("sys.argv", ["render-state.py", str(state_path)]):
                    self.assertEqual(module.main(), 0)

            rendered = json.loads(state_path.read_text())
            self.assertEqual(
                rendered["agents"]["defaults"]["model"]["primary"],
                "openai/gpt-5.3-codex",
            )
            self.assertEqual(
                rendered["models"]["providers"]["openai"]["apiKey"],
                "${OPENAI_API_KEY}",
            )

    def test_main_renders_openai_codex_oauth_profile_for_all_agents(self) -> None:
        module = load_script("render-state.py")

        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = Path(temp_dir) / "openclaw.json"
            state_path.write_text(
                json.dumps(
                    {
                        "auth": {
                            "profiles": {
                                "openai-codex:dummy-user": {
                                    "provider": "openai-codex",
                                    "mode": "oauth",
                                }
                            }
                        },
                        "agents": {
                            "defaults": {
                                "model": {"primary": "anthropic/claude-opus-4-7"},
                                "models": {"anthropic/claude-opus-4-7": {}},
                            },
                            "list": [
                                {
                                    "id": "communicator",
                                    "model": {"primary": "anthropic/claude-opus-4-7"},
                                },
                                {
                                    "id": "vuln_researcher",
                                    "model": {"primary": "anthropic/claude-opus-4-7"},
                                },
                            ],
                        },
                        "gateway": {"auth": {"token": "test-token"}},
                    }
                )
            )
            (Path(temp_dir) / "openclaw-auth.tar").write_bytes(b"dummy")
            (Path(temp_dir) / "model-auth.env").write_text(
                "ANTHROPIC_AUTH_MODE=api-key\nANTHROPIC_API_KEY=dummy-anthropic-key\n"
            )

            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch("sys.argv", ["render-state.py", str(state_path)]):
                    self.assertEqual(module.main(), 0)

            rendered = json.loads(state_path.read_text())
            self.assertEqual(
                rendered["agents"]["defaults"]["model"]["primary"],
                "openai-codex/gpt-5.5",
            )
            self.assertEqual(
                rendered["agents"]["defaults"]["subagents"]["model"],
                "openai-codex/gpt-5.5",
            )
            for agent in rendered["agents"]["list"]:
                self.assertEqual(agent["model"]["primary"], "openai-codex/gpt-5.5")
            self.assertFalse((Path(temp_dir) / "model-auth.env").exists())


if __name__ == "__main__":
    unittest.main()
