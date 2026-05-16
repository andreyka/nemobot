#!/usr/bin/env python3
"""Import Anthropic auth material into an OpenClaw state directory."""

import json
import os
import shutil
import sys
from pathlib import Path


CONFIG_PATH = Path(os.environ.get("OPENCLAW_CONFIG_PATH", "/root/.openclaw/openclaw.json"))
STATE_DIR = CONFIG_PATH.parent
PROFILE_ID = "anthropic:manual"


def log(message: str) -> None:
    """Write a prefixed message to stderr."""

    print(f"[openclaw-anthropic-auth] {message}", file=sys.stderr)


def normalize_shell_export_value(value: str | None) -> str:
    """Trim common shell-quoted wrapper forms from env-file values."""

    value = (value or "").strip()
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


def load_config() -> dict:
    """Load the current OpenClaw config file if it exists."""

    if not CONFIG_PATH.exists():
        return {}
    try:
        return json.loads(CONFIG_PATH.read_text())
    except Exception as exc:
        log(f"could not parse {CONFIG_PATH}: {exc}")
        return {}


def anthropic_in_use(config: dict) -> bool:
    """Return True when any agent primary model uses the Anthropic provider."""

    defaults_primary = (
        config.get("agents", {})
        .get("defaults", {})
        .get("model", {})
        .get("primary", "")
    )
    if isinstance(defaults_primary, str) and defaults_primary.startswith("anthropic/"):
        return True
    for agent in config.get("agents", {}).get("list", []):
        primary = agent.get("model", {}).get("primary", "")
        if isinstance(primary, str) and primary.startswith("anthropic/"):
            return True
    return False


def anthropic_auth_mode() -> str:
    """Resolve the requested Anthropic auth mode from the environment."""

    mode = os.environ.get("ANTHROPIC_AUTH_MODE", "").strip()
    if mode:
        return mode
    if os.environ.get("ANTHROPIC_SETUP_TOKEN", "").strip():
        return "setup-token"
    if os.environ.get("ANTHROPIC_API_KEY", "").strip():
        return "api-key"
    return ""


def save_json(path: Path, payload: dict) -> None:
    """Save a JSON file with restrictive permissions."""

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n")
    path.chmod(0o600)


def resolve_agent_ids(config: dict) -> list[str]:
    """Return every agent state directory that needs auth profiles."""

    agent_ids = {"main"}
    for agent in config.get("agents", {}).get("list", []):
        agent_id = str(agent.get("id", "")).strip()
        if agent_id:
            agent_ids.add(agent_id)
    return sorted(agent_ids)


def upsert_auth_config(config: dict) -> bool:
    """Ensure the Anthropic auth profile is enabled in the config document."""

    auth = config.setdefault("auth", {})
    profiles = auth.setdefault("profiles", {})
    order = auth.setdefault("order", {})
    changed = False

    desired_profile = {
        "provider": "anthropic",
        "mode": "token",
    }
    if profiles.get(PROFILE_ID) != desired_profile:
        profiles[PROFILE_ID] = desired_profile
        changed = True

    desired_order = [PROFILE_ID]
    if order.get("anthropic") != desired_order:
        order["anthropic"] = desired_order
        changed = True

    return changed


def write_auth_profiles(config: dict, token: str) -> None:
    """Write the token-backed Anthropic profile for each agent state dir."""

    store = {
        "version": 1,
        "profiles": {
            PROFILE_ID: {
                "type": "token",
                "provider": "anthropic",
                "token": token,
            }
        },
    }
    for agent_id in resolve_agent_ids(config):
        auth_store_path = STATE_DIR / "agents" / agent_id / "agent" / "auth-profiles.json"
        save_json(auth_store_path, store)


def import_setup_token(config: dict, token: str) -> None:
    """Persist a setup token into the local OpenClaw auth store."""

    if upsert_auth_config(config):
        save_json(CONFIG_PATH, config)
    write_auth_profiles(config, token)


def main() -> int:
    """Import Anthropic auth when the runtime is configured to use it."""

    config = load_config()
    if not anthropic_in_use(config):
        return 0

    mode = anthropic_auth_mode()
    if mode in {"", "api-key"}:
        return 0

    if mode == "claude-cli":
        if not shutil.which("claude"):
            log(
                "Anthropic model is configured for claude-cli runtime, but "
                "`claude` is not installed in this image."
            )
            return 1
        return 0

    if mode != "setup-token":
        log(f"unsupported ANTHROPIC_AUTH_MODE={mode!r}")
        return 1

    token = normalize_shell_export_value(os.environ.get("ANTHROPIC_SETUP_TOKEN", ""))
    if not token:
        log("ANTHROPIC_SETUP_TOKEN is required for setup-token auth mode")
        return 1

    log("importing Anthropic setup-token into the local OpenClaw auth store")
    import_setup_token(config, token)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
