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
OPENSHELL_CLUSTER_IMAGE="${OPENSHELL_CLUSTER_IMAGE:-ghcr.io/nvidia/openshell/cluster@sha256:74b26e485d9263102018a7bf41a62c8cfc93117ff1594da67f007c61d0fcf246}"
OPENSHELL_GATEWAY_IMAGE="${OPENSHELL_GATEWAY_IMAGE:-ghcr.io/nvidia/openshell/gateway:0.0.42}"
export OPENCLAW_RELEASE OPENCLAW_OFFICIAL_PLUGIN_RELEASE OPENCLAW_OFFICIAL_CHANNEL_PLUGINS OPENSHELL_CLUSTER_IMAGE OPENSHELL_GATEWAY_IMAGE
CLUSTER_CONTAINER="${CLUSTER_CONTAINER:-openshell-cluster-nemox86}"
CLUSTER_IMAGE="${CLUSTER_IMAGE:-${OPENSHELL_CLUSTER_IMAGE}}"
CLUSTER_NETWORK="${CLUSTER_NETWORK:-openshell-cluster-nemox86}"
CLUSTER_VOLUME="${CLUSTER_VOLUME:-openshell-cluster-nemox86}"
RESET_CLUSTER_STATE="${RESET_CLUSTER_STATE:-0}"
CLUSTER_NODE_NAME="${CLUSTER_NODE_NAME:-openshell-x86}"
NAMESPACE="${NAMESPACE:-openshell}"
SANDBOX="${SANDBOX:-nemox86worker}"
CONFIG_SECRET="${CONFIG_SECRET:-openclaw-config-${SANDBOX}}"
MODEL_AUTH_SECRET="${MODEL_AUTH_SECRET:-openclaw-model-auth}"
CLAUDE_AUTH_SECRET="${CLAUDE_AUTH_SECRET:-openclaw-claude-auth}"
IMAGE_TAG="${IMAGE_TAG:-openshell/sandbox-from:x86-nemobot}"
LAB_CONTROL_IMAGE_TAG="${LAB_CONTROL_IMAGE_TAG:-openclaw-lab-control:local}"
VM_RUNNER_IMAGE_TAG="${VM_RUNNER_IMAGE_TAG:-openclaw-vm-runner:local}"
SKIP_IMAGE_PUBLISH="${SKIP_IMAGE_PUBLISH:-0}"
SKIP_LAB_IMAGE_PUBLISH="${SKIP_LAB_IMAGE_PUBLISH:-0}"
SKIP_VM_RUNNER_IMAGE_PUBLISH="${SKIP_VM_RUNNER_IMAGE_PUBLISH:-0}"
MGMT_PORT="${MGMT_PORT:-18080}"
GATEWAY_NODEPORT="${GATEWAY_NODEPORT:-31989}"
GATEWAY_HOST_PORT="${GATEWAY_HOST_PORT:-19189}"
WORKSPACE_FILES=(AGENTS.md TOOLS.md USER.md SOUL.md HEARTBEAT.md IDENTITY.md)
WORKSPACE_DIRS=(workspace workspace-researcher workspace-analyzer workspace-verifier)
IMAGE_TAR=""
LAB_NAMESPACE="${LAB_NAMESPACE:-openshell-lab}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "missing docker compose" >&2
    exit 1
  fi
}

host_gateway_bind() {
  docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}'
}

ensure_port_free() {
  local port="$1"
  local owner="${2:-}"
  if ss -ltn "( sport = :${port} )" | grep -q ":${port}"; then
    if [[ -n "${owner}" ]] && docker ps --format '{{.Names}}' | grep -Fxq "${owner}"; then
      return 0
    fi
    echo "port ${port} is already in use" >&2
    exit 1
  fi
}

start_cluster() {
  ensure_port_free "${MGMT_PORT}" "${CLUSTER_CONTAINER}"
  ensure_port_free "${GATEWAY_HOST_PORT}" "${CLUSTER_CONTAINER}"

  docker rm -f openclaw-x86-lab-worker >/dev/null 2>&1 || true
  if [[ "${RESET_CLUSTER_STATE}" == "1" ]]; then
    docker rm -f "${CLUSTER_CONTAINER}" >/dev/null 2>&1 || true
    docker volume rm -f "${CLUSTER_VOLUME}" >/dev/null 2>&1 || true
    docker network rm "${CLUSTER_NETWORK}" >/dev/null 2>&1 || true
  fi
  docker network create "${CLUSTER_NETWORK}" >/dev/null 2>&1 || true
  docker volume create "${CLUSTER_VOLUME}" >/dev/null 2>&1 || true

  docker rm -f "${CLUSTER_CONTAINER}" >/dev/null 2>&1 || true
  docker run -d \
    --name "${CLUSTER_CONTAINER}" \
    --hostname "${CLUSTER_NODE_NAME}" \
    --restart unless-stopped \
    --privileged \
    --network "${CLUSTER_NETWORK}" \
    --add-host host.docker.internal:host-gateway \
    --add-host host.openshell.internal:host-gateway \
    -p "${MGMT_PORT}:30051" \
    -p "${GATEWAY_HOST_PORT}:${GATEWAY_NODEPORT}" \
    -v "${CLUSTER_VOLUME}:/var/lib/rancher/k3s" \
    "${CLUSTER_IMAGE}" \
    server \
    --disable=traefik \
    --node-name="${CLUSTER_NODE_NAME}" \
    --tls-san=localhost \
    --tls-san=host.docker.internal >/dev/null

  for _ in $(seq 1 120); do
    if docker exec "${CLUSTER_CONTAINER}" kubectl get ns >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "cluster did not become ready in time" >&2
  exit 1
}

cleanup_stale_nodes() {
  docker exec "${CLUSTER_CONTAINER}" kubectl get nodes -o name | sed 's#node/##' | while read -r node; do
    [[ -n "${node}" ]] || continue
    if [[ "${node}" != "${CLUSTER_NODE_NAME}" ]]; then
      docker exec "${CLUSTER_CONTAINER}" kubectl delete node "${node}" --ignore-not-found >/dev/null 2>&1 || true
    fi
  done
}

ensure_tls_secrets() {
  local tmpdir
  tmpdir="$(mktemp -d)"

  cat > "${tmpdir}/server.cnf" <<'EOF'
[req]
prompt = no
default_md = sha256
distinguished_name = dn

[dn]
CN = openshell-server

[cert_ext]
subjectAltName = @alt_names
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash

[alt_names]
DNS.1 = openshell
DNS.2 = openshell.openshell.svc
DNS.3 = openshell.openshell.svc.cluster.local
DNS.4 = localhost
DNS.5 = host.docker.internal
EOF

  cat > "${tmpdir}/client.cnf" <<'EOF'
[req]
prompt = no
default_md = sha256
distinguished_name = dn

[dn]
CN = openshell-client

[cert_ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
EOF

  openssl ecparam -name prime256v1 -genkey -noout -out "${tmpdir}/ca.key" >/dev/null 2>&1
  openssl req -x509 -new -nodes -key "${tmpdir}/ca.key" -sha256 -days 3650 \
    -subj "/CN=openshell-ca/O=openshell" -out "${tmpdir}/ca.crt" >/dev/null 2>&1

  openssl ecparam -name prime256v1 -genkey -noout -out "${tmpdir}/server.key" >/dev/null 2>&1
  openssl req -new -key "${tmpdir}/server.key" -out "${tmpdir}/server.csr" -config "${tmpdir}/server.cnf" >/dev/null 2>&1
  openssl x509 -req -in "${tmpdir}/server.csr" -CA "${tmpdir}/ca.crt" -CAkey "${tmpdir}/ca.key" -CAcreateserial \
    -out "${tmpdir}/server.crt" -days 3650 -sha256 -extensions cert_ext -extfile "${tmpdir}/server.cnf" >/dev/null 2>&1

  openssl ecparam -name prime256v1 -genkey -noout -out "${tmpdir}/client.key" >/dev/null 2>&1
  openssl req -new -key "${tmpdir}/client.key" -out "${tmpdir}/client.csr" -config "${tmpdir}/client.cnf" >/dev/null 2>&1
  openssl x509 -req -in "${tmpdir}/client.csr" -CA "${tmpdir}/ca.crt" -CAkey "${tmpdir}/ca.key" -CAcreateserial \
    -out "${tmpdir}/client.crt" -days 3650 -sha256 -extensions cert_ext -extfile "${tmpdir}/client.cnf" >/dev/null 2>&1

  docker exec "${CLUSTER_CONTAINER}" kubectl -n "${NAMESPACE}" delete secret \
    openshell-server-tls openshell-server-client-ca openshell-client-tls --ignore-not-found >/dev/null 2>&1 || true

  tar -C "${tmpdir}" -cf - server.crt server.key \
    | docker exec -i "${CLUSTER_CONTAINER}" sh -lc "
        rm -rf /tmp/server-tls &&
        mkdir -p /tmp/server-tls &&
        tar -xf - -C /tmp/server-tls &&
        kubectl -n ${NAMESPACE} create secret tls openshell-server-tls \
          --cert=/tmp/server-tls/server.crt \
          --key=/tmp/server-tls/server.key \
          --dry-run=client -o yaml | kubectl apply -f - &&
        rm -rf /tmp/server-tls
      "

  cat "${tmpdir}/ca.crt" | docker exec -i "${CLUSTER_CONTAINER}" sh -lc "
    cat > /tmp/ca.crt &&
    kubectl -n ${NAMESPACE} create secret generic openshell-server-client-ca \
      --from-file=ca.crt=/tmp/ca.crt \
      --dry-run=client -o yaml | kubectl apply -f - &&
    rm -f /tmp/ca.crt
  "

  tar -C "${tmpdir}" -cf - ca.crt client.crt client.key \
    | docker exec -i "${CLUSTER_CONTAINER}" sh -lc "
        rm -rf /tmp/client-tls &&
        mkdir -p /tmp/client-tls &&
        tar -xf - -C /tmp/client-tls &&
        kubectl -n ${NAMESPACE} create secret generic openshell-client-tls \
          --from-file=ca.crt=/tmp/client-tls/ca.crt \
          --from-file=tls.crt=/tmp/client-tls/client.crt \
          --from-file=tls.key=/tmp/client-tls/client.key \
          --dry-run=client -o yaml | kubectl apply -f - &&
        rm -rf /tmp/client-tls
      "

  rm -rf "${tmpdir}"
}

repair_openshell_gateway_state() {
  local describe_out pv selected_node
  describe_out="$(docker exec "${CLUSTER_CONTAINER}" kubectl describe pod -n "${NAMESPACE}" openshell-0 2>/dev/null || true)"
  pv="$(docker exec "${CLUSTER_CONTAINER}" kubectl get pvc -n "${NAMESPACE}" openshell-data-openshell-0 \
    -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  selected_node="$(docker exec "${CLUSTER_CONTAINER}" kubectl get pvc -n "${NAMESPACE}" openshell-data-openshell-0 \
    -o jsonpath='{.metadata.annotations.volume\.kubernetes\.io/selected-node}' 2>/dev/null || true)"

  if ! grep -q "didn't match PersistentVolume's node affinity" <<<"${describe_out}" \
    && [[ -n "${pv}" || "${selected_node}" == "${CLUSTER_NODE_NAME}" ]]; then
    return 0
  fi

  docker exec "${CLUSTER_CONTAINER}" kubectl delete pod -n "${NAMESPACE}" openshell-0 \
    --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
  docker exec "${CLUSTER_CONTAINER}" kubectl delete pvc -n "${NAMESPACE}" openshell-data-openshell-0 \
    --ignore-not-found >/dev/null 2>&1 || true
  if [[ -n "${pv}" ]]; then
    docker exec "${CLUSTER_CONTAINER}" kubectl delete pv "${pv}" --ignore-not-found >/dev/null 2>&1 || true
  fi

  for _ in $(seq 1 120); do
    if docker exec "${CLUSTER_CONTAINER}" kubectl get pod -n "${NAMESPACE}" openshell-0 >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
}

wait_for_helm_install() {
  for _ in $(seq 1 180); do
    local statuses
    statuses="$(
      docker exec "${CLUSTER_CONTAINER}" sh -lc \
        "kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '/helm-install-openshell/ {print \$3}'" \
        2>/dev/null || true
    )"
    if [[ -n "${statuses}" ]] && ! grep -qv '^Completed$' <<<"${statuses}"; then
      return 0
    fi
    sleep 2
  done
  echo "openshell helm install did not complete in time" >&2
  exit 1
}

refresh_supervisor_bin() {
  local helper tmpdir helper_path target_path current_hash desired_hash
  helper="$(docker create "${CLUSTER_IMAGE}")"
  tmpdir="$(mktemp -d)"

  helper_path="${tmpdir}/openshell-sandbox"
  target_path="/opt/openshell/bin/openshell-sandbox"

  docker cp "${helper}:${target_path}" "${helper_path}"
  chmod 0755 "${helper_path}"

  desired_hash="$(sha256sum "${helper_path}" | awk '{print $1}')"
  current_hash="$(
    docker exec "${CLUSTER_CONTAINER}" sh -lc "sha256sum ${target_path} 2>/dev/null | cut -d' ' -f1" \
      2>/dev/null || true
  )"
  if [[ "${current_hash}" == "${desired_hash}" ]]; then
    docker rm -f "${helper}" >/dev/null 2>&1 || true
    rm -rf "${tmpdir}"
    return 0
  fi

  docker cp "${helper_path}" "${CLUSTER_CONTAINER}:${target_path}"
  docker exec "${CLUSTER_CONTAINER}" chmod 0755 "${target_path}"
  docker rm -f "${helper}" >/dev/null 2>&1 || true
  rm -rf "${tmpdir}"
}

patch_gateway_chart_bind_address() {
  local chart_path="/var/lib/rancher/k3s/server/static/charts/openshell-0.1.0.tgz"
  local tmpdir template
  tmpdir="$(mktemp -d)"
  docker cp "${CLUSTER_CONTAINER}:${chart_path}" "${tmpdir}/openshell.tgz"
  mkdir -p "${tmpdir}/chart"
  tar -xzf "${tmpdir}/openshell.tgz" -C "${tmpdir}/chart"
  template="${tmpdir}/chart/openshell/templates/statefulset.yaml"
  python3 - "${template}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = "          args:\n            - --port"
replacement = "          args:\n            - --bind-address\n            - 0.0.0.0\n            - --port"
if "--bind-address" not in text:
    if needle not in text:
        raise SystemExit("failed to locate gateway args block in chart template")
    text = text.replace(needle, replacement, 1)
    path.write_text(text)
PY
  tar -czf "${tmpdir}/openshell.patched.tgz" -C "${tmpdir}/chart" openshell
  docker cp "${tmpdir}/openshell.patched.tgz" "${CLUSTER_CONTAINER}:${chart_path}"
  rm -rf "${tmpdir}"
}

patch_gateway_statefulset_bind_address() {
  local tmpfile
  tmpfile="$(mktemp)"
  docker exec "${CLUSTER_CONTAINER}" kubectl get statefulset -n "${NAMESPACE}" openshell -o yaml > "${tmpfile}"
  python3 - "${tmpfile}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = "        - --port\n        - \"8080\""
replacement = "        - --bind-address\n        - 0.0.0.0\n        - --port\n        - \"8080\""
if "--bind-address" not in text:
    if needle not in text:
        raise SystemExit("failed to locate gateway args block in statefulset")
    text = text.replace(needle, replacement, 1)
    path.write_text(text)
PY
  docker exec -i "${CLUSTER_CONTAINER}" kubectl apply -f - < "${tmpfile}"
  rm -f "${tmpfile}"
}

ensure_namespace() {
  docker exec "${CLUSTER_CONTAINER}" kubectl create namespace "${NAMESPACE}" \
    --dry-run=client -o yaml | docker exec -i "${CLUSTER_CONTAINER}" kubectl apply -f -
}

ensure_ssh_handshake_secret() {
  local ssh_secret
  ssh_secret="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
  docker exec "${CLUSTER_CONTAINER}" kubectl -n "${NAMESPACE}" create secret generic openshell-ssh-handshake \
    --from-literal=secret="${ssh_secret}" \
    --dry-run=client -o yaml | docker exec -i "${CLUSTER_CONTAINER}" kubectl apply -f -
}

rewrite_gateway_image_refs() {
  local file="$1"
  local tmpfile
  tmpfile="$(mktemp)"

  cat "${file}" > "${tmpfile}"
  python3 - "${OPENSHELL_GATEWAY_IMAGE}" "${tmpfile}" <<'PY'
import pathlib
import re
import sys

image = sys.argv[1]
path = pathlib.Path(sys.argv[2])
if ":" not in image:
    raise SystemExit(f"expected image tag, got: {image}")
repo, tag = image.rsplit(":", 1)
text = path.read_text()
pattern = re.compile(
    r"(?ms)(\n\s+image:\n\s+repository:\s+)(\S+)"
    r"(\n\s+tag:\s+)(\S+)"
    r"(\n\s+pullPolicy:\s+)(\S+)"
)
updated, count = pattern.subn(
    lambda match: (
        f"{match.group(1)}{repo}"
        f"{match.group(3)}{tag}"
        f"{match.group(5)}Always"
    ),
    text,
    count=1,
)
if count != 1:
    raise SystemExit("failed to locate gateway image block")
path.write_text(updated)
PY
  cat "${tmpfile}"
  rm -f "${tmpfile}"
}

pin_gateway_manifest() {
  local manifest_path="/var/lib/rancher/k3s/server/manifests/openshell-helmchart.yaml"
  local tmpfile
  tmpfile="$(mktemp)"

  docker exec "${CLUSTER_CONTAINER}" sh -lc "cat ${manifest_path}" > "${tmpfile}"
  rewrite_gateway_image_refs "${tmpfile}" \
    | docker exec -i "${CLUSTER_CONTAINER}" sh -lc "cat > ${manifest_path}"
  rm -f "${tmpfile}"
}

pin_gateway_helmchart() {
  local tmpfile
  if ! docker exec "${CLUSTER_CONTAINER}" kubectl get helmchart -n kube-system openshell >/dev/null 2>&1; then
    return 0
  fi

  tmpfile="$(mktemp)"

  docker exec "${CLUSTER_CONTAINER}" kubectl get helmchart -n kube-system openshell -o yaml > "${tmpfile}"
  rewrite_gateway_image_refs "${tmpfile}" \
    | docker exec -i "${CLUSTER_CONTAINER}" kubectl apply -f -
  rm -f "${tmpfile}"
}

reconcile_gateway_release() {
  docker exec "${CLUSTER_CONTAINER}" kubectl delete job -n kube-system -l helmcharts.cattle.io/chart=openshell \
    --ignore-not-found >/dev/null 2>&1 || true
  docker exec "${CLUSTER_CONTAINER}" kubectl delete pod -n "${NAMESPACE}" openshell-0 \
    --ignore-not-found >/dev/null 2>&1 || true
}

pin_gateway_image() {
  for _ in $(seq 1 120); do
    if docker exec "${CLUSTER_CONTAINER}" kubectl get statefulset -n "${NAMESPACE}" openshell >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  docker exec "${CLUSTER_CONTAINER}" kubectl set image -n "${NAMESPACE}" \
    statefulset/openshell "openshell=${OPENSHELL_GATEWAY_IMAGE}" >/dev/null
}

wait_for_openshell_ready() {
  for _ in $(seq 1 180); do
    local image ready
    image="$(
      docker exec "${CLUSTER_CONTAINER}" kubectl get statefulset -n "${NAMESPACE}" openshell \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
    )"
    if [[ -n "${image}" && "${image}" != "${OPENSHELL_GATEWAY_IMAGE}" ]]; then
      docker exec "${CLUSTER_CONTAINER}" kubectl set image -n "${NAMESPACE}" \
        statefulset/openshell "openshell=${OPENSHELL_GATEWAY_IMAGE}" >/dev/null 2>&1 || true
      sleep 2
      continue
    fi
    ready="$(
      docker exec "${CLUSTER_CONTAINER}" kubectl get pod -n "${NAMESPACE}" openshell-0 \
        -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true
    )"
    if [[ "${image}" == "${OPENSHELL_GATEWAY_IMAGE}" && "${ready}" == "true" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "openshell gateway did not settle on ${OPENSHELL_GATEWAY_IMAGE}" >&2
  exit 1
}

start_host_helpers() {
  local gateway_ip
  gateway_ip="$(host_gateway_bind)"
  local compose_args=(-f "${ROOT}/browser/docker-compose.yml")
  if [[ -f "${ROOT}/state/nvidia-proxy.env" ]]; then
    compose_args+=(--profile nvidia-proxy)
  fi
  if [[ -f "${ROOT}/state/anthropic-proxy.env" ]]; then
    compose_args+=(--profile anthropic-proxy)
  fi
  if [[ -f "${ROOT}/state/perplexity-proxy.env" ]]; then
    compose_args+=(--profile perplexity-proxy)
  fi

  HOST_GATEWAY_BIND="${gateway_ip}" compose_cmd "${compose_args[@]}" up -d
}

publish_image() {
  DOCKER_BUILDKIT=0 docker build \
    --build-arg OPENCLAW_RELEASE="${OPENCLAW_RELEASE}" \
    -t "${IMAGE_TAG}" \
    -f "${ROOT}/Dockerfile.sandbox" \
    "${ROOT}"
  import_image "${IMAGE_TAG}" "openshell-x86-image"
}

import_image() {
  local image_tag="$1"
  local prefix="$2"
  local image_tar
  docker exec "${CLUSTER_CONTAINER}" ctr -n k8s.io images rm "docker.io/${image_tag}" >/dev/null 2>&1 || true
  image_tar="$(mktemp "/tmp/${prefix}-XXXXXX.tar")"
  docker save -o "${image_tar}" "${image_tag}"
  docker cp "${image_tar}" "${CLUSTER_CONTAINER}:/tmp/$(basename "${image_tar}")"
  docker exec "${CLUSTER_CONTAINER}" sh -lc "
    ctr -n k8s.io images import /tmp/$(basename "${image_tar}") &&
    rm -f /tmp/$(basename "${image_tar}")
  "
  rm -f "${image_tar}"
}

publish_lab_control_image() {
  DOCKER_BUILDKIT=0 docker build -t "${LAB_CONTROL_IMAGE_TAG}" -f "${ROOT}/Dockerfile.lab-control" "${ROOT}"
  import_image "${LAB_CONTROL_IMAGE_TAG}" "openshell-x86-lab-control"
}

publish_vm_runner_image() {
  DOCKER_BUILDKIT=0 docker build -t "${VM_RUNNER_IMAGE_TAG}" -f "${ROOT}/Dockerfile.vm-runner" "${ROOT}"
  import_image "${VM_RUNNER_IMAGE_TAG}" "openshell-x86-vm-runner"
}

apply_state() {
  cat "${ROOT}/state/openclaw.json" | docker exec -i "${CLUSTER_CONTAINER}" sh -lc "
    cat > /tmp/openclaw.json &&
    kubectl -n ${NAMESPACE} create secret generic ${CONFIG_SECRET} \
      --from-file=openclaw.json=/tmp/openclaw.json \
      --dry-run=client -o yaml | kubectl apply -f - &&
    rm -f /tmp/openclaw.json
  "

  if [[ -f "${ROOT}/state/model-auth.env" ]]; then
    cat "${ROOT}/state/model-auth.env" | docker exec -i "${CLUSTER_CONTAINER}" sh -lc "
      cat > /tmp/model-auth.env &&
      kubectl -n ${NAMESPACE} create secret generic ${MODEL_AUTH_SECRET} \
        --from-env-file=/tmp/model-auth.env \
        --dry-run=client -o yaml | kubectl apply -f - &&
      rm -f /tmp/model-auth.env
    "
  fi

  if [[ -d "${ROOT}/state/claude-auth" ]] && [[ -f "${ROOT}/state/claude-auth/claude.json" || -f "${ROOT}/state/claude-auth/credentials.json" ]]; then
    docker exec "${CLUSTER_CONTAINER}" sh -lc "rm -rf /tmp/claude-auth && mkdir -p /tmp/claude-auth"
    if [[ -f "${ROOT}/state/claude-auth/claude.json" ]]; then
      docker cp "${ROOT}/state/claude-auth/claude.json" "${CLUSTER_CONTAINER}:/tmp/claude-auth/claude.json"
    fi
    if [[ -f "${ROOT}/state/claude-auth/credentials.json" ]]; then
      docker cp "${ROOT}/state/claude-auth/credentials.json" "${CLUSTER_CONTAINER}:/tmp/claude-auth/credentials.json"
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

  local dir_name
  for dir_name in "${WORKSPACE_DIRS[@]}"; do
    tar -C "${ROOT}/state/${dir_name}" -cf - "${WORKSPACE_FILES[@]}" \
      | docker exec -i "${CLUSTER_CONTAINER}" sh -lc "
          rm -rf /tmp/${dir_name} &&
          mkdir -p /tmp/${dir_name} &&
          tar -xf - -C /tmp/${dir_name} &&
          kubectl -n ${NAMESPACE} create configmap openclaw-${dir_name}-${SANDBOX} \
            --from-file=/tmp/${dir_name} \
            --dry-run=client -o yaml | kubectl apply -f - &&
          rm -rf /tmp/${dir_name}
        "
  done
}

apply_sandbox() {
  local sandbox_id ssh_secret gateway_ip model_auth_env_block claude_auth_mount_block claude_auth_volume_block
  sandbox_id="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
  ssh_secret="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
  gateway_ip="$(host_gateway_bind)"
  if [[ -f "${ROOT}/state/model-auth.env" ]]; then
    model_auth_env_block="$(cat <<EOF
          envFrom:
            - secretRef:
                name: ${MODEL_AUTH_SECRET}
EOF
)"
  else
    model_auth_env_block="          envFrom: []"
  fi
  if [[ -f "${ROOT}/state/claude-auth/claude.json" || -f "${ROOT}/state/claude-auth/credentials.json" ]]; then
    claude_auth_mount_block="$(cat <<EOF
            - name: openclaw-claude-auth
              mountPath: /opt/openclaw-nemobot/claude-auth
              readOnly: true
EOF
)"
    claude_auth_volume_block="$(cat <<EOF
        - name: openclaw-claude-auth
          secret:
            secretName: ${CLAUDE_AUTH_SECRET}
EOF
)"
  else
    claude_auth_mount_block=""
    claude_auth_volume_block=""
  fi

  docker exec "${CLUSTER_CONTAINER}" kubectl delete sandbox -n "${NAMESPACE}" "${SANDBOX}" \
    --ignore-not-found >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    if ! docker exec "${CLUSTER_CONTAINER}" kubectl get sandbox -n "${NAMESPACE}" "${SANDBOX}" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  cat <<EOF | docker exec -i "${CLUSTER_CONTAINER}" kubectl apply -f -
apiVersion: agents.x-k8s.io/v1alpha1
kind: Sandbox
metadata:
  name: ${SANDBOX}
  namespace: ${NAMESPACE}
  labels:
    openshell.ai/managed-by: openshell
    openshell.ai/sandbox-id: ${sandbox_id}
spec:
  podTemplate:
    spec:
      containers:
        - name: agent
          image: ${IMAGE_TAG}
          imagePullPolicy: Never
          command:
            - /usr/local/bin/openclaw-entrypoint
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
              value: ${sandbox_id}
            - name: OPENSHELL_SSH_HANDSHAKE_SECRET
              value: ${ssh_secret}
${model_auth_env_block}
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
              mountPath: /opt/openclaw-nemobot/openclaw.json
              subPath: openclaw.json
              readOnly: true
            - name: openclaw-workspace
              mountPath: /opt/openclaw-nemobot/workspace
              readOnly: true
            - name: openclaw-workspace-researcher
              mountPath: /opt/openclaw-nemobot/workspace-researcher
              readOnly: true
            - name: openclaw-workspace-analyzer
              mountPath: /opt/openclaw-nemobot/workspace-analyzer
              readOnly: true
            - name: openclaw-workspace-verifier
              mountPath: /opt/openclaw-nemobot/workspace-verifier
              readOnly: true
${claude_auth_mount_block}
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
        - name: openclaw-workspace
          configMap:
            name: openclaw-workspace-${SANDBOX}
        - name: openclaw-workspace-researcher
          configMap:
            name: openclaw-workspace-researcher-${SANDBOX}
        - name: openclaw-workspace-analyzer
          configMap:
            name: openclaw-workspace-analyzer-${SANDBOX}
        - name: openclaw-workspace-verifier
          configMap:
            name: openclaw-workspace-verifier-${SANDBOX}
${claude_auth_volume_block}
EOF

  docker exec "${CLUSTER_CONTAINER}" kubectl delete pod -n "${NAMESPACE}" "${SANDBOX}" \
    --ignore-not-found >/dev/null 2>&1 || true

  for _ in $(seq 1 120); do
    if docker exec "${CLUSTER_CONTAINER}" kubectl get pod -n "${NAMESPACE}" "${SANDBOX}" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  docker exec "${CLUSTER_CONTAINER}" kubectl wait --for=condition=Ready "pod/${SANDBOX}" -n "${NAMESPACE}" --timeout=300s
}

publish_gateway() {
  local selector_hash
  selector_hash="$(
    docker exec "${CLUSTER_CONTAINER}" kubectl get svc -n "${NAMESPACE}" "${SANDBOX}" \
      -o jsonpath='{.spec.selector.agents\.x-k8s\.io/sandbox-name-hash}'
  )"

  cat <<EOF | docker exec -i "${CLUSTER_CONTAINER}" kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${SANDBOX}-gateway
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    agents.x-k8s.io/sandbox-name-hash: "${selector_hash}"
  ports:
    - name: http
      port: 18789
      targetPort: 18789
      nodePort: ${GATEWAY_NODEPORT}
EOF
}

deploy_lab_control() {
  cat <<EOF | docker exec -i "${CLUSTER_CONTAINER}" kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${LAB_NAMESPACE}
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: openclaw-lab-quota
  namespace: ${LAB_NAMESPACE}
spec:
  hard:
    count/jobs.batch: "20"
    count/pods: "20"
    requests.cpu: "8"
    limits.cpu: "16"
    requests.memory: 16Gi
    limits.memory: 32Gi
---
apiVersion: v1
kind: LimitRange
metadata:
  name: openclaw-lab-limits
  namespace: ${LAB_NAMESPACE}
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: 250m
        memory: 256Mi
      default:
        cpu: "1"
        memory: 1Gi
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: lab-control
  namespace: ${LAB_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: lab-control
  namespace: ${LAB_NAMESPACE}
rules:
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: lab-control
  namespace: ${LAB_NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: lab-control
    namespace: ${LAB_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: lab-control
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lab-control
  namespace: ${LAB_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lab-control
  template:
    metadata:
      labels:
        app: lab-control
    spec:
      serviceAccountName: lab-control
      automountServiceAccountToken: true
      containers:
        - name: app
          image: ${LAB_CONTROL_IMAGE_TAG}
          imagePullPolicy: Never
          env:
            - name: LAB_NAMESPACE
              value: ${LAB_NAMESPACE}
            - name: VM_RUNNER_IMAGE
              value: ${VM_RUNNER_IMAGE_TAG}
          ports:
            - containerPort: 8090
              name: http
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            runAsGroup: 65532
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
      restartPolicy: Always
---
apiVersion: v1
kind: Service
metadata:
  name: lab-control
  namespace: ${LAB_NAMESPACE}
spec:
  selector:
    app: lab-control
  ports:
    - name: http
      port: 8090
      targetPort: http
EOF

  docker exec "${CLUSTER_CONTAINER}" kubectl rollout status deployment/lab-control -n "${LAB_NAMESPACE}" --timeout=300s
}

verify() {
  docker exec "${CLUSTER_CONTAINER}" kubectl exec -n "${NAMESPACE}" "${SANDBOX}" -- openclaw status --json >/dev/null
  curl -fsS "http://localhost:${GATEWAY_HOST_PORT}/healthz" >/dev/null
  docker exec "${CLUSTER_CONTAINER}" kubectl exec -n "${NAMESPACE}" "${SANDBOX}" -- \
    curl -fsS "http://lab-control.${LAB_NAMESPACE}.svc.cluster.local:8090/healthz" >/dev/null
}

require_cmd curl
require_cmd docker
require_cmd openssl
require_cmd python3
start_cluster
refresh_supervisor_bin
patch_gateway_chart_bind_address
ensure_namespace
ensure_ssh_handshake_secret
cleanup_stale_nodes
ensure_tls_secrets
repair_openshell_gateway_state
pin_gateway_manifest
pin_gateway_helmchart
reconcile_gateway_release
wait_for_helm_install
pin_gateway_helmchart
pin_gateway_image
patch_gateway_statefulset_bind_address
wait_for_openshell_ready
start_host_helpers
if [[ "${SKIP_IMAGE_PUBLISH}" != "1" ]]; then
  publish_image
fi
if [[ "${SKIP_LAB_IMAGE_PUBLISH}" != "1" ]]; then
  publish_lab_control_image
fi
if [[ "${SKIP_VM_RUNNER_IMAGE_PUBLISH}" != "1" ]]; then
  publish_vm_runner_image
fi
apply_state
apply_sandbox
publish_gateway
deploy_lab_control
verify

echo "cluster_container=${CLUSTER_CONTAINER}"
echo "sandbox=${SANDBOX}"
echo "gateway_url=http://$(hostname -I | awk '{print $1}'):${GATEWAY_HOST_PORT}/v1/chat/completions"
