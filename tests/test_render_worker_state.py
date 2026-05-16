"""Unit tests for arm-worker/render-worker-state.py."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_script_utils import load_script


class RenderWorkerStateTest(unittest.TestCase):
    """Covers worker-state rendering and model inheritance logic."""

    def test_provider_and_model_supports_builtin_anthropic_provider(self) -> None:
        module = load_script("arm-worker/render-worker-state.py")
        source = {
            "models": {
                "providers": {
                    "anthropic": {
                        "models": [{"id": "claude-opus-4-7", "name": "Claude Opus"}]
                    }
                }
            },
            "agents": {"defaults": {"model": {"primary": "anthropic/claude-opus-4-7"}}},
        }

        provider_id, provider, model = module.provider_and_model(source)

        self.assertEqual(provider_id, "anthropic")
        self.assertIsNotNone(provider)
        self.assertEqual(model["id"], "claude-opus-4-7")

    def test_main_renders_worker_state_and_disables_slack(self) -> None:
        module = load_script("arm-worker/render-worker-state.py")

        with tempfile.TemporaryDirectory() as temp_dir:
            frontdoor_path = Path(temp_dir) / "frontdoor.json"
            template_path = Path(temp_dir) / "worker-template.json"
            output_path = Path(temp_dir) / "worker-openclaw.json"

            frontdoor_path.write_text(
                json.dumps(
                    {
                        "models": {
                            "providers": {
                                "anthropic": {
                                    "models": [
                                        {
                                            "id": "claude-opus-4-7",
                                            "name": "Claude Opus",
                                            "contextWindow": 1048576,
                                            "maxTokens": 32000,
                                        }
                                    ]
                                }
                            }
                        },
                        "agents": {
                            "defaults": {
                                "model": {"primary": "anthropic/claude-opus-4-7"},
                                "models": {"anthropic/claude-opus-4-7": {}},
                                "subagents": {"model": "anthropic/claude-opus-4-7"},
                                "compaction": {"model": "anthropic/claude-opus-4-7"},
                                "timeoutSeconds": 1200,
                            }
                        },
                    }
                )
            )
            template_path.write_text(
                json.dumps(
                    {
                        "models": {"providers": {"anthropic": {"models": []}}},
                        "agents": {
                            "defaults": {"model": {"primary": "anthropic/claude-opus-4-7"}},
                            "list": [
                                {"id": "researcher"},
                                {"id": "analyzer"},
                                {"id": "verifier"},
                            ],
                        },
                        "channels": {"slack": {"enabled": True}},
                        "plugins": {"entries": {"slack": {"enabled": True}}},
                        "gateway": {"auth": {"token": "__REPLACE_GATEWAY_TOKEN__"}},
                    }
                )
            )
            output_path.write_text("{}")

            with mock.patch.dict(
                os.environ, {"WORKER_CODE_MODEL_ID": "claude-sonnet-4-6"}, clear=False
            ):
                with mock.patch(
                    "sys.argv",
                    [
                        "render-worker-state.py",
                        str(frontdoor_path),
                        str(template_path),
                        str(output_path),
                    ],
                ):
                    self.assertEqual(module.main(), 0)

            rendered = json.loads(output_path.read_text())
            self.assertFalse(rendered["channels"]["slack"]["enabled"])
            self.assertFalse(rendered["plugins"]["entries"]["slack"]["enabled"])
            self.assertEqual(
                rendered["agents"]["defaults"]["subagents"]["model"],
                "anthropic/claude-opus-4-7",
            )
            self.assertEqual(
                rendered["agents"]["defaults"]["compaction"]["model"],
                "anthropic/claude-opus-4-7",
            )

            agent_models = {
                agent["id"]: agent["model"]["primary"]
                for agent in rendered["agents"]["list"]
            }
            self.assertEqual(agent_models["researcher"], "anthropic/claude-opus-4-7")
            self.assertEqual(agent_models["analyzer"], "anthropic/claude-sonnet-4-6")
            self.assertEqual(agent_models["verifier"], "anthropic/claude-sonnet-4-6")


if __name__ == "__main__":
    unittest.main()
