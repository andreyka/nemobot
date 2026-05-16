#!/usr/bin/env python3
"""Render the worker OpenClaw state from the frontdoor configuration."""

import json
import os
import secrets
import sys
from pathlib import Path


def replace_placeholders(node, mapping: dict[str, str]):
    """Recursively replace placeholder strings in a JSON-like object."""

    if isinstance(node, str):
        for old, new in mapping.items():
            node = node.replace(old, new)
        return node
    if isinstance(node, list):
        return [replace_placeholders(item, mapping) for item in node]
    if isinstance(node, dict):
        replaced = {}
        for key, value in node.items():
            replaced[replace_placeholders(key, mapping)] = replace_placeholders(value, mapping)
        return replaced
    return node


def load_json(path: Path) -> dict:
    """Load a JSON object from disk."""

    return json.loads(path.read_text())


def prune_placeholders(node):
    """Drop unresolved placeholder fields from a JSON-like object."""

    if isinstance(node, dict):
        cleaned = {}
        for key, value in node.items():
            if isinstance(key, str) and "__REPLACE_" in key:
                continue
            cleaned_value = prune_placeholders(value)
            if isinstance(cleaned_value, str) and "__REPLACE_" in cleaned_value:
                continue
            cleaned[key] = cleaned_value
        return cleaned
    if isinstance(node, list):
        cleaned = []
        for item in node:
            cleaned_item = prune_placeholders(item)
            if isinstance(cleaned_item, str) and "__REPLACE_" in cleaned_item:
                continue
            cleaned.append(cleaned_item)
        return cleaned
    return node


def provider_and_model(source: dict) -> tuple[str, dict | None, dict]:
    """Resolve the effective primary provider and model from frontdoor state."""

    providers = source.get("models", {}).get("providers", {})
    defaults_primary = source.get("agents", {}).get("defaults", {}).get("model", {}).get("primary")
    builtin_provider_ids = {
        "anthropic",
        "openai",
        "openrouter",
        "google",
        "google-vertex",
        "anthropic-vertex",
    }

    if defaults_primary:
        provider_id, model_id = defaults_primary.split("/", 1)
    else:
        provider_id = ""
        model_id = ""

    provider = providers.get(provider_id)
    if not provider:
        if provider_id in builtin_provider_ids:
            return provider_id, None, {"id": model_id, "name": model_id}
        for candidate_id, candidate in providers.items():
            provider_id = candidate_id
            provider = candidate
            model_id = candidate.get("models", [{}])[0].get("id", "")
            break
    elif provider_id in builtin_provider_ids and "baseUrl" not in provider:
        model = next((item for item in provider.get("models", []) if item.get("id") == model_id), None)
        if model is None:
            model = provider.get("models", [{}])[0]
        if not model:
            raise SystemExit("selected provider has no models")
        return provider_id, provider, model

    if not provider:
        raise SystemExit("frontdoor config does not contain a non-cloud primary provider")

    model = next((item for item in provider.get("models", []) if item.get("id") == model_id), None)
    if model is None:
        model = provider.get("models", [{}])[0]
    if not model:
        raise SystemExit("selected provider has no models")
    return provider_id, provider, model


def ensure_model(
    rendered: dict,
    primary: str,
    base_model: dict,
    fallback_name: str | None = None,
) -> str:
    """Ensure the referenced model exists under its provider definition."""

    provider_id, _, model_id = primary.partition("/")
    if not provider_id or not model_id:
        return primary

    provider = rendered.setdefault("models", {}).setdefault("providers", {}).get(provider_id)
    if not provider:
        return primary

    models = provider.setdefault("models", [])
    for item in models:
        if item.get("id") == model_id:
            return primary

    models.append(
        {
            "id": model_id,
            "name": fallback_name or model_id,
            "reasoning": False,
            "input": ["text"],
            "cost": {
                "input": 0,
                "output": 0,
                "cacheRead": 0,
                "cacheWrite": 0,
            },
            "contextWindow": base_model.get("contextWindow", 131072),
            "maxTokens": base_model.get("maxTokens", 4096),
        }
    )
    return primary


def is_worker_config(existing: dict) -> bool:
    """Return True when the current output file already looks like worker state."""

    agent_ids = {agent.get("id") for agent in existing.get("agents", {}).get("list", [])}
    return {"researcher", "analyzer", "verifier"}.issubset(agent_ids) and not existing.get(
        "channels", {}
    ).get("slack", {}).get("enabled", False)


def gateway_token(existing: dict) -> str:
    """Preserve a worker gateway token when rerendering an existing worker state."""

    current = existing.get("gateway", {}).get("auth", {}).get("token")
    if current and "__REPLACE_" not in current and is_worker_config(existing):
        return current
    return secrets.token_hex(24)


def main() -> int:
    """Render the worker state file in place."""

    if len(sys.argv) != 4:
        print(
            "usage: render-worker-state.py <frontdoor-openclaw.json> "
            "<worker-template.json> <worker-openclaw.json>",
            file=sys.stderr,
        )
        return 2

    source_path = Path(sys.argv[1])
    template_path = Path(sys.argv[2])
    output_path = Path(sys.argv[3])

    source = load_json(source_path)
    template = load_json(template_path)
    existing = load_json(output_path) if output_path.exists() and output_path.stat().st_size else {}

    local_provider_id, local_provider, local_model = provider_and_model(source)
    local_primary = f"{local_provider_id}/{local_model['id']}"
    code_model_id = os.environ.get("WORKER_CODE_MODEL_ID", local_model["id"]).strip()
    code_primary = local_primary
    if code_model_id and local_provider is not None:
        code_primary = ensure_model(
            template,
            f"{local_provider_id}/{code_model_id}",
            local_model,
            fallback_name=code_model_id,
        )
    elif code_model_id:
        code_primary = f"{local_provider_id}/{code_model_id}"

    if local_provider is not None and "baseUrl" in local_provider:
        rendered = replace_placeholders(
            template,
            {
                "__REPLACE_PROVIDER_ID__": local_provider_id,
                "__REPLACE_MODEL_API_BASE_URL__": local_provider["baseUrl"],
                "__REPLACE_OR_USE_DEFAULT_API_KEY__": local_provider.get("apiKey", "openshell-managed"),
                "__REPLACE_MODEL_API_MODEL_ID__": local_model["id"],
                "__REPLACE_MODEL_API_MODEL_NAME__": local_model.get("name", local_model["id"]),
            },
        )
        rendered.setdefault("models", {}).setdefault("providers", {})[local_provider_id] = local_provider
    elif local_provider is not None:
        rendered = prune_placeholders(template)
        rendered.setdefault("models", {}).setdefault("providers", {})[local_provider_id] = local_provider
    else:
        rendered = prune_placeholders(template)

    defaults = rendered.setdefault("agents", {}).setdefault("defaults", {})
    source_defaults = source.get("agents", {}).get("defaults", {})
    defaults.setdefault("model", {})["primary"] = local_primary
    defaults.setdefault("models", {})[local_primary] = source_defaults.get("models", {}).get(local_primary, {})
    defaults.setdefault("models", {})[code_primary] = source_defaults.get("models", {}).get(code_primary, {})
    source_compaction_model = source_defaults.get("compaction", {}).get("model")
    if source_compaction_model:
        defaults.setdefault("compaction", {})["model"] = source_compaction_model
        defaults.setdefault("models", {})[source_compaction_model] = source_defaults.get(
            "models", {}
        ).get(source_compaction_model, {})
    source_subagent_model = source_defaults.get("subagents", {}).get("model")
    if source_subagent_model:
        defaults.setdefault("subagents", {})["model"] = source_subagent_model
        defaults.setdefault("models", {})[source_subagent_model] = source_defaults.get(
            "models", {}
        ).get(source_subagent_model, {})
    source_cli_backends = source_defaults.get("cliBackends")
    if source_cli_backends:
        defaults["cliBackends"] = source_cli_backends
    defaults["timeoutSeconds"] = source_defaults.get("timeoutSeconds", defaults.get("timeoutSeconds", 2400))

    source_search = source.get("tools", {}).get("web", {}).get("search")
    if source_search:
        rendered.setdefault("tools", {}).setdefault("web", {})["search"] = source_search
        rendered["tools"]["web"]["search"].pop("perplexity", None)

    source_perplexity = (
        source.get("plugins", {})
        .get("entries", {})
        .get("perplexity")
    )
    if source_perplexity:
        rendered.setdefault("plugins", {}).setdefault("entries", {})["perplexity"] = source_perplexity

    source_browser = source.get("browser")
    if source_browser:
        rendered["browser"] = source_browser

    for agent in rendered.get("agents", {}).get("list", []):
        if agent.get("id") == "researcher":
            agent.setdefault("model", {})["primary"] = local_primary
        elif agent.get("id") in {"analyzer", "verifier"}:
            agent.setdefault("model", {})["primary"] = code_primary

    rendered.setdefault("channels", {}).setdefault("slack", {})["enabled"] = False
    rendered.setdefault("plugins", {}).setdefault("entries", {}).setdefault("slack", {})["enabled"] = False
    rendered.setdefault("gateway", {}).setdefault("auth", {})["token"] = gateway_token(existing)

    session_cfg = rendered.get("session")
    if isinstance(session_cfg, dict):
        session_cfg.pop("parentForkMaxTokens", None)

    defaults_primary = rendered.get("agents", {}).get("defaults", {}).get("model", {}).get("primary", "")
    if isinstance(defaults_primary, str) and defaults_primary.startswith("anthropic/"):
        provider_cfg = rendered.get("models", {}).get("providers", {}).get("anthropic")
        if isinstance(provider_cfg, dict) and not provider_cfg.get("baseUrl"):
            rendered["models"]["providers"].pop("anthropic", None)

    output_path.write_text(json.dumps(rendered, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
