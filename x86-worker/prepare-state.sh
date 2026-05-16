#!/usr/bin/env bash
set -euo pipefail

X86_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${X86_ROOT}/.." && pwd)"
WORKSPACE_FILES=(AGENTS.md TOOLS.md USER.md SOUL.md HEARTBEAT.md IDENTITY.md)
X86_DIRS=(workspace workspace-researcher workspace-analyzer workspace-verifier)

copy_state_dir() {
  local dir_name="$1"
  local target_dir="${X86_ROOT}/state/${dir_name}"
  local candidate_dirs=(
    "${ROOT}/arm-worker/state/${dir_name}"
    "${ROOT}/arm-worker/templates/${dir_name}"
    "${ROOT}/state/${dir_name}"
    "${ROOT}/templates/${dir_name}"
  )
  local name

  mkdir -p "${target_dir}"
  for name in "${WORKSPACE_FILES[@]}"; do
    local source_dir
    for source_dir in "${candidate_dirs[@]}"; do
      if [[ -f "${source_dir}/${name}" ]]; then
        cp "${source_dir}/${name}" "${target_dir}/${name}"
        break
      fi
    done
  done
}

strip_private_memory_refs() {
  local path="$1"
  [[ -f "${path}" ]] || return 0
  python3 - <<'PY' "${path}"
from pathlib import Path
import sys

path = Path(sys.argv[1])
drop_fragments = (
    "Durable research memory service:",
    "Use it for concise reusable findings from long-running work, not raw logs or secrets.",
    "The memory service is on a private/internal host.",
    "Search prior findings with `curl -fsS` against `/search",
    "Store concise summaries with `curl -fsS` against `/store",
    "store a concise record with `curl` `POST /v1/documents`",
    "For durable milestones or final results, store a concise record",
)
replacement = "- Durable storage is handled upstream by the frontdoor/orchestrator memory path, not directly from this host."

lines = []
in_memory = False
inserted = False
for line in path.read_text().splitlines():
    stripped = line.strip()
    if stripped == "## Memory":
        in_memory = True
        inserted = False
        lines.append(line)
        continue
    if in_memory and stripped.startswith("## ") and stripped != "## Memory":
        in_memory = False
    if any(fragment in line for fragment in drop_fragments):
        continue
    lines.append(line)
    if in_memory and not inserted and "Daily notes live in `memory/YYYY-MM-DD.md`." in line:
        lines.append(replacement)
        inserted = True
path.write_text("\n".join(lines) + "\n")
PY
}

append_if_missing() {
  local path="$1"
  local marker="$2"
  local block="$3"
  [[ -f "${path}" ]] || return 0
  if grep -Fq "${marker}" "${path}"; then
    return 0
  fi
  printf '\n%s\n' "${block}" >> "${path}"
}

for dir_name in "${X86_DIRS[@]}"; do
  copy_state_dir "${dir_name}"
  strip_private_memory_refs "${X86_ROOT}/state/${dir_name}/AGENTS.md"
done

append_if_missing \
  "${X86_ROOT}/state/workspace-researcher/TOOLS.md" \
  "public GitHub API examples on x86:" \
"- public GitHub API examples on x86:
- repo metadata: \`https://api.github.com/repos/<owner>/<repo>\`
- repo tree: \`https://api.github.com/repos/<owner>/<repo>/git/trees/<sha>?recursive=1\`
- contents: \`https://api.github.com/repos/<owner>/<repo>/contents/<path>?ref=<ref>\`"

for dir_name in workspace-analyzer workspace-verifier; do
  append_if_missing \
    "${X86_ROOT}/state/${dir_name}/TOOLS.md" \
    "x86 lab-control base URL:" \
"- x86 lab-control base URL:
  \`http://lab-control.openshell-lab.svc.cluster.local:8090\`
- lab-control is for bounded disposable jobs only, not broad host control.
- list jobs:
  \`curl -fsS 'http://lab-control.openshell-lab.svc.cluster.local:8090/jobs'\`
- launch a disposable job:
  \`curl -fsSG 'http://lab-control.openshell-lab.svc.cluster.local:8090/run' --data-urlencode 'profile=debian' --data-urlencode 'name=<short-name>' --data-urlencode 'cmd=<shell command>'\`
- fetch logs:
  \`curl -fsS 'http://lab-control.openshell-lab.svc.cluster.local:8090/logs?name=<job-name>'\`
- delete a job:
  \`curl -fsS 'http://lab-control.openshell-lab.svc.cluster.local:8090/delete?name=<job-name>'\`
- list VM images:
  \`curl -fsS 'http://lab-control.openshell-lab.svc.cluster.local:8090/vm/images'\`
- launch a disposable VM validation job:
  \`curl -fsSG 'http://lab-control.openshell-lab.svc.cluster.local:8090/vm/run' --data-urlencode 'image=ubuntu-24.04' --data-urlencode 'name=<short-name>' --data-urlencode 'script=<bash script>' --data-urlencode 'timeout=900' --data-urlencode 'memoryMiB=2048' --data-urlencode 'vcpus=2'\`
- prefer VM jobs only for guest-boundary, kernel/userspace, or boot/runtime validation that a container cannot model." 
done

mkdir -p "${X86_ROOT}/state"

python3 "${ROOT}/arm-worker/render-worker-state.py" \
  "${ROOT}/state/openclaw.json" \
  "${ROOT}/arm-worker/templates/openclaw.template.json" \
  "${X86_ROOT}/state/openclaw.json"
chmod 0600 "${X86_ROOT}/state/openclaw.json"

for env_name in model-auth.env nvidia-proxy.env anthropic-proxy.env perplexity-proxy.env; do
  if [[ -f "${ROOT}/state/${env_name}" ]]; then
    cp "${ROOT}/state/${env_name}" "${X86_ROOT}/state/${env_name}"
    chmod 0600 "${X86_ROOT}/state/${env_name}"
  else
    rm -f "${X86_ROOT}/state/${env_name}"
  fi
done

if [[ -d "${ROOT}/state/claude-auth" ]]; then
  rm -rf "${X86_ROOT}/state/claude-auth"
  mkdir -p "${X86_ROOT}/state/claude-auth"
  if [[ -f "${ROOT}/state/claude-auth/claude.json" ]]; then
    cp "${ROOT}/state/claude-auth/claude.json" "${X86_ROOT}/state/claude-auth/claude.json"
    chmod 0600 "${X86_ROOT}/state/claude-auth/claude.json"
  fi
  if [[ -f "${ROOT}/state/claude-auth/credentials.json" ]]; then
    cp "${ROOT}/state/claude-auth/credentials.json" "${X86_ROOT}/state/claude-auth/credentials.json"
    chmod 0600 "${X86_ROOT}/state/claude-auth/credentials.json"
  fi
else
  rm -rf "${X86_ROOT}/state/claude-auth"
fi
