#!/usr/bin/env bash
set -euo pipefail

NEMOBOT_ROOT="${NEMOBOT_ROOT:-/opt/openclaw-nemobot}"
if [[ "${NEMOBOT_ROOT}" == "/opt/openclaw-nemobot" && ! -d "${NEMOBOT_ROOT}" && -d /opt/openclaw-vulnlab ]]; then
  NEMOBOT_ROOT="/opt/openclaw-vulnlab"
fi
NEMOBOT_OPENCLAW_RELEASE="${NEMOBOT_OPENCLAW_RELEASE:-2026.5.12}"
NEMOBOT_OFFICIAL_PLUGIN_RELEASE="${NEMOBOT_OFFICIAL_PLUGIN_RELEASE:-${NEMOBOT_OPENCLAW_RELEASE}}"
NEMOBOT_CONFIG="${NEMOBOT_ROOT}/openclaw.json"
NEMOBOT_EXEC_APPROVALS="${NEMOBOT_ROOT}/exec-approvals.json"
NEMOBOT_CLAUDE_AUTH_DIR="${NEMOBOT_ROOT}/claude-auth"
NEMOBOT_OPENCLAW_AUTH_DIR="${NEMOBOT_ROOT}/openclaw-auth"
NEMOBOT_CODEX_AUTH_DIR="${NEMOBOT_ROOT}/codex-auth"
LIVE_CONFIG="/root/.openclaw/openclaw.json"
LIVE_EXEC_APPROVALS="/root/.openclaw/exec-approvals.json"
WORKSPACE_FILES=(AGENTS.md TOOLS.md USER.md SOUL.md HEARTBEAT.md IDENTITY.md)
STALE_FILES=(BOOTSTRAP.md)

mkdir -p /root/.openclaw
mkdir -p /root/.claude
chmod 0700 /root/.openclaw || true
chmod 0700 /root/.claude || true

if [[ -f "${NEMOBOT_CONFIG}" ]]; then
  install -m 0600 "${NEMOBOT_CONFIG}" "${LIVE_CONFIG}"
fi

resolve_env_placeholders() {
  local config_path="$1"
  [[ -f "${config_path}" ]] || return 0
  python3 - "${config_path}" <<'PY'
import json
import os
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
pattern = re.compile(r"^\$\{([A-Z0-9_]+)\}$")

def walk(value):
    if isinstance(value, dict):
        return {k: walk(v) for k, v in value.items()}
    if isinstance(value, list):
        return [walk(v) for v in value]
    if isinstance(value, str):
        m = pattern.fullmatch(value)
        if m:
            return os.environ.get(m.group(1), value)
    return value

path.write_text(json.dumps(walk(data), indent=2) + "\n")
PY
}

resolve_env_placeholders "${LIVE_CONFIG}"
export OPENCLAW_CONFIG_PATH="${LIVE_CONFIG}"

if [[ -f "${NEMOBOT_EXEC_APPROVALS}" ]]; then
  install -m 0600 "${NEMOBOT_EXEC_APPROVALS}" "${LIVE_EXEC_APPROVALS}"
else
  rm -f "${LIVE_EXEC_APPROVALS}"
fi

if [[ -f "${NEMOBOT_CLAUDE_AUTH_DIR}/claude.json" ]]; then
  install -m 0600 "${NEMOBOT_CLAUDE_AUTH_DIR}/claude.json" /root/.claude.json
fi
if [[ -f "${NEMOBOT_CLAUDE_AUTH_DIR}/credentials.json" ]]; then
  install -m 0600 "${NEMOBOT_CLAUDE_AUTH_DIR}/credentials.json" /root/.claude/.credentials.json
fi
if id -u sandbox >/dev/null 2>&1; then
  install -d -m 0700 -o sandbox -g sandbox /home/sandbox/.claude
  if [[ -f "${NEMOBOT_CLAUDE_AUTH_DIR}/claude.json" ]]; then
    install -m 0600 -o sandbox -g sandbox "${NEMOBOT_CLAUDE_AUTH_DIR}/claude.json" /home/sandbox/.claude.json
  fi
  if [[ -f "${NEMOBOT_CLAUDE_AUTH_DIR}/credentials.json" ]]; then
    install -m 0600 -o sandbox -g sandbox "${NEMOBOT_CLAUDE_AUTH_DIR}/credentials.json" /home/sandbox/.claude/.credentials.json
  fi
fi

restore_openclaw_auth() {
  local auth_tar="${NEMOBOT_OPENCLAW_AUTH_DIR}/openclaw-auth.tar"
  [[ -f "${auth_tar}" ]] || return 0

  mkdir -p /root/.openclaw
  tar -xf "${auth_tar}" -C /root/.openclaw
  chmod 0700 /root/.openclaw || true
  chmod -R go-rwx /root/.openclaw/credentials /root/.openclaw/agents 2>/dev/null || true
}

restore_codex_auth() {
  local auth_tar="${NEMOBOT_CODEX_AUTH_DIR}/codex-auth.tar"
  [[ -f "${auth_tar}" ]] || return 0

  mkdir -p /root/.codex
  tar -xf "${auth_tar}" -C /root/.codex
  chmod 0700 /root/.codex || true
  chmod -R go-rwx /root/.codex 2>/dev/null || true

  if id -u sandbox >/dev/null 2>&1; then
    install -d -m 0700 -o sandbox -g sandbox /home/sandbox/.codex
    cp -a /root/.codex/. /home/sandbox/.codex/
    chown -R sandbox:sandbox /home/sandbox/.codex
    chmod -R go-rwx /home/sandbox/.codex 2>/dev/null || true
  fi
}

sync_workspace() {
  local source_dir="$1"
  local live_dir="$2"

  mkdir -p "${live_dir}" "${live_dir}/memory"

  for name in "${STALE_FILES[@]}"; do
    rm -f "${live_dir}/${name}"
  done

  if [[ -d "${source_dir}" ]]; then
    for name in "${WORKSPACE_FILES[@]}"; do
      if [[ -f "${source_dir}/${name}" ]]; then
        install -m 0644 "${source_dir}/${name}" "${live_dir}/${name}"
      else
        rm -f "${live_dir}/${name}"
      fi
    done
  fi
}

for source_dir in "${NEMOBOT_ROOT}"/workspace*; do
  [[ -d "${source_dir}" ]] || continue
  sync_workspace "${source_dir}" "/root/.openclaw/$(basename "${source_dir}")"
done

mkdir -p /root/.openclaw/logs
mkdir -p /root/.openclaw/agents/main/sessions
for source_dir in "${NEMOBOT_ROOT}"/workspace-*; do
  [[ -d "${source_dir}" ]] || continue
  agent_id="$(basename "${source_dir}")"
  agent_id="${agent_id#workspace-}"
  mkdir -p "/root/.openclaw/agents/${agent_id}/sessions"
done

restore_openclaw_auth
restore_codex_auth

if [[ -f "${LIVE_CONFIG}" ]]; then
  /usr/local/bin/openclaw-anthropic-auth
fi

sync_official_slack_plugin() {
  [[ -f "${LIVE_CONFIG}" ]] || return 0

  local slack_enabled current_version
  slack_enabled="$(
    python3 - "${LIVE_CONFIG}" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit(0)

plugin_cfg = data.get("plugins", {}).get("entries", {}).get("slack", {})
channel_cfg = data.get("channels", {}).get("slack", {})
enabled = plugin_cfg.get("enabled") and channel_cfg.get("enabled", True)
print("1" if enabled else "")
PY
  )"
  [[ -n "${slack_enabled}" ]] || return 0

  current_version="$(
    python3 - <<'PY'
import json
from pathlib import Path

path = Path("/root/.openclaw/npm/node_modules/@openclaw/slack/package.json")
if not path.exists():
    print("")
    raise SystemExit(0)

try:
    print(json.loads(path.read_text()).get("version", ""))
except Exception:
    print("")
PY
  )"

  if [[ "${current_version}" == "${NEMOBOT_OFFICIAL_PLUGIN_RELEASE}" ]]; then
    return 0
  fi

  if ! openclaw plugins install "npm:@openclaw/slack@${NEMOBOT_OFFICIAL_PLUGIN_RELEASE}" \
      >/root/.openclaw/logs/slack-plugin-sync.log 2>&1; then
    if [[ -n "${current_version}" ]]; then
      echo "warning: failed to sync @openclaw/slack to ${NEMOBOT_OFFICIAL_PLUGIN_RELEASE}; keeping ${current_version}" >&2
      return 0
    fi
    echo "failed to install required @openclaw/slack@${NEMOBOT_OFFICIAL_PLUGIN_RELEASE}" >&2
    return 1
  fi
}

sync_official_slack_plugin

sync_slack_channel() {
  [[ -f "${LIVE_CONFIG}" ]] || return 0

  local slack_args
  slack_args="$(
    python3 - "${LIVE_CONFIG}" <<'PY'
import json
import shlex
import sys

path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(0)

slack = data.get("channels", {}).get("slack")
if not isinstance(slack, dict):
    sys.exit(0)
if not slack.get("enabled", True):
    sys.exit(0)

bot = slack.get("botToken")
app = slack.get("appToken")
if not bot or not app:
    sys.exit(0)

parts = [
    "--channel", "slack",
    "--account", "default",
    "--name", slack.get("name") or "slack-default",
    "--bot-token", bot,
    "--app-token", app,
]
print(" ".join(shlex.quote(part) for part in parts))
PY
  )"

  [[ -n "${slack_args}" ]] || return 0
  openclaw channels add ${slack_args} >/root/.openclaw/logs/slack-channel-sync.log 2>&1 || true
}

sync_slack_channel

gateway_running=1
if command -v ss >/dev/null 2>&1; then
  if ss -ltn '( sport = :18789 )' | grep -q 18789; then
    gateway_running=0
  fi
fi
if [[ "${gateway_running}" -ne 0 ]]; then
  nohup openclaw gateway run >/root/.openclaw/logs/gateway-startup.log 2>&1 &
  sleep 2
fi

bootstrap_openshell_sandbox() {
  local retries="${OPENSHELL_SANDBOX_BOOT_RETRIES:-120}"
  local delay_seconds="${OPENSHELL_SANDBOX_BOOT_DELAY_SECONDS:-3}"
  local attempt=1
  local sandbox_err="/tmp/openshell-sandbox.stderr"

  while true; do
    : > "${sandbox_err}"
    set +e
    /opt/openshell/bin/openshell-sandbox "$@" 2> >(tee "${sandbox_err}" >&2)
    status=$?
    set -e
    if [[ "${status}" -eq 0 ]]; then
      echo "openshell-sandbox exited successfully" >&2
      return 0
    fi
    if grep -Eq "sandbox has no spec|status: Unimplemented|failed to connect to OpenShell server|log push connect failed" "${sandbox_err}"; then
      if (( attempt < retries )); then
        echo "openshell-sandbox bootstrap not ready yet; retrying (${attempt}/${retries}) in ${delay_seconds}s" >&2
        attempt=$((attempt + 1))
        sleep "${delay_seconds}"
        continue
      fi
      echo "openshell-sandbox did not become ready after ${retries} retries; continuing without it" >&2
      return 0
    fi
    echo "openshell-sandbox exited with status ${status}; continuing without it" >&2
    return 0
  done
}

bootstrap_openshell_sandbox "$@" >/root/.openclaw/logs/openshell-sandbox.log 2>&1 &

exec sleep infinity
