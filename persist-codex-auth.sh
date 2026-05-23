#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT}/state}"
CODEX_HOME_SOURCE="${CODEX_HOME_SOURCE:-${CODEX_HOME:-${HOME}/.codex}}"
CODEX_AUTH_TAR_PATH="${CODEX_AUTH_TAR_PATH:-${STATE_DIR}/codex-auth.tar}"

mkdir -p "${STATE_DIR}"

if [[ ! -f "${CODEX_HOME_SOURCE}/auth.json" ]]; then
  echo "missing Codex auth file: ${CODEX_HOME_SOURCE}/auth.json" >&2
  echo "run 'codex login' for this OS user first, then rerun this script" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

install -m 0600 "${CODEX_HOME_SOURCE}/auth.json" "${tmpdir}/auth.json"
if [[ -f "${CODEX_HOME_SOURCE}/config.toml" ]]; then
  install -m 0600 "${CODEX_HOME_SOURCE}/config.toml" "${tmpdir}/config.toml"
fi

tmp_path="${CODEX_AUTH_TAR_PATH}.tmp"
tar -C "${tmpdir}" -cf "${tmp_path}" .
mv "${tmp_path}" "${CODEX_AUTH_TAR_PATH}"
chmod 0600 "${CODEX_AUTH_TAR_PATH}"

echo "persisted Codex CLI auth to ${CODEX_AUTH_TAR_PATH}"
