#!/usr/bin/env bash
set -euo pipefail

BRIDGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${BRIDGE_ROOT}/.." && pwd)"

CLUSTER_CONTAINER="${CLUSTER_CONTAINER:-openshell-cluster-nemobot}"
NAMESPACE="${NAMESPACE:-openshell}"
WORKER_SANDBOX="${WORKER_SANDBOX:-nemoworker}"
WORKER_STATE_DIR="${WORKER_STATE_DIR:-${ROOT}/worker/state}"
IMAGE_TAG="${IMAGE_TAG:-openclaw-worker-bridge:local}"
DEPLOY_NAME="${DEPLOY_NAME:-openclaw-worker-bridge}"
SECRET_NAME="${SECRET_NAME:-openclaw-worker-bridge}"

if [[ "${CLUSTER_CONTAINER}" == "openshell-cluster-nemobot" ]]; then
  if ! docker ps -a --format '{{.Names}}' | grep -Fxq "${CLUSTER_CONTAINER}" \
    && docker ps -a --format '{{.Names}}' | grep -Fxq "openshell-cluster-nemoclaw"; then
    CLUSTER_CONTAINER="openshell-cluster-nemoclaw"
  fi
fi

mkdir -p "${BRIDGE_ROOT}/state"

WORKER_GATEWAY_URL="${WORKER_GATEWAY_URL:-http://${WORKER_SANDBOX}.${NAMESPACE}.svc.cluster.local:18789/v1/chat/completions}"
WORKER_GATEWAY_TOKEN="$(
  python3 - <<'PY' "${WORKER_STATE_DIR}/openclaw.json"
import json, sys
obj = json.load(open(sys.argv[1]))
print(obj["gateway"]["auth"]["token"])
PY
)"

cat > "${BRIDGE_ROOT}/state/worker-bridge.env" <<EOF
WORKER_GATEWAY_URL=${WORKER_GATEWAY_URL}
WORKER_GATEWAY_TOKEN=${WORKER_GATEWAY_TOKEN}
EOF
chmod 0600 "${BRIDGE_ROOT}/state/worker-bridge.env"

docker build -t "${IMAGE_TAG}" -f "${BRIDGE_ROOT}/Dockerfile" "${BRIDGE_ROOT}"
docker exec "${CLUSTER_CONTAINER}" ctr -n k8s.io images rm "docker.io/${IMAGE_TAG}" >/dev/null 2>&1 || true
TMP_IMAGE_TAR="$(mktemp /tmp/openclaw-worker-bridge-XXXXXX.tar)"
trap 'rm -f "${TMP_IMAGE_TAR}"' EXIT
docker save -o "${TMP_IMAGE_TAR}" "${IMAGE_TAG}"
docker cp "${TMP_IMAGE_TAR}" "${CLUSTER_CONTAINER}:/tmp/$(basename "${TMP_IMAGE_TAR}")"
docker exec "${CLUSTER_CONTAINER}" sh -lc "
  ctr -n k8s.io images import /tmp/$(basename "${TMP_IMAGE_TAR}") &&
  rm -f /tmp/$(basename "${TMP_IMAGE_TAR}")
"

cat "${BRIDGE_ROOT}/state/worker-bridge.env" | docker exec -i "${CLUSTER_CONTAINER}" sh -lc "
  cat > /tmp/worker-bridge.env &&
  kubectl -n ${NAMESPACE} create secret generic ${SECRET_NAME} \
    --from-env-file=/tmp/worker-bridge.env \
    --dry-run=client -o yaml | kubectl apply -f - &&
  rm -f /tmp/worker-bridge.env
"

cat <<EOF | docker exec -i "${CLUSTER_CONTAINER}" kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEPLOY_NAME}
  template:
    metadata:
      labels:
        app: ${DEPLOY_NAME}
    spec:
      containers:
        - name: bridge
          image: ${IMAGE_TAG}
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: ${SECRET_NAME}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          ports:
            - containerPort: 8080
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
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 256Mi
      volumes:
        - name: tmp
          emptyDir: {}
      restartPolicy: Always
---
apiVersion: v1
kind: Service
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: ${DEPLOY_NAME}
  ports:
    - name: http
      port: 8080
      targetPort: http
EOF

docker exec "${CLUSTER_CONTAINER}" kubectl rollout status deployment/"${DEPLOY_NAME}" -n "${NAMESPACE}" --timeout=300s
