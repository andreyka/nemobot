#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${ROOT}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT}/release.env"
fi
OPENCLAW_RELEASE="${OPENCLAW_RELEASE:-2026.5.20}"
OPENCLAW_OFFICIAL_PLUGIN_RELEASE="${OPENCLAW_OFFICIAL_PLUGIN_RELEASE:-${OPENCLAW_RELEASE}}"
OPENCLAW_OFFICIAL_CHANNEL_PLUGINS="${OPENCLAW_OFFICIAL_CHANNEL_PLUGINS:-@openclaw/slack}"
export OPENCLAW_RELEASE OPENCLAW_OFFICIAL_PLUGIN_RELEASE OPENCLAW_OFFICIAL_CHANNEL_PLUGINS
STATE_DIR="${STATE_DIR:-${ROOT}/state}"
TEMPLATE_DIR="${TEMPLATE_DIR:-${ROOT}/templates}"
BACKUP_DIR_BASE="${BACKUP_DIR_BASE:-${ROOT}/backups}"
BACKUP_DIR="${BACKUP_DIR_BASE}/$(date +%Y%m%d-%H%M%S)"

CLUSTER_CONTAINER="${CLUSTER_CONTAINER:-openshell-cluster-nemobot}"
NAMESPACE="${NAMESPACE:-openshell}"
SANDBOX="${SANDBOX:-nemobot}"
SOURCE_SANDBOX="${SOURCE_SANDBOX:-nemobot}"
CONFIG_SECRET="${CONFIG_SECRET:-openclaw-config-${SANDBOX}}"
ENV_FILE_PATH="${ENV_FILE_PATH:-${STATE_DIR}/runtime.env}"
ENV_SECRET="${ENV_SECRET:-openclaw-env-${SANDBOX}}"
MODEL_AUTH_ENV_FILE_PATH="${MODEL_AUTH_ENV_FILE_PATH:-${STATE_DIR}/model-auth.env}"
MODEL_AUTH_ENV_SECRET="${MODEL_AUTH_ENV_SECRET:-openclaw-model-auth}"
CLAUDE_AUTH_DIR="${CLAUDE_AUTH_DIR:-${STATE_DIR}/claude-auth}"
CLAUDE_AUTH_SECRET="${CLAUDE_AUTH_SECRET:-openclaw-claude-auth}"
OPENCLAW_AUTH_TAR_PATH="${OPENCLAW_AUTH_TAR_PATH:-${STATE_DIR}/openclaw-auth.tar}"
OPENCLAW_AUTH_SECRET="${OPENCLAW_AUTH_SECRET:-openclaw-auth-${SANDBOX}}"
CODEX_AUTH_TAR_PATH="${CODEX_AUTH_TAR_PATH:-${STATE_DIR}/codex-auth.tar}"
CODEX_AUTH_SECRET="${CODEX_AUTH_SECRET:-codex-auth-${SANDBOX}}"
IMAGE_TAG="${IMAGE_TAG:-openshell/sandbox-from:nemobot}"
SKIP_IMAGE_BUILD="${SKIP_IMAGE_BUILD:-0}"
CONFIG_PATH="${CONFIG_PATH:-${STATE_DIR}/openclaw.json}"
EXEC_APPROVALS_PATH="${EXEC_APPROVALS_PATH:-${STATE_DIR}/exec-approvals.json}"
NEMOBOT_ROOT="${NEMOBOT_ROOT:-/opt/openclaw-nemobot}"
ENTRYPOINT_CMD="${ENTRYPOINT_CMD:-/usr/local/bin/openclaw-entrypoint}"
WORKSPACE_DIRS_DEFAULT=(
  workspace
  workspace-communicator
  workspace-general-assistant
  workspace-vuln-researcher
  workspace-orchestrator
  workspace-researcher
  workspace-analyzer
  workspace-verifier
)
if [[ -n "${WORKSPACE_DIRS_ENV:-}" ]]; then
  read -r -a WORKSPACE_DIRS <<< "${WORKSPACE_DIRS_ENV}"
else
  WORKSPACE_DIRS=("${WORKSPACE_DIRS_DEFAULT[@]}")
fi
WORKSPACE_FILES=(AGENTS.md TOOLS.md USER.md SOUL.md HEARTBEAT.md IDENTITY.md)
REFRESH_LIVE_CONFIG=0
SKIP_LIVE_CONFIG_REFRESH="${SKIP_LIVE_CONFIG_REFRESH:-0}"

if [[ "${1:-}" == "--refresh-live-config" ]]; then
  REFRESH_LIVE_CONFIG=1
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--refresh-live-config]" >&2
  exit 2
fi

resolve_legacy_defaults() {
  if [[ "${CLUSTER_CONTAINER}" == "openshell-cluster-nemobot" ]]; then
    if ! docker ps -a --format '{{.Names}}' | grep -Fxq "${CLUSTER_CONTAINER}" \
      && docker ps -a --format '{{.Names}}' | grep -Fxq "openshell-cluster-nemoclaw"; then
      CLUSTER_CONTAINER="openshell-cluster-nemoclaw"
    fi
  fi
}

resolve_legacy_defaults

mkdir -p "${STATE_DIR}" "${BACKUP_DIR}"
for dir_name in "${WORKSPACE_DIRS[@]}"; do
  mkdir -p "${STATE_DIR}/${dir_name}"
done

host_gateway_bind() {
  docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}'
}

sandbox_exists() {
  docker exec "${CLUSTER_CONTAINER}" kubectl get sandbox -n "${NAMESPACE}" "$1" >/dev/null 2>&1
}

apply_sandbox_from_scratch() {
  local gateway_ip env_from_block workspace_mounts_block workspace_volumes_block claude_auth_mount_block claude_auth_volume_block openclaw_auth_mount_block openclaw_auth_volume_block codex_auth_mount_block codex_auth_volume_block dir_name
  gateway_ip="$(host_gateway_bind)"

  if [[ -f "${ENV_FILE_PATH}" || -f "${MODEL_AUTH_ENV_FILE_PATH}" ]]; then
    env_from_block=""
    if [[ -f "${ENV_FILE_PATH}" ]]; then
      env_from_block+=$'          envFrom:\n'
      printf -v env_from_block '%s            - secretRef:\n                name: %s\n' "${env_from_block}" "${ENV_SECRET}"
    fi
    if [[ -f "${MODEL_AUTH_ENV_FILE_PATH}" ]]; then
      if [[ -z "${env_from_block}" ]]; then
        env_from_block+=$'          envFrom:\n'
      fi
      printf -v env_from_block '%s            - secretRef:\n                name: %s\n' "${env_from_block}" "${MODEL_AUTH_ENV_SECRET}"
    fi
  else
    env_from_block="          envFrom: []"
  fi

  workspace_mounts_block=""
  workspace_volumes_block=""
  claude_auth_mount_block=""
  claude_auth_volume_block=""
  openclaw_auth_mount_block=""
  openclaw_auth_volume_block=""
  codex_auth_mount_block=""
  codex_auth_volume_block=""
  for dir_name in "${WORKSPACE_DIRS[@]}"; do
    printf -v workspace_mounts_block '%s            - name: openclaw-%s\n              mountPath: %s/%s\n              readOnly: true\n' \
      "${workspace_mounts_block}" "${dir_name}" "${NEMOBOT_ROOT}" "${dir_name}"

    printf -v workspace_volumes_block '%s        - name: openclaw-%s\n          configMap:\n            name: openclaw-%s-%s\n' \
      "${workspace_volumes_block}" "${dir_name}" "${dir_name}" "${SANDBOX}"
  done

  if [[ -f "${CLAUDE_AUTH_DIR}/claude.json" || -f "${CLAUDE_AUTH_DIR}/credentials.json" ]]; then
    printf -v claude_auth_mount_block '%s            - name: openclaw-claude-auth\n              mountPath: %s/claude-auth\n              readOnly: true\n' \
      "${claude_auth_mount_block}" "${NEMOBOT_ROOT}"
    printf -v claude_auth_volume_block '%s        - name: openclaw-claude-auth\n          secret:\n            secretName: %s\n' \
      "${claude_auth_volume_block}" "${CLAUDE_AUTH_SECRET}"
  fi

  if [[ -f "${OPENCLAW_AUTH_TAR_PATH}" ]]; then
    printf -v openclaw_auth_mount_block '%s            - name: openclaw-auth\n              mountPath: %s/openclaw-auth/openclaw-auth.tar\n              subPath: openclaw-auth.tar\n              readOnly: true\n' \
      "${openclaw_auth_mount_block}" "${NEMOBOT_ROOT}"
    printf -v openclaw_auth_volume_block '%s        - name: openclaw-auth\n          secret:\n            secretName: %s\n' \
      "${openclaw_auth_volume_block}" "${OPENCLAW_AUTH_SECRET}"
  fi

  if [[ -f "${CODEX_AUTH_TAR_PATH}" ]]; then
    printf -v codex_auth_mount_block '%s            - name: codex-auth\n              mountPath: %s/codex-auth/codex-auth.tar\n              subPath: codex-auth.tar\n              readOnly: true\n' \
      "${codex_auth_mount_block}" "${NEMOBOT_ROOT}"
    printf -v codex_auth_volume_block '%s        - name: codex-auth\n          secret:\n            secretName: %s\n' \
      "${codex_auth_volume_block}" "${CODEX_AUTH_SECRET}"
  fi

  cat <<EOF | docker exec -i "${CLUSTER_CONTAINER}" kubectl apply -f -
apiVersion: agents.x-k8s.io/v1alpha1
kind: Sandbox
metadata:
  name: ${SANDBOX}
  namespace: ${NAMESPACE}
  labels:
    openshell.ai/managed-by: openshell
    openshell.ai/sandbox-id: ${DESIRED_SANDBOX_ID}
spec:
  podTemplate:
    spec:
      containers:
        - name: agent
          image: ${IMAGE_TAG}
          imagePullPolicy: Never
          command:
            - ${ENTRYPOINT_CMD}
          env:
            - name: OPENSHELL_SANDBOX
              value: ${SANDBOX}
            - name: OPENSHELL_ENDPOINT
              value: https://openshell.openshell.svc.cluster.local:8080
            - name: OPENSHELL_SANDBOX_COMMAND
              value: sleep infinity
            - name: OPENSHELL_SSH_LISTEN_ADDR
              value: 0.0.0.0:2222
            - name: OPENSHELL_SSH_HANDSHAKE_SKEW_SECS
              value: "300"
            - name: OPENSHELL_TLS_CA
              value: /etc/openshell-tls/client/ca.crt
            - name: OPENSHELL_TLS_CERT
              value: /etc/openshell-tls/client/tls.crt
            - name: OPENSHELL_TLS_KEY
              value: /etc/openshell-tls/client/tls.key
            - name: OPENSHELL_SANDBOX_ID
              value: ${DESIRED_SANDBOX_ID}
            - name: OPENSHELL_SSH_HANDSHAKE_SECRET
              value: ${DESIRED_SSH_SECRET}
${env_from_block}
          securityContext:
            runAsUser: 0
            capabilities:
              add:
                - SYS_ADMIN
                - NET_ADMIN
                - SYS_PTRACE
                - SYSLOG
          volumeMounts:
            - name: openshell-client-tls
              mountPath: /etc/openshell-tls/client
              readOnly: true
            - name: openshell-supervisor-bin
              mountPath: /opt/openshell/bin
              readOnly: true
            - name: openclaw-config
              mountPath: ${NEMOBOT_ROOT}/openclaw.json
              subPath: openclaw.json
              readOnly: true
            - name: openclaw-config
              mountPath: ${NEMOBOT_ROOT}/exec-approvals.json
              subPath: exec-approvals.json
              readOnly: true
${workspace_mounts_block}
${claude_auth_mount_block}
${openclaw_auth_mount_block}
${codex_auth_mount_block}
      hostAliases:
        - ip: ${gateway_ip}
          hostnames:
            - host.docker.internal
            - host.openshell.internal
      volumes:
        - name: openshell-client-tls
          secret:
            defaultMode: 256
            secretName: openshell-client-tls
        - name: openshell-supervisor-bin
          hostPath:
            path: /opt/openshell/bin
            type: DirectoryOrCreate
        - name: openclaw-config
          secret:
            secretName: ${CONFIG_SECRET}
${workspace_volumes_block}
${claude_auth_volume_block}
${openclaw_auth_volume_block}
${codex_auth_volume_block}
EOF
}

TARGET_EXISTS=0
if sandbox_exists "${SANDBOX}"; then
  TARGET_EXISTS=1
  mkdir -p "${BACKUP_DIR}"
  docker exec "${CLUSTER_CONTAINER}" kubectl get sandbox -n "${NAMESPACE}" "${SANDBOX}" -o json > "${BACKUP_DIR}/sandbox-before.json"
  docker exec "${CLUSTER_CONTAINER}" kubectl get pod -n "${NAMESPACE}" "${SANDBOX}" -o json > "${BACKUP_DIR}/pod-before.json"
elif (( REFRESH_LIVE_CONFIG )); then
  echo "sandbox ${SANDBOX} does not exist; cannot refresh live config" >&2
  exit 1
fi

if (( TARGET_EXISTS )) && (( SKIP_LIVE_CONFIG_REFRESH == 0 )) && ((( REFRESH_LIVE_CONFIG )) || [[ ! -s "${CONFIG_PATH}" ]]); then
  docker exec "${CLUSTER_CONTAINER}" kubectl exec -n "${NAMESPACE}" "${SANDBOX}" -- cat /root/.openclaw/openclaw.json > "${CONFIG_PATH}"
  chmod 0600 "${CONFIG_PATH}"
fi

for dir_name in "${WORKSPACE_DIRS[@]}"; do
  state_dir="${STATE_DIR}/${dir_name}"
  live_dir="/root/.openclaw/${dir_name}"
  template_dir="${TEMPLATE_DIR}/${dir_name}"
  if (( TARGET_EXISTS )) && ((( REFRESH_LIVE_CONFIG )) || [[ ! -f "${state_dir}/AGENTS.md" ]]); then
    for name in "${WORKSPACE_FILES[@]}"; do
      if docker exec "${CLUSTER_CONTAINER}" kubectl exec -n "${NAMESPACE}" "${SANDBOX}" -- test -f "${live_dir}/${name}"; then
        docker exec "${CLUSTER_CONTAINER}" kubectl exec -n "${NAMESPACE}" "${SANDBOX}" -- cat "${live_dir}/${name}" > "${state_dir}/${name}"
      elif [[ -f "${template_dir}/${name}" && ! -f "${state_dir}/${name}" ]]; then
        cp "${template_dir}/${name}" "${state_dir}/${name}"
      fi
    done
  fi
done

if [[ "${SKIP_IMAGE_BUILD}" != "1" ]]; then
  DOCKER_BUILDKIT=0 docker build \
    --build-arg OPENCLAW_RELEASE="${OPENCLAW_RELEASE}" \
    -t "${IMAGE_TAG}" \
    -f "${ROOT}/Dockerfile.sandbox" \
    "${ROOT}"
fi
docker exec "${CLUSTER_CONTAINER}" ctr -n k8s.io images rm "docker.io/${IMAGE_TAG}" >/dev/null 2>&1 || true
TMP_IMAGE_TAR="$(mktemp /tmp/openclaw-image-XXXXXX.tar)"
trap 'rm -f "${TMP_IMAGE_TAR}"' EXIT
docker save -o "${TMP_IMAGE_TAR}" "${IMAGE_TAG}"
docker cp "${TMP_IMAGE_TAR}" "${CLUSTER_CONTAINER}:/tmp/$(basename "${TMP_IMAGE_TAR}")"
docker exec "${CLUSTER_CONTAINER}" sh -lc "
  ctr -n k8s.io images import /tmp/$(basename "${TMP_IMAGE_TAR}") &&
  rm -f /tmp/$(basename "${TMP_IMAGE_TAR}")
"

docker exec "${CLUSTER_CONTAINER}" sh -lc "rm -f /tmp/openclaw.json /tmp/exec-approvals.json"
docker cp "${CONFIG_PATH}" "${CLUSTER_CONTAINER}:/tmp/openclaw.json"
secret_cmd="kubectl -n ${NAMESPACE} create secret generic ${CONFIG_SECRET} --from-file=openclaw.json=/tmp/openclaw.json"
if [[ -f "${EXEC_APPROVALS_PATH}" ]]; then
  docker cp "${EXEC_APPROVALS_PATH}" "${CLUSTER_CONTAINER}:/tmp/exec-approvals.json"
  secret_cmd+=" --from-file=exec-approvals.json=/tmp/exec-approvals.json"
fi
docker exec "${CLUSTER_CONTAINER}" sh -lc "
  ${secret_cmd} \
    --dry-run=client -o yaml | kubectl apply -f - &&
  rm -f /tmp/openclaw.json /tmp/exec-approvals.json
"

if [[ -n "${ENV_SECRET}" && -f "${ENV_FILE_PATH}" ]]; then
  cat "${ENV_FILE_PATH}" | docker exec -i "${CLUSTER_CONTAINER}" sh -lc "
    cat > /tmp/runtime.env &&
    kubectl -n ${NAMESPACE} create secret generic ${ENV_SECRET} \
      --from-env-file=/tmp/runtime.env \
      --dry-run=client -o yaml | kubectl apply -f - &&
    rm -f /tmp/runtime.env
  "
fi

if [[ -n "${MODEL_AUTH_ENV_SECRET}" && -f "${MODEL_AUTH_ENV_FILE_PATH}" ]]; then
  cat "${MODEL_AUTH_ENV_FILE_PATH}" | docker exec -i "${CLUSTER_CONTAINER}" sh -lc "
    cat > /tmp/model-auth.env &&
    kubectl -n ${NAMESPACE} create secret generic ${MODEL_AUTH_ENV_SECRET} \
      --from-env-file=/tmp/model-auth.env \
      --dry-run=client -o yaml | kubectl apply -f - &&
    rm -f /tmp/model-auth.env
  "
fi

if [[ -d "${CLAUDE_AUTH_DIR}" ]] && [[ -f "${CLAUDE_AUTH_DIR}/claude.json" || -f "${CLAUDE_AUTH_DIR}/credentials.json" ]]; then
  docker exec "${CLUSTER_CONTAINER}" sh -lc "rm -rf /tmp/claude-auth && mkdir -p /tmp/claude-auth"
  if [[ -f "${CLAUDE_AUTH_DIR}/claude.json" ]]; then
    docker cp "${CLAUDE_AUTH_DIR}/claude.json" "${CLUSTER_CONTAINER}:/tmp/claude-auth/claude.json"
  fi
  if [[ -f "${CLAUDE_AUTH_DIR}/credentials.json" ]]; then
    docker cp "${CLAUDE_AUTH_DIR}/credentials.json" "${CLUSTER_CONTAINER}:/tmp/claude-auth/credentials.json"
  fi
  docker exec "${CLUSTER_CONTAINER}" sh -lc "
    kubectl -n ${NAMESPACE} delete secret ${CLAUDE_AUTH_SECRET} --ignore-not-found >/dev/null 2>&1 || true
    create_args=
    if [ -f /tmp/claude-auth/claude.json ]; then
      create_args=\"\$create_args --from-file=claude.json=/tmp/claude-auth/claude.json\"
    fi
    if [ -f /tmp/claude-auth/credentials.json ]; then
      create_args=\"\$create_args --from-file=credentials.json=/tmp/claude-auth/credentials.json\"
    fi
    if [ -n \"\$create_args\" ]; then
      eval kubectl -n ${NAMESPACE} create secret generic ${CLAUDE_AUTH_SECRET} \$create_args --dry-run=client -o yaml | kubectl apply -f -
    fi
    rm -rf /tmp/claude-auth
  "
fi

if [[ -f "${OPENCLAW_AUTH_TAR_PATH}" ]]; then
  docker cp "${OPENCLAW_AUTH_TAR_PATH}" "${CLUSTER_CONTAINER}:/tmp/openclaw-auth.tar"
  docker exec "${CLUSTER_CONTAINER}" sh -lc "
    kubectl -n ${NAMESPACE} create secret generic ${OPENCLAW_AUTH_SECRET} \
      --from-file=openclaw-auth.tar=/tmp/openclaw-auth.tar \
      --dry-run=client -o yaml | kubectl apply -f - &&
    rm -f /tmp/openclaw-auth.tar
  "
fi

if [[ -f "${CODEX_AUTH_TAR_PATH}" ]]; then
  docker cp "${CODEX_AUTH_TAR_PATH}" "${CLUSTER_CONTAINER}:/tmp/codex-auth.tar"
  docker exec "${CLUSTER_CONTAINER}" sh -lc "
    kubectl -n ${NAMESPACE} create secret generic ${CODEX_AUTH_SECRET} \
      --from-file=codex-auth.tar=/tmp/codex-auth.tar \
      --dry-run=client -o yaml | kubectl apply -f - &&
    rm -f /tmp/codex-auth.tar
  "
fi

for dir_name in "${WORKSPACE_DIRS[@]}"; do
  configmap_name="openclaw-${dir_name}-${SANDBOX}"
  tar -C "${STATE_DIR}/${dir_name}" -cf - "${WORKSPACE_FILES[@]}" \
    | docker exec -i "${CLUSTER_CONTAINER}" sh -lc "
        rm -rf /tmp/${dir_name} &&
        mkdir -p /tmp/${dir_name} &&
        tar -xf - -C /tmp/${dir_name} &&
        kubectl -n ${NAMESPACE} create configmap ${configmap_name} \
          --from-file=/tmp/${dir_name} \
          --dry-run=client -o yaml | kubectl apply -f - &&
        rm -rf /tmp/${dir_name}
      "
done

SOURCE_FOR_SPEC="${SANDBOX}"
if (( TARGET_EXISTS == 0 )); then
  SOURCE_FOR_SPEC="${SOURCE_SANDBOX}"
fi

DESIRED_SANDBOX_ID="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
DESIRED_SSH_SECRET="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"

if (( TARGET_EXISTS == 0 )) && ! sandbox_exists "${SOURCE_FOR_SPEC}"; then
  apply_sandbox_from_scratch
else
  docker exec "${CLUSTER_CONTAINER}" kubectl get sandbox -n "${NAMESPACE}" "${SOURCE_FOR_SPEC}" -o json \
  | python3 -c '
import json
import sys

image_tag = sys.argv[1]
config_secret = sys.argv[2]
nemobot_root = sys.argv[3]
entrypoint_cmd = sys.argv[4]
target_sandbox = sys.argv[5]
env_secret = sys.argv[6]
model_auth_env_secret = sys.argv[7]
claude_auth_secret = sys.argv[8]
has_claude_auth = sys.argv[9] == "1"
openclaw_auth_secret = sys.argv[10]
has_openclaw_auth = sys.argv[11] == "1"
codex_auth_secret = sys.argv[12]
has_codex_auth = sys.argv[13] == "1"
desired_sandbox_id = sys.argv[14]
desired_ssh_secret = sys.argv[15]
workspace_dirs = sys.argv[16:]
doc = json.load(sys.stdin)

doc.pop("status", None)
meta = doc.setdefault("metadata", {})
meta["name"] = target_sandbox
labels = meta.setdefault("labels", {})
label_sandbox_id = labels.get("openshell.ai/sandbox-id")
if label_sandbox_id:
    desired_sandbox_id = label_sandbox_id
else:
    labels["openshell.ai/sandbox-id"] = desired_sandbox_id
for key in ("creationTimestamp", "generation", "managedFields", "resourceVersion", "uid"):
    meta.pop(key, None)

spec = doc["spec"]["podTemplate"]["spec"]
container = next(c for c in spec["containers"] if c["name"] == "agent")
container["image"] = image_tag
container["command"] = [entrypoint_cmd]

env = []
saw_sandbox_id = False
saw_ssh_secret = False
for item in container.get("env", []):
    name = item.get("name")
    if name == "OPENSHELL_SANDBOX":
        env.append({"name": name, "value": target_sandbox})
        continue
    if name == "OPENSHELL_SANDBOX_ID":
        env.append({"name": name, "value": desired_sandbox_id})
        saw_sandbox_id = True
        continue
    if name == "OPENSHELL_SSH_HANDSHAKE_SECRET":
        env.append({"name": name, "value": desired_ssh_secret})
        saw_ssh_secret = True
        continue
    env.append(item)
if not saw_sandbox_id:
    env.append({"name": "OPENSHELL_SANDBOX_ID", "value": desired_sandbox_id})
if not saw_ssh_secret:
    env.append({"name": "OPENSHELL_SSH_HANDSHAKE_SECRET", "value": desired_ssh_secret})
container["env"] = env

env_from = []
if env_secret:
    env_from.append({"secretRef": {"name": env_secret}})
if model_auth_env_secret:
    env_from.append({"secretRef": {"name": model_auth_env_secret}})
container["envFrom"] = env_from

mounts = container.setdefault("volumeMounts", [])
desired_mount = {
    "name": "openclaw-config",
    "mountPath": f"{nemobot_root}/openclaw.json",
    "subPath": "openclaw.json",
    "readOnly": True,
}
exec_approvals_mount = {
    "name": "openclaw-config",
    "mountPath": f"{nemobot_root}/exec-approvals.json",
    "subPath": "exec-approvals.json",
    "readOnly": True,
}
workspace_mounts = [
    {
        "name": f"openclaw-{dir_name}",
        "mountPath": f"{nemobot_root}/{dir_name}",
        "readOnly": True,
    }
    for dir_name in workspace_dirs
]
claude_auth_mount = {
    "name": "openclaw-claude-auth",
    "mountPath": f"{nemobot_root}/claude-auth",
    "readOnly": True,
}
openclaw_auth_mount = {
    "name": "openclaw-auth",
    "mountPath": f"{nemobot_root}/openclaw-auth/openclaw-auth.tar",
    "subPath": "openclaw-auth.tar",
    "readOnly": True,
}
codex_auth_mount = {
    "name": "codex-auth",
    "mountPath": f"{nemobot_root}/codex-auth/codex-auth.tar",
    "subPath": "codex-auth.tar",
    "readOnly": True,
}
filtered_mounts = [
    mount
    for mount in mounts
    if (
        mount.get("name") not in {desired_mount["name"], *{m["name"] for m in workspace_mounts}}
        or mount.get("mountPath") not in {desired_mount["mountPath"], exec_approvals_mount["mountPath"]}
    )
    and not str(mount.get("name", "")).startswith("openclaw-")
    and not any(
        str(mount.get("mountPath", "")) == prefix
        or str(mount.get("mountPath", "")).startswith(f"{prefix}/")
        for prefix in (
            nemobot_root,
            "/opt/nemobot",
        )
    )
]
filtered_mounts.append(desired_mount)
filtered_mounts.append(exec_approvals_mount)
filtered_mounts.extend(workspace_mounts)
if has_claude_auth:
    filtered_mounts.append(claude_auth_mount)
if has_openclaw_auth:
    filtered_mounts.append(openclaw_auth_mount)
if has_codex_auth:
    filtered_mounts.append(codex_auth_mount)
container["volumeMounts"] = filtered_mounts

volumes = spec.setdefault("volumes", [])
desired_volume = {
    "name": "openclaw-config",
    "secret": {"secretName": config_secret},
}
workspace_volumes = [
    {
        "name": f"openclaw-{dir_name}",
        "configMap": {"name": f"openclaw-{dir_name}-{target_sandbox}"},
    }
    for dir_name in workspace_dirs
]
claude_auth_volume = {
    "name": "openclaw-claude-auth",
    "secret": {"secretName": claude_auth_secret},
}
openclaw_auth_volume = {
    "name": "openclaw-auth",
    "secret": {"secretName": openclaw_auth_secret},
}
codex_auth_volume = {
    "name": "codex-auth",
    "secret": {"secretName": codex_auth_secret},
}
filtered_volumes = [
    volume
    for volume in volumes
    if volume.get("name") not in {desired_volume["name"], *{v["name"] for v in workspace_volumes}}
    and not str(volume.get("name", "")).startswith("openclaw-")
    and volume.get("name") != "codex-auth"
]
filtered_volumes.append(desired_volume)
filtered_volumes.extend(workspace_volumes)
if has_claude_auth:
    filtered_volumes.append(claude_auth_volume)
if has_openclaw_auth:
    filtered_volumes.append(openclaw_auth_volume)
if has_codex_auth:
    filtered_volumes.append(codex_auth_volume)
spec["volumes"] = filtered_volumes

json.dump(doc, sys.stdout)
' "${IMAGE_TAG}" "${CONFIG_SECRET}" "${NEMOBOT_ROOT}" "${ENTRYPOINT_CMD}" "${SANDBOX}" "$( [[ -f "${ENV_FILE_PATH}" ]] && printf "%s" "${ENV_SECRET}" )" "$( [[ -f "${MODEL_AUTH_ENV_FILE_PATH}" ]] && printf "%s" "${MODEL_AUTH_ENV_SECRET}" )" "${CLAUDE_AUTH_SECRET}" "$( [[ -f "${CLAUDE_AUTH_DIR}/claude.json" || -f "${CLAUDE_AUTH_DIR}/credentials.json" ]] && printf "1" || printf "0" )" "${OPENCLAW_AUTH_SECRET}" "$( [[ -f "${OPENCLAW_AUTH_TAR_PATH}" ]] && printf "1" || printf "0" )" "${CODEX_AUTH_SECRET}" "$( [[ -f "${CODEX_AUTH_TAR_PATH}" ]] && printf "1" || printf "0" )" "${DESIRED_SANDBOX_ID}" "${DESIRED_SSH_SECRET}" "${WORKSPACE_DIRS[@]}" \
  | docker exec -i "${CLUSTER_CONTAINER}" kubectl apply -f -
fi

if (( TARGET_EXISTS )); then
  docker exec "${CLUSTER_CONTAINER}" kubectl delete pod -n "${NAMESPACE}" "${SANDBOX}" --wait=true
fi
until docker exec "${CLUSTER_CONTAINER}" kubectl get pod -n "${NAMESPACE}" "${SANDBOX}" >/dev/null 2>&1; do
  sleep 1
done
docker exec "${CLUSTER_CONTAINER}" kubectl wait --for=condition=Ready pod/"${SANDBOX}" -n "${NAMESPACE}" --timeout=300s

mkdir -p "${BACKUP_DIR}"
docker exec "${CLUSTER_CONTAINER}" kubectl get sandbox -n "${NAMESPACE}" "${SANDBOX}" -o json > "${BACKUP_DIR}/sandbox-after.json"
docker exec "${CLUSTER_CONTAINER}" kubectl get pod -n "${NAMESPACE}" "${SANDBOX}" -o json > "${BACKUP_DIR}/pod-after.json"
image="$(
  docker exec "${CLUSTER_CONTAINER}" \
    kubectl get sandbox -n "${NAMESPACE}" "${SANDBOX}" \
    -o jsonpath='{.spec.podTemplate.spec.containers[0].image}'
)"
echo "IMAGE=${image}"

for _ in $(seq 1 30); do
  if docker exec "${CLUSTER_CONTAINER}" \
    kubectl exec -n "${NAMESPACE}" "${SANDBOX}" -- \
    sh -lc 'timeout 8 openclaw health --json >/dev/null 2>&1'; then
    break
  fi
  sleep 2
done

docker exec "${CLUSTER_CONTAINER}" kubectl exec -n "${NAMESPACE}" "${SANDBOX}" -- \
  jq -r '[
    (.gateway.bind // "n/a"),
    (.browser.defaultProfile // "n/a"),
    (.browser.evaluateEnabled // false),
    (.channels.slack.groupPolicy // "n/a"),
    (.channels.slack.requireMention // "n/a")
  ] | @tsv' /root/.openclaw/openclaw.json || true
