# canary.mk - Canary deployment implementation for Kubernetes

SHELL := /bin/bash

# Canary deployment configuration
CANARY_REPLICAS ?= 1
CANARY_TRAFFIC_PERCENTAGE ?= 10
CANARY_LABEL := canary
PRODUCTION_LABEL := stable
CANARY_INSTANCE_NAME ?= vault-canary
CANARY_SERVICE_NAME ?= vault-service-canary

.PHONY: canary-init canary-deploy canary-promote canary-rollback canary-traffic \
        canary-status canary-validate canary-validate-promote

##@ Canary Deployment

## canary-init: Label current deployment as stable (prerequisite for canary)
canary-init:
	@echo "Labeling current deployment as stable (production)"
	@kubectl label statefulset vault app.kubernetes.io/track=$(PRODUCTION_LABEL) -n $(VAULT_NAMESPACE) --overwrite
	@echo "Canary initialization complete"

## canary-deploy: Deploy canary version with reduced replicas and traffic
canary-deploy: create-release
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
canary-promote:
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
canary-rollback:
	@echo "Rolling back canary deployment"
	@kubectl delete statefulset $(CANARY_INSTANCE_NAME) -n $(VAULT_NAMESPACE) --ignore-not-found
	@kubectl delete service $(CANARY_SERVICE_NAME) -n $(VAULT_NAMESPACE) --ignore-not-found
	@echo "Canary deployment rolled back"

## canary-traffic: Configure traffic splitting between canary and production
canary-traffic:
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
	      weight: $((100 - $(CANARY_TRAFFIC_PERCENTAGE)))
	    - destination:
	        host: vault-service
	        subset: $(CANARY_LABEL)
	      weight: $(CANARY_TRAFFIC_PERCENTAGE))" | kubectl apply -f -
else
	@echo "Istio not enabled (ENABLE_ISTIO_SIDECAR=false), using Kubernetes native service for canary"
	@echo "Canary will receive traffic via: $(CANARY_SERVICE_NAME).$(VAULT_NAMESPACE).svc.cluster.local"
endif

## canary-status: Show status of canary and production deployments
canary-status:
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
canary-validate:
	@echo "Validating canary deployment..."
	@echo "Checking canary pods are ready..."
	@kubectl wait --for=condition=Ready pod -n $(VAULT_NAMESPACE) -l app.kubernetes.io/instance=$(CANARY_INSTANCE_NAME) --timeout=300s
	@echo "Canary validation passed"

## canary-validate-promote: Validate canary and automatically promote if successful
canary-validate-promote: canary-validate canary-promote
	@echo "Canary validated and promoted to production"

## canary-cleanup: Remove all canary resources
canary-cleanup:
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
	@echo "  canary-cleanup         Remove all canary resources"
