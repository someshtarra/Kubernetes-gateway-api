#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Production Installation Script for Envoy Gateway & Gateway API CRDs
# ==============================================================================

ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.6.1}"
NAMESPACE="${NAMESPACE:-envoy-gateway-system}"
HELM_VALUES_FILE="$(dirname "$0")/helm-values.yaml"

echo "==> [1/4] Checking prerequisites (kubectl, helm)..."
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is required but not installed." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm is required but not installed." >&2; exit 1; }

echo "==> Current cluster context: $(kubectl config current-context)"

echo "==> [2/4] Ensuring namespace '${NAMESPACE}' exists with restricted pod security..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
EOF

echo "==> [3/4] Installing/Upgrading Envoy Gateway ${ENVOY_GATEWAY_VERSION} via Helm OCI..."
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --namespace "${NAMESPACE}" \
  --values "${HELM_VALUES_FILE}" \
  --wait \
  --timeout 7m

echo "==> [4/4] Verifying Envoy Gateway Deployment roll-out status..."
kubectl rollout status deployment/envoy-gateway -n "${NAMESPACE}" --timeout=120s

echo "==> Checking Gateway API CRDs registration..."
kubectl get crd \
  gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io \
  referencegrants.gateway.networking.k8s.io \
  envoyproxies.gateway.envoyproxy.io \
  backendtrafficpolicies.gateway.envoyproxy.io \
  clienttrafficpolicies.gateway.envoyproxy.io \
  securitypolicies.gateway.envoyproxy.io \
  ratelimitpolicies.gateway.envoyproxy.io >/dev/null 2>&1 && {
    echo "✔ All standard Gateway API and Envoy Gateway CRDs are installed successfully."
} || {
    echo "⚠ Warning: Some CRDs might still be reconciling. Run 'kubectl get crd' to inspect."
}

echo "✔ Envoy Gateway installation complete!"
