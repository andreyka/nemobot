#!/usr/bin/env bash
set -euo pipefail

WORKER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${WORKER_ROOT}/.." && pwd)"
if [[ -f "${ROOT}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT}/release.env"
fi
OPENCLAW_RELEASE="${OPENCLAW_RELEASE:-2026.5.12}"
OPENCLAW_OFFICIAL_PLUGIN_RELEASE="${OPENCLAW_OFFICIAL_PLUGIN_RELEASE:-${OPENCLAW_RELEASE}}"
OPENCLAW_OFFICIAL_CHANNEL_PLUGINS="${OPENCLAW_OFFICIAL_CHANNEL_PLUGINS:-@openclaw/slack}"
export OPENCLAW_RELEASE OPENCLAW_OFFICIAL_PLUGIN_RELEASE OPENCLAW_OFFICIAL_CHANNEL_PLUGINS

"${WORKER_ROOT}/prepare-state.sh"

export STATE_DIR="${WORKER_ROOT}/state"
export TEMPLATE_DIR="${WORKER_ROOT}/templates"
export CONFIG_PATH="${STATE_DIR}/openclaw.json"
export EXEC_APPROVALS_PATH="${EXEC_APPROVALS_PATH:-${ROOT}/state/exec-approvals.json}"
export WORKSPACE_DIRS_ENV="workspace workspace-researcher workspace-analyzer workspace-verifier"
export BACKUP_DIR_BASE="${WORKER_ROOT}/backups"
export SANDBOX="${SANDBOX:-nemoworker}"
export SOURCE_SANDBOX="${SOURCE_SANDBOX:-nemobot}"
export CONFIG_SECRET="${CONFIG_SECRET:-openclaw-config-${SANDBOX}}"
export ENV_FILE_PATH="${ENV_FILE_PATH:-}"
export ENV_SECRET="${ENV_SECRET:-}"
export MODEL_AUTH_ENV_FILE_PATH="${MODEL_AUTH_ENV_FILE_PATH:-${ROOT}/state/model-auth.env}"
export MODEL_AUTH_ENV_SECRET="${MODEL_AUTH_ENV_SECRET:-openclaw-model-auth}"
export SKIP_LIVE_CONFIG_REFRESH=1

exec "${ROOT}/apply.sh" "$@"
