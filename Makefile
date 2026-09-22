# ==============================================================================
# Enterprise Kubernetes Gateway API & Istio Gateway Controller Management
# ==============================================================================

SHELL := /bin/bash
ISTIO_VERSION ?= 1.24.0
GATEWAY_NAMESPACE ?= gateway-infra
APP_NAMESPACE ?= production-apps

.PHONY: help install-istio deploy-infra deploy-gateway deploy-policies deploy-workloads deploy-routes deploy-all test-traffic clean-all status lint

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

lint: ## Validate all Kubernetes YAML manifests for syntax errors
	@echo "==> Validating YAML syntax across all manifests..."
	@ruby -e 'require "yaml"; Dir.glob("**/*.yaml").each { |f| YAML.load_stream(File.read(f)) }; puts "✔ All YAML files are valid!"'

install-istio: ## Install Istio control plane (istiod) with Gateway API enabled
	@echo "==> Installing Istio $(ISTIO_VERSION)..."
	@./00-crds-and-controller/install.sh

deploy-infra: ## Deploy namespaces, GatewayClass, and cert-manager issuer
	@echo "==> Deploying platform infrastructure..."
	@kubectl apply -f 01-platform-infrastructure/namespaces.yaml
	@kubectl apply -f 01-platform-infrastructure/gateway-class.yaml
	@kubectl apply -f 01-platform-infrastructure/cert-manager/cluster-issuer.yaml

deploy-gateway: ## Deploy Gateway fleet and ReferenceGrants
	@echo "==> Deploying Gateway fleet..."
	@kubectl apply -f 02-gateway-fleet/reference-grant.yaml
	@kubectl apply -f 02-gateway-fleet/gateway.yaml

deploy-policies: ## Deploy Telemetry, PeerAuthentication, and AuthorizationPolicy
	@echo "==> Deploying resilience and security policies..."
	@kubectl apply -f 03-resilience-and-security-policies/telemetry.yaml
	@kubectl apply -f 03-resilience-and-security-policies/peer-authentication.yaml
	@kubectl apply -f 03-resilience-and-security-policies/authorization-policy.yaml

deploy-workloads: ## Deploy hardened backend workloads (v1 & v2)
	@echo "==> Deploying backend workloads..."
	@kubectl apply -f 04-workloads/backend-v1/
	@kubectl apply -f 04-workloads/backend-v2/
	@echo "==> Waiting for backend deployments to become ready..."
	@kubectl rollout status deployment/backend-v1 -n $(APP_NAMESPACE) --timeout=120s
	@kubectl rollout status deployment/backend-v2 -n $(APP_NAMESPACE) --timeout=120s

deploy-routes: ## Deploy HTTPRoute resources (Basic, Rewrite, Canary, Header-based)
	@echo "==> Deploying HTTPRoutes..."
	@kubectl apply -f 05-routes/

deploy-all: deploy-infra deploy-gateway deploy-policies deploy-workloads deploy-routes ## Deploy all layers sequentially
	@echo "✔ Production Gateway API stack successfully deployed!"

status: ## Inspect Gateway, HTTPRoute, and auto-provisioned proxy fleet status
	@echo "=== GatewayClasses ==="
	@kubectl get gatewayclasses.gateway.networking.k8s.io
	@echo ""
	@echo "=== Gateways ==="
	@kubectl get gateways.gateway.networking.k8s.io -A
	@echo ""
	@echo "=== HTTPRoutes ==="
	@kubectl get httproutes.gateway.networking.k8s.io -A
	@echo ""
	@echo "=== Auto-Provisioned Gateway Proxy Pods ==="
	@kubectl get pods -n $(GATEWAY_NAMESPACE) -l gateway.networking.k8s.io/gateway-name=production-gateway
	@echo ""
	@echo "=== Application Workloads ==="
	@kubectl get pods -n $(APP_NAMESPACE)

test-traffic: ## Run curl validation tests against the Gateway
	@GATEWAY_IP=$$(kubectl get gateway/production-gateway -n $(GATEWAY_NAMESPACE) -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "127.0.0.1"); \
	echo "==> Testing Gateway IP: $$GATEWAY_IP"; \
	echo "--- 1. Testing HTTP-to-HTTPS redirect (port 80) ---"; \
	curl -s -I "http://$$GATEWAY_IP/" -H "Host: app.example.com" | head -n 5; \
	echo ""; \
	echo "--- 2. Testing Basic Route (HTTPS port 443) ---"; \
	curl -k -s "https://$$GATEWAY_IP/" -H "Host: app.example.com" | head -n 10; \
	echo ""; \
	echo "--- 3. Testing Canary Header Routing (X-Canary: true) ---"; \
	curl -k -s "https://$$GATEWAY_IP/" -H "Host: preview.example.com" -H "X-Canary: true" | grep -i "version" || true; \
	echo ""; \
	echo "--- 4. Testing URL Rewrite (/api/v1/echo) ---"; \
	curl -k -s "https://$$GATEWAY_IP/api/v1/echo" -H "Host: api.example.com" | head -n 8

clean-all: ## Teardown all resources in reverse order
	@echo "==> Tearing down Gateway API resources..."
	@-kubectl delete -f 05-routes/ --ignore-not-found
	@-kubectl delete -f 04-workloads/backend-v2/ --ignore-not-found
	@-kubectl delete -f 04-workloads/backend-v1/ --ignore-not-found
	@-kubectl delete -f 03-resilience-and-security-policies/ --ignore-not-found
	@-kubectl delete -f 02-gateway-fleet/ --ignore-not-found
	@-kubectl delete -f 01-platform-infrastructure/ --ignore-not-found
	@echo "✔ Teardown complete."
