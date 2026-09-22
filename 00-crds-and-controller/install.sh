#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Production Installation Script for Istio Gateway API Controller & CRDs
# ==============================================================================

ISTIO_VERSION="${ISTIO_VERSION:-1.24.0}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.0}"
NAMESPACE="${NAMESPACE:-istio-system}"
HELM_VALUES_FILE="$(dirname "$0")/helm-values.yaml"

echo "==> [1/5] Checking prerequisites (kubectl, helm)..."
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is required but not installed." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm is required but not installed." >&2; exit 1; }

echo "==> Current cluster context: $(kubectl config current-context 2>/dev/null || echo 'N/A')"

echo "==> [2/5] Installing Kubernetes Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> [3/5] Setting up Istio Helm repository..."
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update istio

echo "==> [4/5] Ensuring namespace '${NAMESPACE}' exists with restricted pod security..."
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

echo "==> [5/5] Installing Istio Base (CRDs) and Istiod (${ISTIO_VERSION})..."
helm upgrade --install istio-base istio/base \
  --namespace "${NAMESPACE}" \
  --version "${ISTIO_VERSION}" \
  --wait

helm upgrade --install istiod istio/istiod \
  --namespace "${NAMESPACE}" \
  --values "${HELM_VALUES_FILE}" \
  --version "${ISTIO_VERSION}" \
  --wait \
  --timeout 7m

echo "==> Verifying Istiod Deployment roll-out status..."
kubectl rollout status deployment/istiod -n "${NAMESPACE}" --timeout=120s

echo "==> Verifying Gateway API CRD registration..."
kubectl get crd \
  gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io \
  referencegrants.gateway.networking.k8s.io >/dev/null 2>&1 && {
    echo "✔ Standard Kubernetes Gateway API CRDs are active and registered."
}

echo "✔ Istio Gateway API controller installation complete!"
