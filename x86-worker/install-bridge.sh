#!/usr/bin/env bash
set -euo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${X86_ROOT}/.." && pwd)"

export WORKER_STATE_DIR="${WORKER_STATE_DIR:-${X86_ROOT}/state}"
if [[ -z "${WORKER_GATEWAY_URL:-}" ]]; then
  echo "set WORKER_GATEWAY_URL to the x86 worker gateway URL before running install-bridge.sh" >&2
  exit 2
fi
export DEPLOY_NAME="${DEPLOY_NAME:-openclaw-x86-worker-bridge}"
export SECRET_NAME="${SECRET_NAME:-openclaw-x86-worker-bridge}"
export IMAGE_TAG="${IMAGE_TAG:-openclaw-worker-bridge:x86-remote}"

exec "${ROOT}/bridge/install.sh"
