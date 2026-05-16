#!/usr/bin/env bash
set -euo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${X86_ROOT}/.." && pwd)"
if [[ -f "${ROOT}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT}/release.env"
fi
OPENCLAW_RELEASE="${OPENCLAW_RELEASE:-2026.5.12}"
OPENCLAW_OFFICIAL_PLUGIN_RELEASE="${OPENCLAW_OFFICIAL_PLUGIN_RELEASE:-${OPENCLAW_RELEASE}}"
OPENCLAW_OFFICIAL_CHANNEL_PLUGINS="${OPENCLAW_OFFICIAL_CHANNEL_PLUGINS:-@openclaw/slack}"
export OPENCLAW_RELEASE OPENCLAW_OFFICIAL_PLUGIN_RELEASE OPENCLAW_OFFICIAL_CHANNEL_PLUGINS
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER-${USER:-}}"
REMOTE_DIR="${REMOTE_DIR:-openshell-x86-lab}"
REMOTE_PASSWORD="${REMOTE_PASSWORD:-}"
RESET_CLUSTER_STATE="${RESET_CLUSTER_STATE:-0}"
ALLOW_INSECURE_SSH="${ALLOW_INSECURE_SSH:-0}"
SSH_OPTS=()

if [[ "${ALLOW_INSECURE_SSH}" == "1" ]]; then
  echo "warning: insecure SSH host key verification is enabled for this run" >&2
  SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
fi

if [[ -z "${REMOTE_HOST}" ]]; then
  echo "set REMOTE_HOST to the x86 lab host before running install-remote.sh" >&2
  exit 2
fi

if [[ -n "${REMOTE_PASSWORD}" ]] && ! command -v sshpass >/dev/null 2>&1; then
  echo "sshpass not found; falling back to built-in Python PTY password driver" >&2
fi

remote_target() {
  if [[ -n "${REMOTE_USER}" ]]; then
    printf '%s@%s' "${REMOTE_USER}" "${REMOTE_HOST}"
  else
    printf '%s' "${REMOTE_HOST}"
  fi
}

REMOTE_TARGET="$(remote_target)"

run_with_password() {
  local password="$1"
  shift
  python3 - "$password" "$@" <<'PY'
import os
import select
import sys

password = sys.argv[1]
cmd = sys.argv[2:]
pid, master_fd = os.forkpty()
if pid == 0:
    os.execvp(cmd[0], cmd)

buffer = ""
sent = 0
final_status = None

while True:
    ready, _, _ = select.select([master_fd], [], [], 0.2)
    if master_fd in ready:
      try:
        chunk = os.read(master_fd, 4096)
      except OSError:
        chunk = b""
      if chunk:
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        decoded = chunk.decode("utf-8", "ignore")
        buffer = (buffer + decoded)[-4096:]
        if "assword:" in buffer and sent < 4:
          os.write(master_fd, (password + "\n").encode("utf-8"))
          sent += 1
          buffer = ""
      else:
        try:
          waited_pid, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
          waited_pid, status = pid, 0
        if waited_pid == pid:
          final_status = status
          break
    else:
      try:
        waited_pid, status = os.waitpid(pid, os.WNOHANG)
      except ChildProcessError:
          waited_pid, status = pid, 0
      if waited_pid == pid:
        final_status = status
        break

os.close(master_fd)
if final_status is None:
    _, final_status = os.waitpid(pid, 0)
status = final_status
if os.WIFEXITED(status):
    raise SystemExit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    raise SystemExit(128 + os.WTERMSIG(status))
raise SystemExit(1)
PY
}

ssh_cmd() {
  if [[ -n "${REMOTE_PASSWORD}" ]]; then
    if command -v sshpass >/dev/null 2>&1; then
      sshpass -p "${REMOTE_PASSWORD}" ssh "${SSH_OPTS[@]}" "$@"
    else
      run_with_password "${REMOTE_PASSWORD}" ssh "${SSH_OPTS[@]}" "$@"
    fi
  else
    ssh "${SSH_OPTS[@]}" "$@"
  fi
}

rsync_cmd() {
  if [[ -n "${REMOTE_PASSWORD}" ]]; then
    if command -v sshpass >/dev/null 2>&1; then
      SSHPASS="${REMOTE_PASSWORD}" rsync -az -e "sshpass -e ssh ${SSH_OPTS[*]}" "$@"
    else
      run_with_password "${REMOTE_PASSWORD}" rsync -az -e "ssh ${SSH_OPTS[*]}" "$@"
    fi
  else
    rsync -az -e "ssh ${SSH_OPTS[*]}" "$@"
  fi
}

"${X86_ROOT}/prepare-state.sh"

ssh_cmd "${REMOTE_TARGET}" "mkdir -p '${REMOTE_DIR}' '${REMOTE_DIR}/state' '${REMOTE_DIR}/browser'"
rsync_cmd \
  "${ROOT}/release.env" \
  "${X86_ROOT}/Dockerfile.sandbox" \
  "${X86_ROOT}/Dockerfile.lab-control" \
  "${X86_ROOT}/Dockerfile.vm-runner" \
  "${X86_ROOT}/lab-control.py" \
  "${X86_ROOT}/vm-runner.py" \
  "${X86_ROOT}/claude-wrapper.sh" \
  "${ROOT}/openclaw-bridge.py" \
  "${ROOT}/openclaw-anthropic-auth.py" \
  "${ROOT}/openclaw-memory.py" \
  "${X86_ROOT}/openclaw-entrypoint.sh" \
  "${X86_ROOT}/remote-deploy.sh" \
  "${REMOTE_TARGET}:${REMOTE_DIR}/"
rsync_cmd --delete "${X86_ROOT}/state/" "${REMOTE_TARGET}:${REMOTE_DIR}/state/"
rsync_cmd --delete "${ROOT}/browser/" "${REMOTE_TARGET}:${REMOTE_DIR}/browser/"

ssh_cmd "${REMOTE_TARGET}" \
  "cd '${REMOTE_DIR}' && RESET_CLUSTER_STATE='${RESET_CLUSTER_STATE}' bash ./remote-deploy.sh"
