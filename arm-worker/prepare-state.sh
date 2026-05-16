#!/usr/bin/env bash
set -euo pipefail

WORKER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${WORKER_ROOT}/.." && pwd)"
WORKSPACE_FILES=(AGENTS.md TOOLS.md USER.md SOUL.md HEARTBEAT.md IDENTITY.md)
WORKER_DIRS=(workspace workspace-researcher workspace-analyzer workspace-verifier)

copy_template_dir() {
  local dir_name="$1"
  local source_dir="${ROOT}/templates/${dir_name}"
  local target_dir="${WORKER_ROOT}/templates/${dir_name}"
  local name

  [[ -d "${source_dir}" ]] || return 0

  mkdir -p "${target_dir}"
  for name in "${WORKSPACE_FILES[@]}"; do
    if [[ -f "${source_dir}/${name}" ]]; then
      cp "${source_dir}/${name}" "${target_dir}/${name}"
    fi
  done
}

seed_state_dir() {
  local dir_name="$1"
  local target_dir="${WORKER_ROOT}/state/${dir_name}"
  local worker_template_dir="${WORKER_ROOT}/templates/${dir_name}"
  local shared_state_dir="${ROOT}/state/${dir_name}"
  local shared_template_dir="${ROOT}/templates/${dir_name}"
  local name

  mkdir -p "${target_dir}"
  for name in "${WORKSPACE_FILES[@]}"; do
    local target_path="${target_dir}/${name}"
    if [[ -f "${target_path}" ]]; then
      continue
    fi
    if [[ "${dir_name}" != "workspace" && -f "${shared_state_dir}/${name}" ]]; then
      cp "${shared_state_dir}/${name}" "${target_path}"
    elif [[ -f "${worker_template_dir}/${name}" ]]; then
      cp "${worker_template_dir}/${name}" "${target_path}"
    elif [[ -f "${shared_template_dir}/${name}" ]]; then
      cp "${shared_template_dir}/${name}" "${target_path}"
    fi
  done
}

mkdir -p "${WORKER_ROOT}/templates" "${WORKER_ROOT}/state"

copy_template_dir "workspace-researcher"
copy_template_dir "workspace-analyzer"
copy_template_dir "workspace-verifier"

for dir_name in "${WORKER_DIRS[@]}"; do
  seed_state_dir "${dir_name}"
done

if [[ -f "${ROOT}/state/openclaw.json" ]]; then
  python3 "${WORKER_ROOT}/render-worker-state.py" \
    "${ROOT}/state/openclaw.json" \
    "${WORKER_ROOT}/templates/openclaw.template.json" \
    "${WORKER_ROOT}/state/openclaw.json"
  chmod 0600 "${WORKER_ROOT}/state/openclaw.json"
elif [[ ! -s "${WORKER_ROOT}/state/openclaw.json" ]]; then
  cp "${WORKER_ROOT}/templates/openclaw.template.json" "${WORKER_ROOT}/state/openclaw.json"
  chmod 0600 "${WORKER_ROOT}/state/openclaw.json"
fi
