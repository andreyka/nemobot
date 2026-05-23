#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKIP_BROWSER=0
SKIP_WORKER=0
SKIP_BRIDGE=0
DEPLOY_X86=0
INIT_ONLY=0

usage() {
  cat <<'EOF'
Usage: ./bootstrap.sh [options]

Interactive installer for Nemobot.

Options:
  --init-state    Initialize local state templates and exit.
  --skip-browser  Do not deploy host-side browser/proxy containers.
  --skip-worker   Do not deploy the worker sandbox.
  --skip-bridge   Do not deploy the worker bridge.
  --with-x86-worker  Also prompt for and deploy the optional x86 worker host.
  --with-x86-lab     Backward-compatible alias for --with-x86-worker.
  -h, --help      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init-state)
      INIT_ONLY=1
      shift
      ;;
    --skip-browser)
      SKIP_BROWSER=1
      shift
      ;;
    --skip-worker)
      SKIP_WORKER=1
      shift
      ;;
    --skip-bridge)
      SKIP_BRIDGE=1
      shift
      ;;
    --with-x86-worker|--with-x86-lab)
      DEPLOY_X86=1
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

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

normalize_base_url() {
  local raw
  raw="$(trim "${1:-}")"

  if [[ -z "${raw}" || "${raw}" == "localhost" ]]; then
    printf 'http://localhost:8001/v1\n'
    return
  fi

  if [[ "${raw}" =~ ^https?:// ]]; then
    if [[ "${raw}" =~ /v1/?$ ]]; then
      printf '%s\n' "${raw}"
    elif [[ "${raw}" == */ ]]; then
      printf '%sv1\n' "${raw}"
    else
      printf '%s/v1\n' "${raw}"
    fi
    return
  fi

  if [[ "${raw}" == */* ]]; then
    printf 'http://%s\n' "${raw}"
    return
  fi

  if [[ "${raw}" == *:* ]]; then
    printf 'http://%s/v1\n' "${raw}"
  else
    printf 'http://%s:8001/v1\n' "${raw}"
  fi
}

prompt_value() {
  local __var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local secret="${4:-0}"
  local value=""
  local suffix=""

  if [[ -n "${default}" ]]; then
    suffix=" [${default}]"
  fi

  while true; do
    if [[ "${secret}" == "1" ]]; then
      read -r -s -p "${prompt}${suffix}: " value || true
      printf '\n'
    else
      read -r -p "${prompt}${suffix}: " value || true
    fi
    value="$(trim "${value}")"
    if [[ -z "${value}" ]]; then
      value="${default}"
    fi
    printf -v "${__var_name}" '%s' "${value}"
    return 0
  done
}

prompt_yes_no() {
  local __var_name="$1"
  local prompt="$2"
  local default="${3:-y}"
  local value=""
  local rendered_default="Y/n"

  if [[ "${default}" == "n" ]]; then
    rendered_default="y/N"
  fi

  while true; do
    read -r -p "${prompt} [${rendered_default}]: " value || true
    value="$(trim "${value}")"
    if [[ -z "${value}" ]]; then
      value="${default}"
    fi
    case "${value}" in
      y|Y|yes|YES)
        printf -v "${__var_name}" '1'
        return 0
        ;;
      n|N|no|NO)
        printf -v "${__var_name}" '0'
        return 0
        ;;
    esac
  done
}

prompt_choice() {
  local __var_name="$1"
  local prompt="$2"
  local default="$3"
  shift 3
  local options=("$@")
  local value=""
  local rendered_options
  rendered_options="$(IFS=/; printf '%s' "${options[*]}")"

  while true; do
    read -r -p "${prompt} [${rendered_options}] (${default}): " value || true
    value="$(trim "${value}")"
    if [[ -z "${value}" ]]; then
      value="${default}"
    fi
    local option
    for option in "${options[@]}"; do
      if [[ "${value}" == "${option}" ]]; then
        printf -v "${__var_name}" '%s' "${value}"
        return 0
      fi
    done
  done
}

load_env_value() {
  local path="$1"
  local key="$2"
  if [[ ! -f "${path}" ]]; then
    return 0
  fi
  python3 - "$path" "$key" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = ""
for raw_line in path.read_text().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    current_key, current_value = line.split("=", 1)
    if current_key == key:
        value = current_value.strip()

shell_single_quote_wrapper = '\'"\'"\''
if value.startswith(shell_single_quote_wrapper) and value.endswith(shell_single_quote_wrapper):
    value = value[len(shell_single_quote_wrapper):-len(shell_single_quote_wrapper)]
if len(value) >= 2 and ((value[0] == "'" and value[-1] == "'") or (value[0] == '"' and value[-1] == '"')):
    value = value[1:-1]
print(value)
PY
}

json_value() {
  local path="$1"
  local expr="$2"
  if [[ ! -f "${path}" ]]; then
    return 0
  fi
  python3 - "$path" "$expr" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expr = sys.argv[2]
try:
    data = json.loads(path.read_text())
except Exception:
    raise SystemExit(0)

value = data
for part in expr.split("."):
    if not part:
        continue
    if isinstance(value, dict):
        value = value.get(part)
    elif isinstance(value, list) and part.isdigit():
        idx = int(part)
        value = value[idx] if idx < len(value) else None
    else:
        value = None
        break

if value is None:
    raise SystemExit(0)
if isinstance(value, (dict, list)):
    raise SystemExit(0)
print(value)
PY
}

drop_placeholder() {
  local value="${1:-}"
  if [[ "${value}" == __REPLACE_* ]]; then
    return 0
  fi
  printf '%s' "${value}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd bash
require_cmd python3

"${ROOT}/stack-install.sh" --init-state

if (( INIT_ONLY )); then
  echo "initialized local state"
  exit 0
fi

STATE_DIR="${ROOT}/state"
CONFIG_PATH="${STATE_DIR}/openclaw.json"
RUNTIME_ENV_PATH="${STATE_DIR}/runtime.env"
MODEL_AUTH_ENV_PATH="${STATE_DIR}/model-auth.env"
OPENCLAW_AUTH_TAR_PATH="${STATE_DIR}/openclaw-auth.tar"
NVIDIA_ENV_PATH="${STATE_DIR}/nvidia-proxy.env"
PERPLEXITY_ENV_PATH="${STATE_DIR}/perplexity-proxy.env"

existing_primary_model="${MODEL_PRIMARY:-$(json_value "${CONFIG_PATH}" 'agents.defaults.model.primary')}"
existing_base_url="${MODEL_API_BASE_URL:-${DGX_BASE_URL:-$(json_value "${CONFIG_PATH}" 'models.providers.__REPLACE_PROVIDER_ID__.baseUrl')}}"
existing_model_id="${MODEL_API_MODEL_ID:-${DGX_MODEL_ID:-$(json_value "${CONFIG_PATH}" 'models.providers.__REPLACE_PROVIDER_ID__.models.0.id')}}"
existing_model_name="${MODEL_API_MODEL_NAME:-${DGX_MODEL_NAME:-$(json_value "${CONFIG_PATH}" 'models.providers.__REPLACE_PROVIDER_ID__.models.0.name')}}"
existing_provider_id="${MODEL_API_PROVIDER_ID:-${DGX_PROVIDER_ID:-}}"
existing_context_window="${MODEL_CONTEXT_WINDOW:-${DGX_CONTEXT_WINDOW:-$(json_value "${CONFIG_PATH}" 'agents.defaults.contextWindow')}}"
existing_timeout="${TIMEOUT_SECONDS:-$(json_value "${CONFIG_PATH}" 'agents.defaults.timeoutSeconds')}"
existing_slack_bot="${SLACK_BOT_TOKEN:-$(load_env_value "${RUNTIME_ENV_PATH}" 'SLACK_BOT_TOKEN')}"
existing_slack_app="${SLACK_APP_TOKEN:-$(load_env_value "${RUNTIME_ENV_PATH}" 'SLACK_APP_TOKEN')}"
existing_nvidia_key="${NVIDIA_API_KEY:-$(load_env_value "${NVIDIA_ENV_PATH}" 'NVIDIA_API_KEY')}"
existing_openai_key="${OPENAI_API_KEY:-${CODEX_API_KEY:-$(load_env_value "${MODEL_AUTH_ENV_PATH}" 'OPENAI_API_KEY')}}"
existing_codex_model="${CODEX_MODEL:-${OPENAI_MODEL:-gpt-5.3-codex}}"
existing_codex_oauth_model="${CODEX_MODEL:-${OPENAI_MODEL:-gpt-5.5}}"
existing_model_api_key="${MODEL_API_KEY:-${DGX_API_KEY:-}}"
existing_anthropic_auth_mode="${ANTHROPIC_AUTH_MODE:-$(load_env_value "${MODEL_AUTH_ENV_PATH}" 'ANTHROPIC_AUTH_MODE')}"
existing_anthropic_auth_token="${ANTHROPIC_AUTH_TOKEN:-$(load_env_value "${MODEL_AUTH_ENV_PATH}" 'ANTHROPIC_AUTH_TOKEN')}"
existing_anthropic_setup_token="${ANTHROPIC_SETUP_TOKEN:-$(load_env_value "${MODEL_AUTH_ENV_PATH}" 'ANTHROPIC_SETUP_TOKEN')}"
existing_anthropic_key="${ANTHROPIC_API_KEY:-$(load_env_value "${MODEL_AUTH_ENV_PATH}" 'ANTHROPIC_API_KEY')}"
existing_anthropic_model="${ANTHROPIC_MODEL:-$(load_env_value "${MODEL_AUTH_ENV_PATH}" 'ANTHROPIC_MODEL')}"
existing_perplexity_key="${PERPLEXITY_API_KEY:-$(load_env_value "${PERPLEXITY_ENV_PATH}" 'PERPLEXITY_API_KEY')}"
existing_perplexity_model="${PERPLEXITY_MODEL:-$(json_value "${CONFIG_PATH}" 'plugins.entries.perplexity.config.webSearch.model')}"
existing_worker_code_model="${WORKER_CODE_MODEL_ID:-gpt-5.3-codex}"

existing_base_url="$(drop_placeholder "${existing_base_url}")"
existing_model_id="$(drop_placeholder "${existing_model_id}")"
existing_model_name="$(drop_placeholder "${existing_model_name}")"
existing_provider_id="$(drop_placeholder "${existing_provider_id}")"
if [[ "${existing_primary_model}" == openai-codex/* ]]; then
  existing_codex_oauth_model="${existing_primary_model#openai-codex/}"
fi

if [[ -z "${existing_base_url}" ]]; then
  existing_base_url="https://api.openai.com/v1"
fi
if [[ -z "${existing_model_id}" ]]; then
  existing_model_id="${existing_codex_model}"
fi
if [[ -z "${existing_model_name}" ]]; then
  existing_model_name="${existing_model_id}"
fi
if [[ -z "${existing_anthropic_model}" ]]; then
  existing_anthropic_model="claude-opus-4-7"
fi
if [[ -z "${existing_context_window}" ]]; then
  existing_context_window="400000"
fi
if [[ -z "${existing_timeout}" ]]; then
  existing_timeout="2400"
fi
if [[ -z "${existing_perplexity_model}" ]]; then
  existing_perplexity_model="sonar-pro"
fi

backend_default="codex-api"
if [[ -n "${MODEL_BACKEND:-}" ]]; then
  backend_default="${MODEL_BACKEND}"
elif [[ -n "${existing_anthropic_setup_token}" || -n "${existing_anthropic_key}" || -n "${existing_anthropic_auth_token}" || "${existing_model_id}" == anthropic/* || "${existing_primary_model}" == anthropic/* ]]; then
  backend_default="anthropic"
elif [[ "${existing_primary_model}" == openai-codex/* || -f "${OPENCLAW_AUTH_TAR_PATH}" ]]; then
  backend_default="codex-oauth"
elif [[ -n "${existing_base_url}" && "${existing_base_url}" != "https://api.openai.com/v1" && "${existing_provider_id}" != "openai" ]]; then
  backend_default="custom-openai"
fi
case "${backend_default}" in
  codex-oauth|codex-api|custom-openai|anthropic)
    ;;
  openai|openai-api)
    backend_default="codex-api"
    ;;
  openai-codex|openai-codex-oauth)
    backend_default="codex-oauth"
    ;;
  *)
    backend_default="codex-api"
    ;;
esac
prompt_choice MODEL_BACKEND "Primary model backend" "${backend_default}" "codex-oauth" "codex-api" "custom-openai" "anthropic"
if [[ "${MODEL_BACKEND}" == "anthropic" ]]; then
  if [[ -z "${existing_anthropic_auth_mode}" ]]; then
    if [[ -n "${existing_anthropic_auth_token}" ]]; then
      existing_anthropic_auth_mode="claude-cli"
    elif [[ -n "${existing_anthropic_setup_token}" ]]; then
      existing_anthropic_auth_mode="setup-token"
    else
      existing_anthropic_auth_mode="api-key"
    fi
  fi
  prompt_choice ANTHROPIC_AUTH_MODE "Anthropic auth mode" "${existing_anthropic_auth_mode}" "claude-cli" "setup-token" "api-key"
  if [[ "${ANTHROPIC_AUTH_MODE}" == "claude-cli" ]]; then
    prompt_value ANTHROPIC_AUTH_TOKEN "Claude Code auth token" "${existing_anthropic_auth_token}" 1
    unset ANTHROPIC_SETUP_TOKEN ANTHROPIC_API_KEY || true
  elif [[ "${ANTHROPIC_AUTH_MODE}" == "setup-token" ]]; then
    prompt_value ANTHROPIC_SETUP_TOKEN "Anthropic setup-token from \`claude setup-token\`" "${existing_anthropic_setup_token}" 1
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN || true
  else
    prompt_value ANTHROPIC_API_KEY "Anthropic API key" "${existing_anthropic_key}" 1
    unset ANTHROPIC_SETUP_TOKEN ANTHROPIC_AUTH_TOKEN || true
  fi
  prompt_value ANTHROPIC_MODEL "Anthropic Claude model id" "${existing_anthropic_model}"
  MODEL_API_BASE_URL=""
  MODEL_API_MODEL_ID=""
  MODEL_API_MODEL_NAME=""
  MODEL_API_PROVIDER_ID=""
  MODEL_API_KEY=""
  OPENAI_API_KEY=""
  existing_worker_code_model="${WORKER_CODE_MODEL_ID:-${ANTHROPIC_MODEL}}"
  model_max_tokens_default="${MODEL_MAX_TOKENS:-${DGX_MAX_TOKENS:-32000}}"
elif [[ "${MODEL_BACKEND}" == "codex-api" ]]; then
  MODEL_API_BASE_URL="https://api.openai.com/v1"
  MODEL_API_PROVIDER_ID="openai"
  prompt_value OPENAI_API_KEY "OpenAI API key for Codex API model" "${existing_openai_key}" 1
  if [[ -z "${OPENAI_API_KEY}" ]]; then
    echo "OpenAI API key is required for codex-api backend. Use custom-openai for unauthenticated local endpoints." >&2
    exit 1
  fi
  prompt_value MODEL_API_MODEL_ID "Codex API model id" "${existing_model_id}"
  prompt_value MODEL_API_MODEL_NAME "Codex API model display name" "${existing_model_name}"
  unset ANTHROPIC_AUTH_MODE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_SETUP_TOKEN ANTHROPIC_MODEL MODEL_API_KEY || true
  existing_worker_code_model="${WORKER_CODE_MODEL_ID:-${MODEL_API_MODEL_ID}}"
  model_max_tokens_default="${MODEL_MAX_TOKENS:-${DGX_MAX_TOKENS:-32000}}"
elif [[ "${MODEL_BACKEND}" == "codex-oauth" ]]; then
  prompt_value CODEX_MODEL "Codex OAuth model id" "${existing_codex_oauth_model}"
  MODEL_API_BASE_URL=""
  MODEL_API_MODEL_ID=""
  MODEL_API_MODEL_NAME=""
  MODEL_API_PROVIDER_ID=""
  MODEL_API_KEY=""
  OPENAI_API_KEY=""
  unset ANTHROPIC_AUTH_MODE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_SETUP_TOKEN ANTHROPIC_MODEL MODEL_API_KEY || true
  existing_worker_code_model="${WORKER_CODE_MODEL_ID:-${CODEX_MODEL}}"
  model_max_tokens_default="${MODEL_MAX_TOKENS:-${DGX_MAX_TOKENS:-32000}}"
else
  prompt_value inference_endpoint "Model-serving API host, host:port, localhost, or full base URL" "${existing_base_url}"
  MODEL_API_BASE_URL="$(normalize_base_url "${inference_endpoint}")"
  if [[ -n "${existing_provider_id}" && "${existing_provider_id}" != "openai" ]]; then
    prompt_value MODEL_API_PROVIDER_ID "Provider id" "${existing_provider_id}"
  else
    MODEL_API_PROVIDER_ID=""
  fi
  prompt_value MODEL_API_MODEL_ID "Primary model id" "${existing_model_id}"
  prompt_value MODEL_API_MODEL_NAME "Primary model display name" "${existing_model_name}"
  prompt_value MODEL_API_KEY "Model API key, blank for local/managed endpoint" "${existing_model_api_key}" 1
  unset ANTHROPIC_AUTH_MODE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_SETUP_TOKEN ANTHROPIC_MODEL OPENAI_API_KEY || true
  model_max_tokens_default="${MODEL_MAX_TOKENS:-${DGX_MAX_TOKENS:-4096}}"
fi

prompt_value WORKER_CODE_MODEL_ID "Worker analyzer/verifier code model id" "${existing_worker_code_model}"
prompt_value MODEL_CONTEXT_WINDOW "Primary model context window" "${existing_context_window}"
prompt_value MODEL_MAX_TOKENS "Primary model max output tokens" "${model_max_tokens_default}"
prompt_value TIMEOUT_SECONDS "Gateway timeout seconds" "${existing_timeout}"

prompt_yes_no configure_slack "Configure Slack now?" "y"
if (( configure_slack )); then
  prompt_value SLACK_BOT_TOKEN "Slack bot token" "${existing_slack_bot}" 1
  prompt_value SLACK_APP_TOKEN "Slack app token" "${existing_slack_app}" 1
else
  unset SLACK_BOT_TOKEN SLACK_APP_TOKEN || true
fi

prompt_yes_no configure_nvidia_cloud "Configure NVIDIA cloud proxy for subagents?" "n"
if (( configure_nvidia_cloud )); then
  prompt_value NVIDIA_API_KEY "NVIDIA API key" "${existing_nvidia_key}" 1
else
  unset NVIDIA_API_KEY || true
fi

prompt_yes_no configure_perplexity "Configure Perplexity web search?" "y"
if (( configure_perplexity )); then
  prompt_value PERPLEXITY_API_KEY "Perplexity API key" "${existing_perplexity_key}" 1
  prompt_value PERPLEXITY_MODEL "Perplexity model" "${existing_perplexity_model}"
else
  unset PERPLEXITY_API_KEY PERPLEXITY_MODEL || true
fi

stack_args=()
if (( SKIP_BROWSER )); then
  stack_args+=(--skip-browser)
fi
if (( SKIP_WORKER )); then
  stack_args+=(--skip-worker)
fi
if (( SKIP_BRIDGE )); then
  stack_args+=(--skip-bridge)
fi

export MODEL_BACKEND MODEL_API_BASE_URL MODEL_API_PROVIDER_ID MODEL_API_MODEL_ID MODEL_API_MODEL_NAME WORKER_CODE_MODEL_ID MODEL_CONTEXT_WINDOW MODEL_MAX_TOKENS TIMEOUT_SECONDS
if [[ -n "${CODEX_MODEL:-}" ]]; then
  export CODEX_MODEL
fi
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  export OPENAI_API_KEY
fi
if [[ -n "${MODEL_API_KEY:-}" ]]; then
  export MODEL_API_KEY
fi
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  export ANTHROPIC_API_KEY
fi
if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  export ANTHROPIC_AUTH_TOKEN
fi
if [[ -n "${ANTHROPIC_SETUP_TOKEN:-}" ]]; then
  export ANTHROPIC_SETUP_TOKEN
fi
if [[ -n "${ANTHROPIC_AUTH_MODE:-}" ]]; then
  export ANTHROPIC_AUTH_MODE
fi
if [[ -n "${ANTHROPIC_MODEL:-}" ]]; then
  export ANTHROPIC_MODEL
fi
if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
  export SLACK_BOT_TOKEN
fi
if [[ -n "${SLACK_APP_TOKEN:-}" ]]; then
  export SLACK_APP_TOKEN
fi
if [[ -n "${NVIDIA_API_KEY:-}" ]]; then
  export NVIDIA_API_KEY
fi
if [[ -n "${PERPLEXITY_API_KEY:-}" ]]; then
  export PERPLEXITY_API_KEY
fi
if [[ -n "${PERPLEXITY_MODEL:-}" ]]; then
  export PERPLEXITY_MODEL
fi

"${ROOT}/stack-install.sh" "${stack_args[@]}"

if (( DEPLOY_X86 )); then
  prompt_value REMOTE_HOST "x86 lab SSH host or IP (localhost allowed)" "${REMOTE_HOST:-}"
  prompt_value REMOTE_USER "x86 lab SSH user (leave blank to use your SSH default)" "${REMOTE_USER-}"
  prompt_value REMOTE_DIR "x86 worker remote directory" "${REMOTE_DIR:-openshell-x86-worker}"
  prompt_value REMOTE_PASSWORD "x86 lab SSH password (leave blank for SSH keys)" "${REMOTE_PASSWORD:-}" 1
  prompt_yes_no ALLOW_INSECURE_SSH "Temporarily disable SSH host key verification for the x86 lab bootstrap?" "n"

  export REMOTE_HOST REMOTE_USER REMOTE_DIR REMOTE_PASSWORD
  if (( ALLOW_INSECURE_SSH )); then
    export ALLOW_INSECURE_SSH=1
  else
    export ALLOW_INSECURE_SSH=0
  fi

  "${ROOT}/x86-worker/install-remote.sh"
  if (( SKIP_BRIDGE == 0 )) && (( SKIP_WORKER == 0 )); then
    "${ROOT}/x86-worker/install-bridge.sh"
  fi
fi

echo "bootstrap complete"
