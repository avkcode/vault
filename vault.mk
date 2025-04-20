# Define a list of targets that require VAULT_POD
VAULT_POD_TARGETS := enable-metrics create-backup restore-backup enable-audit scale-vault upgrade-vault \
                     enable-auto-unseal enable-raft enable-namespace enable-ldap enable-oidc enable-k8s-auth \
                     enable-transit enable-pki enable-aws enable-database enable-consul enable-ssh enable-totp \
                     enable-kv enable-transform get-vault-keys exec logs

# Default Vault pod name (can be overridden by the user)
ifndef VAULT_POD
ifeq ($(filter $(MAKECMDGOALS),$(VAULT_POD_TARGETS)),)
# No target requiring VAULT_POD specified, default to vault-0 without prompting
VAULT_POD := vault-0
else
# Prompt user for Vault pod name for relevant targets
VAULT_POD := $(shell read -p "Enter Vault pod name (default: vault-0): " pod && echo $${pod:-vault-0})
endif
endif

.PHONY: help
vault-help: ## Display this help message
	@echo "Available Targets:"
	@echo ""
	@echo "  enable-metrics        Enable Prometheus metrics endpoint"
	@echo "  create-backup         Create a manual backup of Vault's Raft storage"
	@echo "  restore-backup        Restore Vault from a backup"
	@echo "  enable-audit          Enable Vault audit logging"
	@echo "  scale-vault           Scale Vault cluster replicas"
	@echo "  upgrade-vault         Upgrade Vault version"
	@echo "  enable-auto-unseal    Configure Vault for auto-unseal"
	@echo "  enable-raft           Enable Raft storage backend"
	@echo "  enable-namespace      Enable Vault namespaces"
	@echo "  enable-ldap           Enable LDAP authentication"
	@echo "  enable-oidc           Enable OIDC authentication"
	@echo "  enable-k8s-auth       Enable Kubernetes authentication"
	@echo "  enable-transit        Enable Transit secrets engine"
	@echo "  enable-pki            Enable PKI secrets engine"
	@echo "  enable-aws            Enable AWS secrets engine"
	@echo "  enable-database       Enable Database secrets engine"
	@echo "  enable-consul         Enable Consul secrets engine"
	@echo "  enable-ssh            Enable SSH secrets engine"
	@echo "  enable-totp           Enable TOTP secrets engine"
	@echo "  enable-kv             Enable Key/Value secrets engine"
	@echo "  enable-transform      Enable Transform secrets engine"
	@echo ""
	@echo "Utility Targets:"
	@echo "  build-vault-image     Build a custom Vault Docker image"
	@echo "  get-vault-ui          Fetch Vault UI access details (Node IP and NodePort)"
	@echo "  get-vault-keys        Retrieve unseal and root keys for a specific Vault pod"
	@echo "  exec                  Open an interactive shell in a specific Vault pod"
	@echo "  logs                  Stream logs from a specific Vault pod"

VAULT_IMAGE_NAME ?= vault
VAULT_IMAGE_TAG  ?= latest
DOCKERFILE_PATH  ?= ./Dockerfile

.PHONY: build-vault-image
build-vault-image:
	@echo "Building Vault Docker image..."
	@docker build -t $(VAULT_IMAGE_NAME):$(VAULT_IMAGE_TAG) -f $(DOCKERFILE_PATH) .
	@echo "Vault Docker image built successfully: $(VAULT_IMAGE_NAME):$(VAULT_IMAGE_TAG)"

.PHONY: get-vault-ui
get-vault-ui:
	@echo "Fetching Vault UI Node IP and NodePort..."
	@NODE_PORT=$$(kubectl get svc -o jsonpath='{.items[?(@.spec.ports[].name=="http")].spec.ports[?(@.name=="http")].nodePort}'); \
	NODE_IP=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}'); \
	if [ -z "$$NODE_IP" ]; then \
		NODE_IP=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'); \
	fi; \
	echo "Vault UI is accessible at: http://$$NODE_IP:$$NODE_PORT"

.PHONY: get-vault-keys
get-vault-keys:
	@echo "Available Vault pods:"
	@PODS=$$(kubectl get pods -l app.kubernetes.io/name=vault -o jsonpath='{.items[*].metadata.name}'); \
	echo "$$PODS"; \
	read -p "Enter the Vault pod name (e.g., vault-0): " POD_NAME; \
	if echo "$$PODS" | grep -qw "$$POD_NAME"; then \
		kubectl exec $$POD_NAME -- vault operator init -key-shares=1 -key-threshold=1 -format=json > keys.json; \
		VAULT_UNSEAL_KEY=$$(cat keys_$$POD_NAME.json | jq -r ".unseal_keys_b64[]"); \
		echo "Unseal Key: $$VAULT_UNSEAL_KEY"; \
		VAULT_ROOT_KEY=$$(cat keys.json | jq -r ".root_token"); \
		echo "Root Token: $$VAULT_ROOT_KEY"; \
	else \
		echo "Error: Pod '$$POD_NAME' not found."; \
	fi

.PHONY: exec
exec:
	@echo "Available Vault pods:"
	@PODS=$$(kubectl get pods -l app.kubernetes.io/name=vault -o jsonpath='{.items[*].metadata.name}'); \
	echo "$$PODS"; \
	read -p "Enter the Vault pod name (e.g., vault-0): " POD_NAME; \
	if echo "$$PODS" | grep -qw "$$POD_NAME"; then \
		kubectl exec -it $$POD_NAME -- /bin/sh; \
	else \
		echo "Error: Pod '$$POD_NAME' not found."; \
	fi

.PHONY: logs
logs:
	@echo "Available Vault pods:"
	@PODS=$$(kubectl get pods -l app.kubernetes.io/name=vault -o jsonpath='{.items[*].metadata.name}'); \
	echo "$$PODS"; \
	read -p "Enter the Vault pod name (e.g., vault-0): " POD_NAME; \
	if echo "$$PODS" | grep -qw "$$POD_NAME"; then \
		kubectl logs -f $$POD_NAME; \
	else \
		echo "Error: Pod '$$POD_NAME' not found."; \
	fi

.PHONY: enable-metrics
enable-metrics: ## Enable Prometheus metrics for Vault
		@echo "Enabling Vault metrics endpoint..."
		@kubectl exec $(VAULT_POD) -- vault write sys/metrics config/enable=1 format=prometheus

.PHONY: create-backup
create-backup: ## Create a manual backup of Vault's Raft storage
	    @echo "Creating Vault backup..."
	    @kubectl exec $(VAULT_POD) -- vault operator raft snapshot save /vault/data/backup.snap

.PHONY: restore-backup
restore-backup: ## Restore Vault from a backup
	    @echo "Restoring Vault from backup..."
	    @kubectl exec $(VAULT_POD) -- vault operator raft snapshot restore -force /vault/data/backup.snap

.PHONY: enable-audit
enable-audit: ## Enable audit logging
	    @echo "Enabling Vault audit logging..."
	    @kubectl exec $(VAULT_POD) -- vault audit enable file file_path=/vault/logs/audit.log

.PHONY: scale-vault
scale-vault: ## Scale Vault cluster
	    @read -p "Enter desired replica count: " replicas; \
	    kubectl scale statefulset vault --replicas=$$replicas

.PHONY: upgrade-vault
upgrade-vault: ## Upgrade Vault version
	    @read -p "Enter new Vault version (e.g., 1.18.0): " version; \
	    kubectl set image statefulset/vault vault=hashicorp/vault:$$version

.PHONY: enable-auto-unseal
enable-auto-unseal: ## Configure Vault for auto-unseal
	    @echo "Configuring auto-unseal..."
	    @kubectl exec $(VAULT_POD) -- vault operator init -key-shares=1 -key-threshold=1 -recovery-shares=1 -recovery-threshold=1

.PHONY: enable-raft
enable-raft: ## Enable Raft storage backend
	    @echo "Enabling Raft storage backend..."
	    @kubectl exec $(VAULT_POD) -- vault operator raft join http://$(VAULT_POD).vault-internal:8200

.PHONY: enable-namespace
enable-namespace: ## Enable Vault namespaces
	    @echo "Enabling Vault namespaces..."
	    @kubectl exec $(VAULT_POD) -- vault namespace create my-namespace

.PHONY: enable-ldap
enable-ldap: ## Enable LDAP authentication
	    @echo "Enabling LDAP authentication..."
	    @kubectl exec $(VAULT_POD) -- vault auth enable ldap

.PHONY: enable-oidc
enable-oidc: ## Enable OIDC authentication
	    @echo "Enabling OIDC authentication..."
	    @kubectl exec $(VAULT_POD) -- vault auth enable oidc

.PHONY: enable-k8s-auth
enable-k8s-auth: ## Enable Kubernetes authentication
	    @echo "Enabling Kubernetes authentication..."
	    @kubectl exec $(VAULT_POD) -- vault auth enable kubernetes

.PHONY: enable-transit
enable-transit: ## Enable Transit secrets engine
	    @echo "Enabling Transit secrets engine..."
	    @kubectl exec $(VAULT_POD) -- vault secrets enable transit

.PHONY: enable-pki
enable-pki: ## Enable PKI secrets engine
	    @echo "Enabling PKI secrets engine..."
	    @kubectl exec $(VAULT_POD) -- vault secrets enable pki

.PHONY: enable-aws
enable-aws: ## Enable AWS secrets engine
	    @echo "Enabling AWS secrets engine..."
	    @kubectl exec $(VAULT_POD) -- vault secrets enable aws

.PHONY: enable-database
enable-database: ## Enable Database secrets engine
	    @echo "Enabling Database secrets engine..."
	    @kubectl exec $(VAULT_POD) -- vault secrets enable database

.PHONY: enable-consul
enable-consul: ## Enable Consul secrets engine
	    @echo "Enabling Consul secrets engine..."
	    @kubectl exec $(VAULT_POD) -- vault secrets enable consul

.PHONY: enable-ssh
enable-ssh: ## Enable SSH secrets engine
	    @echo "Enabling SSH secrets engine..."
	    @kubectl exec $(VAULT_POD) -- vault secrets enable ssh

.PHONY: enable-totp
enable-totp: ## Enable TOTP secrets engine
	    @echo "Enabling TOTP secrets engine..."
	    @kubectl exec $(VAULT_POD) -- vault secrets enable totp

.PHONY: enable-kv
enable-kv: ## Enable Key/Value secrets engine
	    @echo "Enabling Key/Value secrets engine..."
	    @kubectl exec $(VAULT_POD) -- vault secrets enable -version=2 kv

.PHONY: enable-transform
enable-transform: ## Enable Transform secrets engine
	    @echo "Enabling Transform secrets engine..."
	    @kubectl exec $(VAULT_POD) -- vault secrets enable transform
