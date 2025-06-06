# canary.mk - Canary deployment implementation for Kubernetes

SHELL := /bin/bash

# Canary deployment configuration
CANARY_REPLICAS ?= 1
CANARY_TRAFFIC_PERCENTAGE ?= 10
CANARY_LABEL := canary
PRODUCTION_LABEL := stable
CANARY_INSTANCE_NAME ?= vault-canary
CANARY_SERVICE_NAME ?= vault-service-canary
CANARY_VALIDATION_TIMEOUT ?= 300s

# Validate required variables
check-vault-namespace:
	@if [ -z "$(VAULT_NAMESPACE)" ]; then \
		echo "Error: VAULT_NAMESPACE is not set"; \
		exit 1; \
	fi

.PHONY: canary-init canary-deploy canary-promote canary-rollback canary-traffic \
        canary-status canary-validate canary-validate-promote canary-metrics \
        canary-cleanup canary-help check-vault-namespace

##@ Canary Deployment

## canary-init: Label current deployment as stable (prerequisite for canary)
canary-init: check-vault-namespace
	@echo "Labeling current deployment as stable (production)"
	@kubectl label statefulset vault app.kubernetes.io/track=$(PRODUCTION_LABEL) -n $(VAULT_NAMESPACE) --overwrite
	@echo "Canary initialization complete"

## canary-deploy: Deploy canary version with reduced replicas and traffic
canary-deploy: check-vault-namespace create-release
	@echo "Deploying canary version ($(GIT_COMMIT)) with $(CANARY_REPLICAS) replicas"
	@$(foreach manifest,$(manifests), \
		echo "$(manifest)" | \
		sed 's/replicas: $(REPLICA_NUM)/replicas: $(CANARY_REPLICAS)/' | \
		sed 's/app.kubernetes.io\/instance: vault/app.kubernetes.io\/instance: $(CANARY_INSTANCE_NAME)/' | \
		sed 's/name: vault/name: $(CANARY_INSTANCE_NAME)/' | \
		sed 's/app.kubernetes.io\/track: $(PRODUCTION_LABEL)/app.kubernetes.io\/track: $(CANARY_LABEL)/' | \
		sed 's/vault-service/$(CANARY_SERVICE_NAME)/g' | \
		kubectl apply -f - ; \
	)
	@echo "Canary deployment complete"
	@echo "Routing $(CANARY_TRAFFIC_PERCENTAGE)% of traffic to canary version"

## canary-promote: Promote canary version to production
canary-promote: check-vault-namespace
	@echo "Promoting canary to production"
	@# Scale down canary
	@kubectl scale statefulset $(CANARY_INSTANCE_NAME) --replicas=0 -n $(VAULT_NAMESPACE)
	@# Update production to use canary configuration
	@$(foreach manifest,$(manifests), \
		echo "$(manifest)" | \
		kubectl apply -f - ; \
	)
	@echo "Canary promoted to production"

## canary-rollback: Rollback canary deployment
canary-rollback: check-vault-namespace
	@echo "Rolling back canary deployment"
	@kubectl delete statefulset $(CANARY_INSTANCE_NAME) -n $(VAULT_NAMESPACE) --ignore-not-found
	@kubectl delete service $(CANARY_SERVICE_NAME) -n $(VAULT_NAMESPACE) --ignore-not-found
	@echo "Canary deployment rolled back"

## canary-traffic: Configure traffic splitting between canary and production
canary-traffic: check-vault-namespace
ifeq ($(ENABLE_ISTIO_SIDECAR),true)
	@echo "Configuring Istio traffic splitting ($(CANARY_TRAFFIC_PERCENTAGE)% to canary)"
	@echo "apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: vault
  namespace: $(VAULT_NAMESPACE)
spec:
  hosts:
  - vault-service
  http:
  - route:
    - destination:
        host: vault-service
        subset: $(PRODUCTION_LABEL)
      weight: $$(( 100 - $(CANARY_TRAFFIC_PERCENTAGE) ))
    - destination:
        host: vault-service
        subset: $(CANARY_LABEL)
      weight: $(CANARY_TRAFFIC_PERCENTAGE)" | kubectl apply -f -
else
	@echo "Istio not enabled (ENABLE_ISTIO_SIDECAR=false), using Kubernetes native service for canary"
	@echo "Canary will receive traffic via: $(CANARY_SERVICE_NAME).$(VAULT_NAMESPACE).svc.cluster.local"
endif

## canary-status: Show status of canary and production deployments
canary-status: check-vault-namespace
	@echo "=== Canary Deployment Status ==="
	@echo "Production:"
	@kubectl get statefulset,svc -n $(VAULT_NAMESPACE) -l app.kubernetes.io/instance=vault
	@echo ""
	@echo "Canary:"
	@kubectl get statefulset,svc -n $(VAULT_NAMESPACE) -l app.kubernetes.io/instance=$(CANARY_INSTANCE_NAME)
	@echo ""
	@echo "Pods:"
	@kubectl get pods -n $(VAULT_NAMESPACE) -l app.kubernetes.io/name=vault --show-labels

## canary-validate: Run validation tests against canary deployment
canary-validate: check-vault-namespace
	@echo "Validating canary deployment..."
	@echo "Checking canary pods are ready..."
	@if ! kubectl wait --for=condition=Ready pod -n $(VAULT_NAMESPACE) -l app.kubernetes.io/instance=$(CANARY_INSTANCE_NAME) --timeout=$(CANARY_VALIDATION_TIMEOUT); then \
		echo "Error: Canary pods are not ready"; \
		exit 1; \
	fi
	@echo "Checking canary service is accessible..."
	@if ! kubectl exec -it -n $(VAULT_NAMESPACE) $$(kubectl get pod -n $(VAULT_NAMESPACE) -l app.kubernetes.io/instance=$(CANARY_INSTANCE_NAME) -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:8200/v1/sys/health > /dev/null; then \
		echo "Error: Canary service health check failed"; \
		exit 1; \
	fi
	@echo "Canary validation passed"

## canary-validate-promote: Validate canary and automatically promote if successful
canary-validate-promote: canary-validate canary-promote
	@echo "Canary validated and promoted to production"

## canary-metrics: Show metrics for canary deployment
canary-metrics: check-vault-namespace
	@echo "=== Canary Deployment Metrics ==="
	@echo "Resource usage:"
	@kubectl top pods -n $(VAULT_NAMESPACE) -l app.kubernetes.io/instance=$(CANARY_INSTANCE_NAME)
	@echo ""
	@echo "Logs (last 20 lines):"
	@kubectl logs -n $(VAULT_NAMESPACE) $$(kubectl get pod -n $(VAULT_NAMESPACE) -l app.kubernetes.io/instance=$(CANARY_INSTANCE_NAME) -o jsonpath='{.items[0].metadata.name}') --tail=20
	@echo ""
	@if command -v istioctl &> /dev/null && [ "$(ENABLE_ISTIO_SIDECAR)" = "true" ]; then \
		echo "Istio traffic metrics:"; \
		istioctl dashboard kiali & sleep 3 && open http://localhost:20001/kiali/console/graph/namespaces?namespaces=$(VAULT_NAMESPACE); \
	fi

## canary-cleanup: Remove all canary resources
canary-cleanup: check-vault-namespace
	@echo "Cleaning up all canary resources"
	@kubectl delete statefulset $(CANARY_INSTANCE_NAME) -n $(VAULT_NAMESPACE) --ignore-not-found
	@kubectl delete service $(CANARY_SERVICE_NAME) -n $(VAULT_NAMESPACE) --ignore-not-found
	@kubectl delete virtualservice vault -n $(VAULT_NAMESPACE) --ignore-not-found
	@echo "Canary resources cleaned up"

canary-help:
	@echo ""
	@echo "Canary Deployment Targets:"
	@echo "  canary-init            Label current deployment as stable (prerequisite for canary)"
	@echo "  canary-deploy          Deploy canary version with reduced replicas and traffic"
	@echo "  canary-promote         Promote canary version to production"
	@echo "  canary-rollback        Rollback canary deployment"
	@echo "  canary-traffic         Configure traffic splitting between canary and production"
	@echo "  canary-status          Show status of canary and production deployments"
	@echo "  canary-validate        Run validation tests against canary deployment"
	@echo "  canary-validate-promote Validate and automatically promote if successful"
	@echo "  canary-metrics         Show metrics for canary deployment"
	@echo "  canary-cleanup         Remove all canary resources"
	@echo ""
	@echo "Configuration Variables:"
	@echo "  CANARY_REPLICAS=$(CANARY_REPLICAS)"
	@echo "  CANARY_TRAFFIC_PERCENTAGE=$(CANARY_TRAFFIC_PERCENTAGE)"
	@echo "  CANARY_VALIDATION_TIMEOUT=$(CANARY_VALIDATION_TIMEOUT)"
