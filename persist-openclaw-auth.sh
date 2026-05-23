#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT}/state}"
CLUSTER_CONTAINER="${CLUSTER_CONTAINER:-openshell-cluster-nemobot}"
NAMESPACE="${NAMESPACE:-openshell}"
SANDBOX="${SANDBOX:-nemobot}"
CONFIG_PATH="${CONFIG_PATH:-${STATE_DIR}/openclaw.json}"
OPENCLAW_AUTH_TAR_PATH="${OPENCLAW_AUTH_TAR_PATH:-${STATE_DIR}/openclaw-auth.tar}"

mkdir -p "${STATE_DIR}"

docker exec "${CLUSTER_CONTAINER}" kubectl exec -n "${NAMESPACE}" "${SANDBOX}" -- \
  cat /root/.openclaw/openclaw.json > "${CONFIG_PATH}"
chmod 0600 "${CONFIG_PATH}"

tmp_path="${OPENCLAW_AUTH_TAR_PATH}.tmp"
docker exec "${CLUSTER_CONTAINER}" kubectl exec -n "${NAMESPACE}" "${SANDBOX}" -- sh -lc '
set -eu
cd /root/.openclaw
python3 - <<'"'"'PY'"'"'
import json
from pathlib import Path

root = Path("/root/.openclaw")
config = json.loads((root / "openclaw.json").read_text())
agent_ids = {
    "main",
    "communicator",
    "general_assistant",
    "vuln_researcher",
    "orchestrator",
    "researcher",
    "analyzer",
    "verifier",
}
for agent in config.get("agents", {}).get("list", []):
    if isinstance(agent, dict) and agent.get("id"):
        agent_ids.add(agent["id"])

profile_source = None
state_source = None
for path in sorted(root.glob("agents/*/agent/auth-profiles.json")):
    try:
        data = json.loads(path.read_text())
    except Exception:
        continue
    profiles = data.get("profiles", {})
    if any(
        isinstance(profile, dict) and profile.get("provider") == "openai-codex"
        for profile in profiles.values()
    ):
        profile_source = path
        state_candidate = path.with_name("auth-state.json")
        if state_candidate.exists():
            state_source = state_candidate
        break

if profile_source is None:
    raise SystemExit("no OpenClaw Codex auth profile found")

profile_text = profile_source.read_text()
state_text = state_source.read_text() if state_source else None
for agent_id in sorted(agent_ids):
    agent_dir = root / "agents" / agent_id / "agent"
    agent_dir.mkdir(parents=True, exist_ok=True)
    (agent_dir / "auth-profiles.json").write_text(profile_text)
    if state_text is not None:
        (agent_dir / "auth-state.json").write_text(state_text)
PY
paths=""
if [ -d credentials/auth-profiles ]; then
  paths="${paths} credentials/auth-profiles"
fi
for path in agents/*/agent/auth-profiles.json agents/*/agent/auth-state.json; do
  if [ -f "${path}" ]; then
    paths="${paths} ${path}"
  fi
done
if [ -z "${paths}" ]; then
  echo "no OpenClaw auth profiles found" >&2
  exit 3
fi
tar -cf - ${paths}
' > "${tmp_path}"
mv "${tmp_path}" "${OPENCLAW_AUTH_TAR_PATH}"
chmod 0600 "${OPENCLAW_AUTH_TAR_PATH}"

echo "persisted OpenClaw config to ${CONFIG_PATH}"
echo "persisted OpenClaw auth to ${OPENCLAW_AUTH_TAR_PATH}"
