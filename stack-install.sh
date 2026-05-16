#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INIT_ONLY=0
SKIP_BROWSER=0
SKIP_WORKER=0
SKIP_BRIDGE=0
REFRESH_LIVE_FRONTDOOR=0
REFRESH_LIVE_WORKER=0

usage() {
  cat <<'EOF'
Usage: ./stack-install.sh [options]

Options:
  --init-state              Initialize local frontdoor and worker state, then exit.
  --skip-browser            Do not deploy host-side browser/proxy containers.
  --skip-worker             Do not deploy the worker sandbox.
  --skip-bridge             Do not deploy the worker bridge.
  --refresh-live-frontdoor  Snapshot frontdoor config/workspace from the running sandbox before deploying.
  --refresh-live-worker     Snapshot worker config/workspace from the running sandbox before deploying.
  -h, --help                Show this help.
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

frontdoor_args=()
worker_args=()

if (( INIT_ONLY )); then
  "${ROOT}/install.sh" --init-state
  if (( SKIP_WORKER == 0 )); then
    "${ROOT}/arm-worker/install.sh" --init-state
  fi
  exit 0
fi

if (( REFRESH_LIVE_FRONTDOOR )); then
  frontdoor_args+=(--refresh-live-config)
fi
if (( SKIP_BROWSER )); then
  frontdoor_args+=(--skip-browser)
fi

"${ROOT}/install.sh" "${frontdoor_args[@]}"

if (( SKIP_WORKER == 0 )); then
  if (( REFRESH_LIVE_WORKER )); then
    worker_args+=(--refresh-live-config)
  fi
  "${ROOT}/arm-worker/install.sh" "${worker_args[@]}"
fi

if (( SKIP_BRIDGE == 0 )) && (( SKIP_WORKER == 0 )); then
  "${ROOT}/bridge/install.sh"
fi
