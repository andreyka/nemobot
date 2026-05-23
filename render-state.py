#!/usr/bin/env python3
"""Render the frontdoor OpenClaw state from local deployment inputs."""

import json
import os
import secrets
import sys
from pathlib import Path
from urllib.parse import urlparse

OPENAI_BASE_URL = "https://api.openai.com/v1"
DEFAULT_CODEX_MODEL = "gpt-5.3-codex"
DEFAULT_CODEX_MODEL_NAME = "GPT-5.3-Codex"
DEFAULT_CODEX_OAUTH_MODEL = "gpt-5.5"
DEFAULT_CODEX_CONTEXT_WINDOW = 400000
DEFAULT_CODEX_MAX_TOKENS = 32000
VALID_MODEL_BACKENDS = {
    "auto",
    "anthropic",
    "codex-api",
    "codex-oauth",
    "custom-openai",
}
MODEL_BACKEND_ALIASES = {
    "openai": "codex-api",
    "openai-api": "codex-api",
    "openai-codex": "codex-oauth",
    "openai-codex-oauth": "codex-oauth",
}


def sanitize_provider_id(base_url: str) -> str:
    """Build a stable provider identifier from a model API base URL."""

    parsed = urlparse(base_url)
    host = parsed.hostname or "custom-provider"
    port = parsed.port
    pieces = ["custom", host.replace(".", "-")]
    if port:
        pieces.append(str(port))
    return "-".join(pieces)


def env(name: str, default: str | None = None) -> str | None:
    """Return a non-empty environment variable value or the default."""

    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return value


def env_any(names: list[str], default: str | None = None) -> str | None:
    """Return the first non-empty environment variable among the candidates."""

    for name in names:
        value = env(name)
        if value is not None:
            return value
    return default


def normalize_model_backend(value: str | None) -> str:
    """Return a canonical model backend selector."""

    backend = (value or "auto").strip().lower()
    backend = MODEL_BACKEND_ALIASES.get(backend, backend)
    if backend not in VALID_MODEL_BACKENDS:
        valid = ", ".join(sorted(VALID_MODEL_BACKENDS))
        raise ValueError(f"invalid MODEL_BACKEND={value!r}; expected one of: {valid}")
    return backend


def model_id_for_provider(value: str | None, provider_id: str) -> str | None:
    """Accept either a bare model id or a provider/model key."""

    if value is None:
        return None
    prefix = f"{provider_id}/"
    if value.startswith(prefix):
        return value[len(prefix):]
    return value


def codex_auth_profile_id(config: dict) -> str:
    """Return the existing OpenClaw Codex auth profile id, if configured."""

    profiles = config.get("auth", {}).get("profiles", {})
    if not isinstance(profiles, dict):
        return ""
    for profile_id, profile in profiles.items():
        if isinstance(profile, dict) and profile.get("provider") == "openai-codex":
            return str(profile_id)
    return ""


def set_all_agent_models(config: dict, primary: str) -> None:
    """Pin defaults and all explicit agents to the selected primary model."""

    defaults = config.setdefault("agents", {}).setdefault("defaults", {})
    defaults.setdefault("model", {})["primary"] = primary
    defaults.setdefault("models", {})[primary] = {}
    defaults.setdefault("compaction", {})["model"] = primary
    defaults.setdefault("subagents", {})["model"] = primary
    for agent in config.setdefault("agents", {}).get("list", []):
        if isinstance(agent, dict):
            agent.setdefault("model", {})["primary"] = primary


def normalize_shell_export_value(value: str | None) -> str | None:
    """Trim common shell-quoted wrapper forms from env-file values."""

    if value is None:
        return None
    value = value.strip()
    shell_single_quote_wrapper = '\'"\'"\''
    if value.startswith(shell_single_quote_wrapper) and value.endswith(
        shell_single_quote_wrapper
    ):
        value = value[len(shell_single_quote_wrapper):-len(shell_single_quote_wrapper)]
    if len(value) >= 2 and (
        (value[0] == "'" and value[-1] == "'")
        or (value[0] == '"' and value[-1] == '"')
    ):
        value = value[1:-1]
    return value


def load_env_file(path: Path) -> dict[str, str]:
    """Load a simple KEY=VALUE env file into a dictionary."""

    data: dict[str, str] = {}
    if not path.exists():
        return data
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = normalize_shell_export_value(value) or ""
    return data


def write_env_file(path: Path, pairs: dict[str, str]) -> None:
    """Persist environment variables in a deterministic order."""

    path.write_text("".join(f"{key}={value}\n" for key, value in sorted(pairs.items())))
    path.chmod(0o600)


def needs_secret_migration(value: str | None) -> bool:
    """Return True when an inline secret should be moved into local state."""

    if not value:
        return False
    if value.startswith("${"):
        return False
    if value.startswith("__REPLACE_"):
        return False
    if value == "openshell-managed":
        return False
    return True


def is_openai_base_url(base_url: str | None) -> bool:
    """Return True when the configured endpoint is OpenAI's public API."""

    if not base_url:
        return False
    parsed = urlparse(base_url)
    return parsed.scheme in {"http", "https"} and parsed.hostname == "api.openai.com"


def replace_placeholders(node, mapping: dict[str, str]):
    """Recursively replace placeholder strings in a JSON-like object."""

    if isinstance(node, str):
        for old, new in mapping.items():
            node = node.replace(old, new)
        return node
    if isinstance(node, list):
        return [replace_placeholders(item, mapping) for item in node]
    if isinstance(node, dict):
        replaced: dict = {}
        for key, value in node.items():
            new_key = replace_placeholders(key, mapping)
            replaced[new_key] = replace_placeholders(value, mapping)
        return replaced
    return node


def prune_placeholders(node):
    """Drop unresolved placeholder fields from a JSON-like object."""

    if isinstance(node, dict):
        cleaned: dict = {}
        for key, value in node.items():
            if isinstance(key, str) and "__REPLACE_" in key:
                continue
            cleaned_value = prune_placeholders(value)
            if isinstance(cleaned_value, str) and "__REPLACE_" in cleaned_value:
                continue
            cleaned[key] = cleaned_value
        return cleaned
    if isinstance(node, list):
        cleaned_list = []
        for item in node:
            cleaned_item = prune_placeholders(item)
            if isinstance(cleaned_item, str) and "__REPLACE_" in cleaned_item:
                continue
            cleaned_list.append(cleaned_item)
        return cleaned_list
    return node


def main() -> int:
    """Render the state file in place and write any sidecar auth/env files."""

    if len(sys.argv) != 2:
        print("usage: render-state.py <state-openclaw.json>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    state_dir = path.parent
    obj = json.loads(path.read_text())

    base_url = env_any(["MODEL_API_BASE_URL", "DGX_BASE_URL"])
    model_id = env_any(["MODEL_API_MODEL_ID", "DGX_MODEL_ID"])
    model_name = env_any(["MODEL_API_MODEL_NAME", "DGX_MODEL_NAME"])
    provider_id = env_any(["MODEL_API_PROVIDER_ID", "DGX_PROVIDER_ID"])
    context_window_env = env_any(["MODEL_CONTEXT_WINDOW", "DGX_CONTEXT_WINDOW"])
    max_tokens_env = env_any(["MODEL_MAX_TOKENS", "DGX_MAX_TOKENS"])
    context_window = int(context_window_env or "1048576")
    max_tokens = int(max_tokens_env or "4096")
    timeout_seconds = int(env("TIMEOUT_SECONDS", "2400"))
    try:
        model_backend = normalize_model_backend(env("MODEL_BACKEND"))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    openai_api_key = env_any(["OPENAI_API_KEY", "CODEX_API_KEY"])
    codex_model = model_id_for_provider(env_any(["CODEX_MODEL", "OPENAI_MODEL"]), "openai-codex")
    serving_api_key = env_any(["MODEL_API_KEY", "DGX_API_KEY"])
    slack_bot = env("SLACK_BOT_TOKEN")
    slack_app = env("SLACK_APP_TOKEN")
    gateway_token = env("GATEWAY_TOKEN")
    runtime_env_path = state_dir / "runtime.env"
    runtime_env = load_env_file(runtime_env_path)
    model_auth_env_path = state_dir / "model-auth.env"
    model_auth_env = load_env_file(model_auth_env_path)
    anthropic_legacy_env = load_env_file(state_dir / "anthropic-proxy.env")
    if model_backend not in {"auto", "codex-api"}:
        openai_api_key = None
    if not openai_api_key and model_backend in {"auto", "codex-api"}:
        openai_api_key = model_auth_env.get("OPENAI_API_KEY") or model_auth_env.get(
            "CODEX_API_KEY"
        )
    existing_codex_auth_profile = codex_auth_profile_id(obj)
    codex_auth_profile = env_any(["OPENCLAW_CODEX_AUTH_PROFILE", "CODEX_AUTH_PROFILE"])
    if not codex_auth_profile:
        codex_auth_profile = existing_codex_auth_profile
    has_persisted_codex_auth = (state_dir / "openclaw-auth.tar").exists()
    if model_backend == "codex-oauth" and not (
        codex_auth_profile or has_persisted_codex_auth
    ):
        print(
            "MODEL_BACKEND=codex-oauth requires an OpenClaw Codex auth profile "
            "or state/openclaw-auth.tar",
            file=sys.stderr,
        )
        return 1
    if model_backend in {"anthropic", "codex-oauth"}:
        openai_api_key = None
        base_url = None
        model_id = None
        model_name = None
        provider_id = None
        serving_api_key = None
    if model_backend == "custom-openai":
        openai_api_key = None
    if model_backend == "codex-api":
        base_url = OPENAI_BASE_URL
        provider_id = "openai"
    use_codex_oauth = model_backend == "codex-oauth" or (
        model_backend == "auto"
        and bool(codex_auth_profile or has_persisted_codex_auth)
        and not (openai_api_key or base_url or serving_api_key)
    )
    explicit_openai_requested = bool(
        model_backend in {"codex-api", "codex-oauth", "custom-openai"}
        or (
            model_backend == "auto"
            and (
                openai_api_key
                or codex_model
                or provider_id == "openai"
                or is_openai_base_url(base_url)
                or use_codex_oauth
            )
        )
    )
    anthropic_setup_token = env("ANTHROPIC_SETUP_TOKEN")
    if not anthropic_setup_token and not explicit_openai_requested:
        anthropic_setup_token = model_auth_env.get("ANTHROPIC_SETUP_TOKEN")
    anthropic_api_key = env("ANTHROPIC_API_KEY")
    anthropic_auth_token = env("ANTHROPIC_AUTH_TOKEN")
    anthropic_auth_mode = env("ANTHROPIC_AUTH_MODE")
    anthropic_model = env("ANTHROPIC_MODEL", "claude-opus-4-7")
    frontdoor_model = env_any(["FRONTDOOR_MODEL_ID", "COMMUNICATOR_MODEL_ID"])
    frontdoor_model_name = env_any(["FRONTDOOR_MODEL_NAME", "COMMUNICATOR_MODEL_NAME"])
    frontdoor_context_window_env = env_any(
        ["FRONTDOOR_MODEL_CONTEXT_WINDOW", "COMMUNICATOR_MODEL_CONTEXT_WINDOW"]
    )
    frontdoor_max_tokens_env = env_any(
        ["FRONTDOOR_MODEL_MAX_TOKENS", "COMMUNICATOR_MODEL_MAX_TOKENS"]
    )
    perplexity_api_key = env("PERPLEXITY_API_KEY")
    perplexity_model = env("PERPLEXITY_MODEL", "sonar-pro")
    nvidia_api_key = env("NVIDIA_API_KEY")
    if not anthropic_api_key and not explicit_openai_requested:
        anthropic_api_key = model_auth_env.get("ANTHROPIC_API_KEY") or anthropic_legacy_env.get(
            "ANTHROPIC_API_KEY"
        )
    if not anthropic_auth_token and not explicit_openai_requested:
        anthropic_auth_token = model_auth_env.get(
            "ANTHROPIC_AUTH_TOKEN"
        ) or anthropic_legacy_env.get("ANTHROPIC_AUTH_TOKEN")
    if not anthropic_auth_mode and not explicit_openai_requested:
        anthropic_auth_mode = model_auth_env.get("ANTHROPIC_AUTH_MODE")
    if not anthropic_model:
        anthropic_model = model_auth_env.get("ANTHROPIC_MODEL", "claude-opus-4-7")
    if (
        "ANTHROPIC_MODEL" in anthropic_legacy_env
        and not env("ANTHROPIC_MODEL")
        and not explicit_openai_requested
    ):
        anthropic_model = anthropic_legacy_env["ANTHROPIC_MODEL"]

    if model_backend == "codex-api" and not openai_api_key:
        print(
            "MODEL_BACKEND=codex-api requires OPENAI_API_KEY or CODEX_API_KEY",
            file=sys.stderr,
        )
        return 1
    if openai_api_key and not base_url:
        base_url = OPENAI_BASE_URL
    if base_url and is_openai_base_url(base_url):
        if not provider_id:
            provider_id = "openai"
        if not model_id:
            model_id = model_id_for_provider(codex_model, "openai") or DEFAULT_CODEX_MODEL
        if not model_name:
            model_name = (
                DEFAULT_CODEX_MODEL_NAME
                if model_id == DEFAULT_CODEX_MODEL
                else model_id
            )
        if context_window_env is None:
            context_window = DEFAULT_CODEX_CONTEXT_WINDOW
        if max_tokens_env is None:
            max_tokens = DEFAULT_CODEX_MAX_TOKENS
        if not serving_api_key and openai_api_key:
            serving_api_key = "${OPENAI_API_KEY}"
    if not serving_api_key:
        serving_api_key = "openshell-managed"

    if not anthropic_auth_mode:
        if anthropic_setup_token:
            anthropic_auth_mode = "setup-token"
        elif anthropic_api_key:
            anthropic_auth_mode = "api-key"

    use_native_anthropic = anthropic_auth_mode in {"setup-token", "api-key", "claude-cli"}
    if use_codex_oauth:
        if model_auth_env_path.exists():
            model_auth_env_path.unlink()
        obj = prune_placeholders(obj)
        primary = f"openai-codex/{codex_model or DEFAULT_CODEX_OAUTH_MODEL}"
        set_all_agent_models(obj, primary)
        if codex_auth_profile:
            obj.setdefault("auth", {}).setdefault("profiles", {})[codex_auth_profile] = {
                "provider": "openai-codex",
                "mode": "oauth",
            }
        base_url = None
        model_id = None
        provider_id = None
    elif use_native_anthropic:
        native_auth_env: dict[str, str] = {
            "ANTHROPIC_AUTH_MODE": anthropic_auth_mode,
            "ANTHROPIC_MODEL": anthropic_model,
        }
        if anthropic_auth_mode == "claude-cli" and anthropic_auth_token:
            native_auth_env["ANTHROPIC_AUTH_TOKEN"] = anthropic_auth_token
            native_auth_env["NEMOBOT_ANTHROPIC_AUTH_TOKEN"] = anthropic_auth_token
            native_auth_env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        if anthropic_auth_mode == "setup-token" and anthropic_setup_token:
            native_auth_env["ANTHROPIC_SETUP_TOKEN"] = anthropic_setup_token
        if anthropic_auth_mode == "api-key" and anthropic_api_key:
            native_auth_env["ANTHROPIC_API_KEY"] = anthropic_api_key
        write_env_file(model_auth_env_path, native_auth_env)
        if context_window_env is None:
            context_window = 1048576
        if max_tokens_env is None:
            max_tokens = 32000
        obj = prune_placeholders(obj)
        obj.setdefault("models", {}).setdefault("providers", {}).pop("anthropic", None)
        defaults = obj.setdefault("agents", {}).setdefault("defaults", {})
        if anthropic_auth_mode == "claude-cli":
            defaults.setdefault("cliBackends", {})["claude-cli"] = {
                "command": "claude",
                "args": ["--verbose", "--permission-mode", "bypassPermissions"],
                "resumeArgs": ["--verbose", "--permission-mode", "bypassPermissions"],
            }
        anthropic_primary = f"anthropic/{anthropic_model}"
        set_all_agent_models(obj, anthropic_primary)
        if anthropic_auth_mode == "claude-cli":
            defaults["models"][anthropic_primary]["agentRuntime"] = {"id": "claude-cli"}
        if frontdoor_model and frontdoor_model != anthropic_model:
            frontdoor_primary = f"anthropic/{frontdoor_model}"
            defaults.setdefault("models", {})[frontdoor_primary] = {}
            if anthropic_auth_mode == "claude-cli":
                defaults["models"][frontdoor_primary]["agentRuntime"] = {
                    "id": "claude-cli"
                }
            for agent in obj.setdefault("agents", {}).get("list", []):
                if agent.get("id") in {"communicator", "general_assistant"}:
                    agent.setdefault("model", {})["primary"] = frontdoor_primary
        if (state_dir / "anthropic-proxy.env").exists():
            (state_dir / "anthropic-proxy.env").unlink()
        base_url = None
        model_id = None
        provider_id = None
    else:
        if openai_api_key:
            write_env_file(model_auth_env_path, {"OPENAI_API_KEY": openai_api_key})
        elif model_auth_env_path.exists():
            model_auth_env_path.unlink()

    if base_url and not provider_id:
        provider_id = sanitize_provider_id(base_url)
    if model_id and not model_name:
        model_name = f"{model_id} (Custom Provider)"
    if not gateway_token:
        auth = obj.get("gateway", {}).get("auth", {})
        current = auth.get("token")
        if not current or "__REPLACE_" in current:
            gateway_token = secrets.token_hex(24)

    if base_url and model_id and provider_id:
        obj = replace_placeholders(
            obj,
            {
                "__REPLACE_PROVIDER_ID__": provider_id,
                "__REPLACE_MODEL_API_BASE_URL__": base_url,
                "__REPLACE_OR_USE_DEFAULT_API_KEY__": serving_api_key,
                "__REPLACE_MODEL_API_MODEL_ID__": model_id,
                "__REPLACE_MODEL_API_MODEL_NAME__": model_name or model_id,
            },
        )
        provider_models = [
            {
                "id": model_id,
                "name": model_name or model_id,
                "reasoning": False,
                "input": ["text"],
                "cost": {
                    "input": 0,
                    "output": 0,
                    "cacheRead": 0,
                    "cacheWrite": 0,
                },
                "contextWindow": context_window,
                "maxTokens": max_tokens,
            }
        ]
        if frontdoor_model and frontdoor_model != model_id:
            frontdoor_context_window = int(frontdoor_context_window_env or str(context_window))
            frontdoor_max_tokens = int(frontdoor_max_tokens_env or str(max_tokens))
            provider_models.append(
                {
                    "id": frontdoor_model,
                    "name": frontdoor_model_name or frontdoor_model,
                    "reasoning": False,
                    "input": ["text"],
                    "cost": {
                        "input": 0,
                        "output": 0,
                        "cacheRead": 0,
                        "cacheWrite": 0,
                    },
                    "contextWindow": frontdoor_context_window,
                    "maxTokens": frontdoor_max_tokens,
                }
            )
        provider = {
            "baseUrl": base_url,
            "apiKey": serving_api_key,
            "api": "openai-completions",
            "models": provider_models,
        }
        models_obj = obj.setdefault("models", {})
        models_obj["mode"] = "merge"
        models_obj.setdefault("providers", {})[provider_id] = provider
        primary = f"{provider_id}/{model_id}"
        defaults = obj.setdefault("agents", {}).setdefault("defaults", {})
        set_all_agent_models(obj, primary)
        if frontdoor_model and frontdoor_model != model_id:
            frontdoor_primary = f"{provider_id}/{frontdoor_model}"
            defaults.setdefault("models", {})[frontdoor_primary] = {}
            for agent in obj.setdefault("agents", {}).get("list", []):
                if agent.get("id") in {"communicator", "general_assistant"}:
                    agent.setdefault("model", {})["primary"] = frontdoor_primary

    defaults = obj.setdefault("agents", {}).setdefault("defaults", {})
    defaults["timeoutSeconds"] = timeout_seconds

    auth = obj.setdefault("gateway", {}).setdefault("auth", {})
    if gateway_token:
        auth["token"] = gateway_token

    slack = obj.setdefault("channels", {}).setdefault("slack", {})
    slack_bot = slack_bot or runtime_env.get("SLACK_BOT_TOKEN") or (
        slack.get("botToken") if needs_secret_migration(slack.get("botToken")) else None
    )
    slack_app = slack_app or runtime_env.get("SLACK_APP_TOKEN") or (
        slack.get("appToken") if needs_secret_migration(slack.get("appToken")) else None
    )
    if slack_bot:
        runtime_env["SLACK_BOT_TOKEN"] = slack_bot
        slack["botToken"] = "${SLACK_BOT_TOKEN}"
    if slack_app:
        runtime_env["SLACK_APP_TOKEN"] = slack_app
        slack["appToken"] = "${SLACK_APP_TOKEN}"
    for secret_name in (
        "ANTHROPIC_AUTH_MODE",
        "ANTHROPIC_SETUP_TOKEN",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_MODEL_NAME",
    ):
        runtime_env.pop(secret_name, None)
    if runtime_env:
        write_env_file(runtime_env_path, runtime_env)
    elif runtime_env_path.exists():
        runtime_env_path.unlink()

    if nvidia_api_key:
        proxy_env_path = state_dir / "nvidia-proxy.env"
        write_env_file(proxy_env_path, {"NVIDIA_API_KEY": nvidia_api_key})
    legacy_proxy_env_path = state_dir / "proxy.env"
    if legacy_proxy_env_path.exists():
        legacy = load_env_file(legacy_proxy_env_path)
        if "NVIDIA_API_KEY" in legacy and not (state_dir / "nvidia-proxy.env").exists():
            write_env_file(
                state_dir / "nvidia-proxy.env",
                {"NVIDIA_API_KEY": legacy["NVIDIA_API_KEY"]},
            )
        legacy_proxy_env_path.unlink()

    tools = obj.setdefault("tools", {})
    web = tools.setdefault("web", {})
    search = web.setdefault("search", {})
    plugins = obj.setdefault("plugins", {}).setdefault("entries", {})
    perplexity_plugin = plugins.setdefault("perplexity", {})
    perplexity_config = perplexity_plugin.setdefault("config", {})
    web_search_config = perplexity_config.setdefault("webSearch", {})
    perplexity_api_key = (
        perplexity_api_key
        or load_env_file(state_dir / "perplexity-proxy.env").get("PERPLEXITY_API_KEY")
        or (web_search_config.get("apiKey") if needs_secret_migration(web_search_config.get("apiKey")) else None)
    )
    if perplexity_api_key:
        proxy_env_path = state_dir / "perplexity-proxy.env"
        write_env_file(proxy_env_path, {"PERPLEXITY_API_KEY": perplexity_api_key})
        search["enabled"] = True
        search["provider"] = "perplexity"
        search.setdefault("maxResults", 5)
        search.setdefault("timeoutSeconds", 30)
        search.setdefault("cacheTtlMinutes", 15)
        web_search_config["apiKey"] = "openshell-managed"
        web_search_config["baseUrl"] = "http://host.openshell.internal:9003"
        web_search_config["model"] = perplexity_model
        search.pop("perplexity", None)

    session_cfg = obj.get("session")
    if isinstance(session_cfg, dict):
        session_cfg.pop("parentForkMaxTokens", None)

    slack_cfg = obj.get("channels", {}).get("slack")
    if isinstance(slack_cfg, dict):
        streaming = slack_cfg.get("streaming")
        native_streaming = slack_cfg.pop("nativeStreaming", None)
        if isinstance(streaming, str):
            slack_cfg["streaming"] = {"mode": streaming}
            streaming = slack_cfg["streaming"]
        elif not isinstance(streaming, dict):
            slack_cfg["streaming"] = {"mode": "off"}
            streaming = slack_cfg["streaming"]
        if native_streaming is not None:
            streaming.setdefault("nativeTransport", bool(native_streaming))
        slack_cfg.pop("channels", None)

    defaults_primary = obj.get("agents", {}).get("defaults", {}).get("model", {}).get("primary", "")
    if isinstance(defaults_primary, str) and defaults_primary.startswith("anthropic/"):
        provider_cfg = obj.get("models", {}).get("providers", {}).get("anthropic")
        if isinstance(provider_cfg, dict) and not provider_cfg.get("baseUrl"):
            obj["models"]["providers"].pop("anthropic", None)

    path.write_text(json.dumps(obj, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
