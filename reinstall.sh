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
BACKUP_DIR_BASE="${BACKUP_DIR_BASE:-${ROOT}/backups}"
MEMORY_ENV_PATH="${MEMORY_ENV_PATH:-${STATE_DIR}/memory-service.env}"
BACKUP_MEMORY=1
SKIP_BROWSER=0
SKIP_WORKER=0
SKIP_BRIDGE=0
WITH_X86_WORKER=0
REFRESH_LIVE_FRONTDOOR=0
REFRESH_LIVE_WORKER=0
RESET_X86_CLUSTER=0
ALLOW_INSECURE_SSH="${ALLOW_INSECURE_SSH:-0}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER-}"
REMOTE_DIR="${REMOTE_DIR:-}"
REMOTE_PASSWORD="${REMOTE_PASSWORD:-}"

usage() {
  cat <<'EOF'
Usage: ./reinstall.sh [options]

Safe rebuild/update entrypoint for Nemobot.

By default this script:
- preserves the durable memory Docker volume
- writes a timestamped SQL backup when the memory DB is running
- rebuilds and reapplies the primary ARM stack
- optionally updates the x86 worker host and its frontdoor-side bridge

Options:
  --skip-memory-backup      Do not create a pg_dump backup before reinstalling.
  --skip-browser            Do not rebuild/redeploy host-side browser/proxy containers.
  --skip-worker             Do not redeploy the ARM worker sandbox.
  --skip-bridge             Do not redeploy the frontdoor-side worker bridge.
  --with-x86-worker         Also update the optional x86 worker host and x86 bridge.
  --with-x86-lab            Backward-compatible alias for --with-x86-worker.
  --remote-host HOST        x86 worker SSH host.
  --remote-user USER        x86 worker SSH user.
  --remote-dir DIR          x86 worker remote directory.
  --remote-password PASS    x86 worker SSH password. Prefer SSH keys when possible.
  --allow-insecure-ssh      Disable SSH host-key verification for x86 worker update.
  --reset-x86-cluster       Recreate the x86 OpenShell cluster state during update.
  --refresh-live-frontdoor  Snapshot the running frontdoor sandbox before redeploying.
  --refresh-live-worker     Snapshot the running ARM worker sandbox before redeploying.
  -h, --help                Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-memory-backup)
      BACKUP_MEMORY=0
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
      WITH_X86_WORKER=1
      shift
      ;;
    --remote-host)
      REMOTE_HOST="${2:-}"
      shift 2
      ;;
    --remote-user)
      REMOTE_USER="${2:-}"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="${2:-}"
      shift 2
      ;;
    --remote-password)
      REMOTE_PASSWORD="${2:-}"
      shift 2
      ;;
    --allow-insecure-ssh)
      ALLOW_INSECURE_SSH=1
      shift
      ;;
    --reset-x86-cluster)
      RESET_X86_CLUSTER=1
      shift
      ;;
    --refresh-live-frontdoor)
      REFRESH_LIVE_FRONTDOOR=1
      shift
      ;;
    --refresh-live-worker)
      REFRESH_LIVE_WORKER=1
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

memory_db_running() {
  docker ps --format '{{.Names}}' | grep -Fxq openclaw-memory-db
}

memory_volume_exists() {
  docker volume inspect openclaw-memory-db-data >/dev/null 2>&1
}

backup_memory_db() {
  local timestamp backup_dir backup_path
  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_DIR_BASE}/${timestamp}"
  backup_path="${backup_dir}/openclaw-memory.sql"

  mkdir -p "${backup_dir}"

  if memory_db_running; then
    docker exec openclaw-memory-db sh -lc 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > "${backup_path}"
    chmod 0600 "${backup_path}"
    echo "memory backup written to ${backup_path}"
    return 0
  fi

  if memory_volume_exists; then
    echo "memory DB container is not running; skipping SQL dump but preserving Docker volume openclaw-memory-db-data" >&2
    return 0
  fi

  echo "memory DB is not present yet; nothing to back up" >&2
}

require_cmd docker
require_cmd bash

if (( BACKUP_MEMORY )); then
  backup_memory_db
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
if (( REFRESH_LIVE_FRONTDOOR )); then
  stack_args+=(--refresh-live-frontdoor)
fi
if (( REFRESH_LIVE_WORKER )); then
  stack_args+=(--refresh-live-worker)
fi

"${ROOT}/stack-install.sh" "${stack_args[@]}"

if (( WITH_X86_WORKER )); then
  if [[ -z "${REMOTE_HOST}" ]]; then
    echo "set --remote-host or REMOTE_HOST when using --with-x86-worker" >&2
    exit 2
  fi

  export REMOTE_HOST REMOTE_USER REMOTE_DIR REMOTE_PASSWORD ALLOW_INSECURE_SSH
  if (( RESET_X86_CLUSTER )); then
    export RESET_CLUSTER_STATE=1
  else
    export RESET_CLUSTER_STATE=0
  fi

  "${ROOT}/x86-worker/install-remote.sh"
  if (( SKIP_BRIDGE == 0 )); then
    "${ROOT}/x86-worker/install-bridge.sh"
  fi
fi

echo "reinstall/update complete"
