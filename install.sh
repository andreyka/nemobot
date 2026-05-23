#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${ROOT}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT}/release.env"
fi
OPENCLAW_RELEASE="${OPENCLAW_RELEASE:-2026.5.12}"
OPENCLAW_OFFICIAL_PLUGIN_RELEASE="${OPENCLAW_OFFICIAL_PLUGIN_RELEASE:-${OPENCLAW_RELEASE}}"
OPENCLAW_OFFICIAL_CHANNEL_PLUGINS="${OPENCLAW_OFFICIAL_CHANNEL_PLUGINS:-@openclaw/slack}"
export OPENCLAW_RELEASE OPENCLAW_OFFICIAL_PLUGIN_RELEASE OPENCLAW_OFFICIAL_CHANNEL_PLUGINS
STATE_DIR="${STATE_DIR:-${ROOT}/state}"
TEMPLATE_DIR="${TEMPLATE_DIR:-${ROOT}/templates}"
CONFIG_PATH="${CONFIG_PATH:-${STATE_DIR}/openclaw.json}"
EXEC_APPROVALS_PATH="${EXEC_APPROVALS_PATH:-${STATE_DIR}/exec-approvals.json}"
WORKSPACE_DIRS_DEFAULT=(
  workspace
  workspace-communicator
  workspace-general-assistant
  workspace-vuln-researcher
  workspace-orchestrator
  workspace-researcher
  workspace-analyzer
  workspace-verifier
)
if [[ -n "${WORKSPACE_DIRS_ENV:-}" ]]; then
  read -r -a WORKSPACE_DIRS <<< "${WORKSPACE_DIRS_ENV}"
else
  WORKSPACE_DIRS=("${WORKSPACE_DIRS_DEFAULT[@]}")
fi
WORKSPACE_FILES=(AGENTS.md TOOLS.md USER.md SOUL.md HEARTBEAT.md IDENTITY.md)
MEMORY_ENV_PATH="${STATE_DIR}/memory-service.env"

REFRESH_LIVE_CONFIG=0
INIT_ONLY=0
SKIP_BROWSER=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --refresh-live-config  Snapshot config/workspace from the current nemobot pod before deploying.
  --init-state           Create local state templates and exit.
  --skip-browser         Do not deploy the isolated browser container.
  -h, --help            Show this help.

Environment variables for template rendering:
  MODEL_BACKEND
  MODEL_API_BASE_URL
  MODEL_API_MODEL_ID
  MODEL_API_MODEL_NAME
  MODEL_API_PROVIDER_ID
  MODEL_API_KEY
  OPENAI_API_KEY
  CODEX_API_KEY
  CODEX_MODEL
  OPENAI_MODEL
  MODEL_CONTEXT_WINDOW
  MODEL_MAX_TOKENS
  FRONTDOOR_MODEL_ID
  FRONTDOOR_MODEL_NAME
  FRONTDOOR_MODEL_CONTEXT_WINDOW
  FRONTDOOR_MODEL_MAX_TOKENS
  SLACK_BOT_TOKEN
  SLACK_APP_TOKEN
  ANTHROPIC_AUTH_MODE
  ANTHROPIC_SETUP_TOKEN
  ANTHROPIC_API_KEY
  ANTHROPIC_MODEL
  NVIDIA_API_KEY
  PERPLEXITY_API_KEY
  PERPLEXITY_MODEL
  MEMORY_DB_USER
  MEMORY_DB_NAME
  MEMORY_DB_PASSWORD
  GATEWAY_TOKEN
  TIMEOUT_SECONDS

Legacy compatibility aliases from older bundle revisions are still accepted.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh-live-config)
      REFRESH_LIVE_CONFIG=1
      shift
      ;;
    --init-state)
      INIT_ONLY=1
      shift
      ;;
    --skip-browser)
      SKIP_BROWSER=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "missing docker compose" >&2
    exit 1
  fi
}

detect_host_gateway_bind() {
  if [[ -n "${HOST_GATEWAY_BIND:-}" ]]; then
    printf '%s\n' "${HOST_GATEWAY_BIND}"
    return
  fi
  docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}'
}

init_state() {
  mkdir -p "${STATE_DIR}"
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    cp "${TEMPLATE_DIR}/openclaw.template.json" "${CONFIG_PATH}"
    chmod 0600 "${CONFIG_PATH}"
  fi
  if [[ ! -f "${EXEC_APPROVALS_PATH}" ]]; then
    cp "${TEMPLATE_DIR}/exec-approvals.template.json" "${EXEC_APPROVALS_PATH}"
    chmod 0600 "${EXEC_APPROVALS_PATH}"
  fi

  for dir_name in "${WORKSPACE_DIRS[@]}"; do
    mkdir -p "${STATE_DIR}/${dir_name}"
    for name in "${WORKSPACE_FILES[@]}"; do
      if [[ ! -f "${STATE_DIR}/${dir_name}/${name}" ]]; then
        cp "${TEMPLATE_DIR}/${dir_name}/${name}" "${STATE_DIR}/${dir_name}/${name}"
      fi
    done
  done
}

ensure_memory_env() {
  if [[ -f "${MEMORY_ENV_PATH}" ]]; then
    return
  fi

  local db_user="${MEMORY_DB_USER:-openclaw_memory}"
  local db_name="${MEMORY_DB_NAME:-openclaw_memory}"
  local db_password="${MEMORY_DB_PASSWORD:-}"

  if [[ -z "${db_password}" ]]; then
    db_password="$(
      python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
    )"
  fi

  cat > "${MEMORY_ENV_PATH}" <<EOF
POSTGRES_HOST=openclaw-memory-db
POSTGRES_PORT=5432
POSTGRES_USER=${db_user}
POSTGRES_PASSWORD=${db_password}
POSTGRES_DB=${db_name}
MEMORY_PORT=9004
MEMORY_DEFAULT_LIMIT=10
EOF
  chmod 0600 "${MEMORY_ENV_PATH}"
}

has_placeholders() {
  local paths=("${CONFIG_PATH}")
  local dir_name
  for dir_name in "${WORKSPACE_DIRS[@]}"; do
    paths+=("${STATE_DIR}/${dir_name}")
  done
  grep -R "__REPLACE_" "${paths[@]}" >/dev/null 2>&1
}

require_cmd docker
require_cmd python3

init_state
ensure_memory_env

if (( INIT_ONLY )); then
  echo "initialized ${STATE_DIR}"
  echo "edit ${CONFIG_PATH} or export model API and Slack env vars, then rerun ./install.sh"
  exit 0
fi

python3 "${ROOT}/render-state.py" "${CONFIG_PATH}"

if (( SKIP_BROWSER == 0 )); then
  compose_args=(-f "${ROOT}/browser/docker-compose.yml")
  host_gateway_bind="$(detect_host_gateway_bind)"
  if [[ -f "${STATE_DIR}/nvidia-proxy.env" ]]; then
    compose_args+=(--profile nvidia-proxy)
  fi
  if [[ -f "${STATE_DIR}/anthropic-proxy.env" ]]; then
    compose_args+=(--profile anthropic-proxy)
  fi
  if [[ -f "${STATE_DIR}/perplexity-proxy.env" ]]; then
    compose_args+=(--profile perplexity-proxy)
  fi
  if [[ -f "${MEMORY_ENV_PATH}" ]]; then
    compose_args+=(--profile memory)
  fi
  HOST_GATEWAY_BIND="${host_gateway_bind}" compose_cmd "${compose_args[@]}" up -d --build
fi

if (( REFRESH_LIVE_CONFIG )); then
  "${ROOT}/apply.sh" --refresh-live-config
  exit 0
fi

if has_placeholders; then
  cat >&2 <<EOF
state contains placeholders.

Either:
1. edit ${CONFIG_PATH} manually, or
2. export MODEL_API_BASE_URL, MODEL_API_MODEL_ID, SLACK_BOT_TOKEN, and SLACK_APP_TOKEN, then rerun, or
3. rerun with --refresh-live-config against an already working nemobot.
EOF
  exit 1
fi

"${ROOT}/apply.sh"
