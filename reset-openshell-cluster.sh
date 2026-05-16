#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${ROOT}/release.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT}/release.env"
fi

OPENSHELL_CLUSTER_IMAGE="${OPENSHELL_CLUSTER_IMAGE:-ghcr.io/nvidia/openshell/cluster@sha256:74b26e485d9263102018a7bf41a62c8cfc93117ff1594da67f007c61d0fcf246}"
OPENSHELL_GATEWAY_IMAGE="${OPENSHELL_GATEWAY_IMAGE:-ghcr.io/nvidia/openshell/gateway:0.0.42}"
CLUSTER_CONTAINER="${CLUSTER_CONTAINER:-openshell-cluster-nemobot}"
LEGACY_CLUSTER_CONTAINER="${LEGACY_CLUSTER_CONTAINER:-openshell-cluster-nemoclaw}"
CLUSTER_NETWORK="${CLUSTER_NETWORK:-openshell-cluster-nemobot}"
LEGACY_CLUSTER_NETWORK="${LEGACY_CLUSTER_NETWORK:-openshell-cluster-nemoclaw}"
CLUSTER_VOLUME="${CLUSTER_VOLUME:-openshell-cluster-nemobot}"
LEGACY_CLUSTER_VOLUME="${LEGACY_CLUSTER_VOLUME:-openshell-cluster-nemoclaw}"
CLUSTER_NODE_NAME="${CLUSTER_NODE_NAME:-openshell-pi}"
MGMT_PORT="${MGMT_PORT:-8080}"
NAMESPACE="${NAMESPACE:-openshell}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
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
  docker rm -f "${LEGACY_CLUSTER_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${CLUSTER_CONTAINER}" >/dev/null 2>&1 || true
  docker volume rm -f "${LEGACY_CLUSTER_VOLUME}" >/dev/null 2>&1 || true
  docker volume rm -f "${CLUSTER_VOLUME}" >/dev/null 2>&1 || true
  docker network rm "${LEGACY_CLUSTER_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${CLUSTER_NETWORK}" >/dev/null 2>&1 || true

  ensure_port_free "${MGMT_PORT}"
  docker network create "${CLUSTER_NETWORK}" >/dev/null
  docker volume create "${CLUSTER_VOLUME}" >/dev/null

  docker run -d \
    --name "${CLUSTER_CONTAINER}" \
    --hostname "${CLUSTER_NODE_NAME}" \
    --restart unless-stopped \
    --privileged \
    --network "${CLUSTER_NETWORK}" \
    --add-host host.docker.internal:host-gateway \
    --add-host host.openshell.internal:host-gateway \
    -p "${MGMT_PORT}:30051" \
    -v "${CLUSTER_VOLUME}:/var/lib/rancher/k3s" \
    "${OPENSHELL_CLUSTER_IMAGE}" \
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

refresh_supervisor_bin() {
  local helper tmpdir helper_path target_path current_hash desired_hash
  helper="$(docker create "${OPENSHELL_CLUSTER_IMAGE}")"
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
  if [[ "${current_hash}" != "${desired_hash}" ]]; then
    docker cp "${helper_path}" "${CLUSTER_CONTAINER}:${target_path}"
    docker exec "${CLUSTER_CONTAINER}" chmod 0755 "${target_path}"
  fi

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

require_cmd docker
require_cmd openssl
require_cmd python3
require_cmd ss

start_cluster
ensure_namespace
ensure_ssh_handshake_secret
ensure_tls_secrets
refresh_supervisor_bin
patch_gateway_chart_bind_address
wait_for_helm_install
pin_gateway_manifest
pin_gateway_helmchart
reconcile_gateway_release
pin_gateway_image
patch_gateway_statefulset_bind_address
wait_for_openshell_ready

echo "OpenShell cluster reset complete:"
echo "  container: ${CLUSTER_CONTAINER}"
echo "  cluster image: ${OPENSHELL_CLUSTER_IMAGE}"
echo "  gateway image: ${OPENSHELL_GATEWAY_IMAGE}"
