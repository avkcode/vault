SHELL := /bin/bash

# Check if DEBUG=1 is set, and conditionally add MAKEFLAGS
ifeq ($(DEBUG),1)
	MAKEFLAGS += --no-print-directory
	MAKEFLAGS += --keep-going
	MAKEFLAGS += --ignore-errors
endif

# Default goal
.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  template          - Generate Kubernetes manifests from templates"
	@echo "  apply             - Apply generated manifests to the Kubernetes cluster"
	@echo "  delete            - Delete Kubernetes resources defined in the manifests"
	@echo "  validate-%        - Validate a specific manifest using yq, e.g. make validate-rbac"
	@echo "  print-%           - Print the value of a specific variable"
	@echo "  get-vault-ui      - Fetch the Vault UI Node IP and NodePort"
	@echo "  build-vault-image - Build the Vault Docker image"
	@echo "  exec              - Execute a shell in the vault-0 pod"
	@echo "  logs              - Stream logs from the vault-0 pod"
	@echo "  switch-namespace  - Switch the current Kubernetes namespace"
	@echo "  archive           - Create a git archive"
	@echo "  bundle            - Create a git bundle"
	@echo "  clean             - Clean up generated files"
	@echo "  release           - Create a Git tag and release on GitHub"
	@echo "  get-vault-keys    - Initialize Vault and retrieve unseal and root keys"
	@echo "  show-params       - Show contents of the parameter file for the current environment"
	@echo "  interactive       - Start an interactive session"
	@echo "  create-release    - Create a Kubernetes secret with VERSION set to Git commit SHA"
	@echo "  remove-release    - Remove the dynamically created Kubernetes secret"
	@echo "  dump-manifests    - Dump manifests in both YAML and JSON formats to the current directory"
	@echo "  convert-to-json   - Convert manifests to JSON format"
	@echo "  validate-server   - Validate JSON manifests against the Kubernetes API (server-side)"
	@echo "  validate-client   - Validate JSON manifests against the Kubernetes API (client-side)"
	@echo "  list-vars         - List all non-built-in variables, their origins, and values."
	@echo "  package           - Create a tar.gz archive of the entire directory"
	@echo "  help              - Display this help message"

##########
##########

ENV ?= dev
# This allows users to override the ENV variable by passing it as an argument to `make`.

ALLOWED_ENVS := global dev sit uat prod
# Define a list of allowed environments. These are the valid values for the ENV variable.

ifeq ($(filter $(ENV),$(ALLOWED_ENVS)),)
    $(error Invalid ENV value '$(ENV)'. Allowed values are: $(ALLOWED_ENVS))
endif

PARAM_FILE := $(ENV).param
ifeq ($(wildcard $(PARAM_FILE)),)
	$(error Parameter file for environment '$(ENV)' not found: $(PARAM_FILE))
endif
include $(PARAM_FILE)
# This ensures that only predefined environments can be used.

# The global.param file contains shared parameters that apply to all environments unless explicitly overridden.
# For example, it might define default values for VAULT_NAMESPACE, DOCKER_IMAGE, or resource allocation (CPU_REQUEST, MEMORY_REQUEST, etc.).
include global.param

##########
##########

define rbac
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-service-account
  namespace: ${VAULT_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-server-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-service-account
  namespace: ${VAULT_NAMESPACE}
endef
export rbac

define configmap
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
  namespace: ${VAULT_NAMESPACE}
data:
  extraconfig-from-values.hcl: |-
    disable_mlock = true
    ui = ${VAULT_UI}
    
    listener "tcp" {
      tls_disable = 1
      address = "[::]:8200"
      cluster_address = "[::]:8201"
    }
    storage "file" {
      path = "/vault/data"
    }
    ${TELEMETRY_CONFIG}
endef
export configmap

define services
---
apiVersion: v1
kind: Service
metadata:
  name: vault-service
  namespace: ${VAULT_NAMESPACE}
  labels:
    environment: ${ENV}
    app.kubernetes.io/name: vault
    app.kubernetes.io/instance: vault
  annotations:
spec:
  type: NodePort
  publishNotReadyAddresses: true
  ports:
    - name: http
      port: 8200
      targetPort: 8200
      nodePort: 32000
    - name: https-internal
      port: 8201
      targetPort: 8201
  selector:
    app.kubernetes.io/name: vault
    app.kubernetes.io/instance: vault
    component: server
---
apiVersion: v1
kind: Service
metadata:
  name: vault-internal
  namespace: ${VAULT_NAMESPACE}
  labels:
    environment: ${ENV}
    app.kubernetes.io/name: vault
    app.kubernetes.io/instance: vault
  annotations:
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  ports:
    - name: "http"
      port: 8200
      targetPort: 8200
    - name: https-internal
      port: 8201
      targetPort: 8201
  selector:
    app.kubernetes.io/name: vault
    app.kubernetes.io/instance: vault
    component: server
endef
export services

define statefulset
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vault-statefulset
  namespace: ${VAULT_NAMESPACE}
  labels:
    environment: ${ENV}
    app.kubernetes.io/name: vault
    app.kubernetes.io/instance: vault
spec:
  serviceName: vault-internal
  replicas: ${REPLICA_NUM}
  selector:
    matchLabels:
      app.kubernetes.io/name: vault
      app.kubernetes.io/instance: vault
      component: server
  template:
    metadata:
      labels:
        environment: ${ENV}
        app.kubernetes.io/name: vault
        app.kubernetes.io/instance: vault
        component: server
      annotations:
        sidecar.istio.io/inject: ${ENABLE_ISTIO_SIDECAR}
    spec:
      serviceAccountName: vault
      securityContext:
        runAsNonRoot: true
        runAsGroup: 1000
        runAsUser: 100
        fsGroup: 1000
      volumes:
        - name: config
          configMap:
            name: vault-config
        - name: home
          emptyDir: {}
      containers:
        - name: vault
          image: ${DOCKER_IMAGE}
          imagePullPolicy: Always
          command:
          - "/bin/sh"
          - "-ec"
          args:
          - |
            cp /vault/config/extraconfig-from-values.hcl /tmp/storageconfig.hcl;
            [ -n "$${HOST_IP}" ] && sed -Ei "s|HOST_IP|$${HOST_IP?}|g" /tmp/storageconfig.hcl;
            [ -n "$${POD_IP}" ] && sed -Ei "s|POD_IP|$${POD_IP?}|g" /tmp/storageconfig.hcl;
            [ -n "$${HOSTNAME}" ] && sed -Ei "s|HOSTNAME|$${HOSTNAME?}|g" /tmp/storageconfig.hcl;
            [ -n "$${API_ADDR}" ] && sed -Ei "s|API_ADDR|$${API_ADDR?}|g" /tmp/storageconfig.hcl;
            [ -n "$${TRANSIT_ADDR}" ] && sed -Ei "s|TRANSIT_ADDR|$${TRANSIT_ADDR?}|g" /tmp/storageconfig.hcl;
            [ -n "$${RAFT_ADDR}" ] && sed -Ei "s|RAFT_ADDR|$${RAFT_ADDR?}|g" /tmp/storageconfig.hcl;
            /usr/local/bin/docker-entrypoint.sh vault server -config=/tmp/storageconfig.hcl
          command:
          - "/bin/sh"
          - "-ec"
          args:
          - |
            vault server -config=/vault/config
          securityContext:
            allowPrivilegeEscalation: false
          env:
            - name: HOSTNAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: VAULT_ADDR
              value: "http://127.0.0.1:8200"
            - name: VAULT_API_ADDR
              value: "http://$$(POD_IP):8200"
            - name: SKIP_CHOWN
              value: "true"
            - name: SKIP_SETCAP
              value: "true"
            - name: VAULT_CLUSTER_ADDR
              value: "https://$$(HOSTNAME).vault-internal:8201"
            - name: HOME
              value: "/home/vault"
          volumeMounts:
            - name: data
              mountPath: /vault/data
            - name: config
              mountPath: /vault/config
            - name: home
              mountPath: /home/vault
          ports:
            - containerPort: 8200
              name: http
            - containerPort: 8201
              name: https-internal
            - containerPort: 8202
              name: http-rep
          resources:
            requests:
              cpu: ${CPU_REQUEST}
              memory: ${MEMORY_REQUEST}
            limits:
              cpu: ${CPU_LIMIT}
              memory: ${MEMORY_LIMIT}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 2Gi
endef
export statefulset

##########
##########

manifests += $${rbac}
manifests += $${configmap}
manifests += $${services}
manifests += $${statefulset}

.PHONY: template apply delete dry-run

# Outputs the generated Kubernetes manifests to the console.
template:
	@$(foreach manifest,$(manifests),echo "$(manifest)";)

# Applies the generated Kubernetes manifests to the cluster using `kubectl apply`.
apply: create-release
	@$(foreach manifest,$(manifests),echo "$(manifest)" | kubectl apply -f - ;)

# Deletes the Kubernetes resources defined in the generated manifests using `kubectl delete`.
delete: remove-release
	@$(foreach manifest,$(manifests),echo "$(manifest)" | kubectl delete -f - ;)

# Validates a specific manifest using `yq`.
validate-%:
	@echo "$$$*" | yq eval -P '.' -

# Prints the value of a specific variable.
print-%:
	@echo "$$$*"

##########
##########

.PHONY: interactive
interactive:
	@echo "Interactive mode:"
	@read -p "Enter the environment (dev/sit/uat/prod): " env; \
	$(MAKE) ENV=$$env apply

# Variables for Docker image
VAULT_IMAGE_NAME ?= vault
VAULT_IMAGE_TAG  ?= latest
DOCKERFILE_PATH  ?= ./Dockerfile

# Build the Vault Docker image
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
	kubectl exec vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > keys.json
	VAULT_UNSEAL_KEY=$(cat keys.json | jq -r ".unseal_keys_b64[]")
	echo $VAULT_UNSEAL_KEY
	VAULT_ROOT_KEY=$(cat keys.json | jq -r ".root_token")
	echo $VAULT_ROOT_KEY

.PHONY: exec
exec:
	@kubectl exec -it vault-0 -- /bin/sh

.PHONY: logs
logs:
	@kubectl logs -f vault-0

.PHONY: show-params
show-params:
	@echo "Contents of $(PARAM_FILE):"
	@cat $(PARAM_FILE)

.PHONY: switch-namespace
switch-namespace:
	@echo "Listing all available namespaces..."
	@NAMESPACES=$$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}'); \
	echo "$$NAMESPACES"; \
		read -p "Enter the namespace you want to switch to: " SELECTED_NAMESPACE; \
		if echo "$$NAMESPACES" | grep -qw "$$SELECTED_NAMESPACE"; then \
			kubectl config set-context --current --namespace=$$SELECTED_NAMESPACE; \
			echo "Switched to namespace: $$SELECTED_NAMESPACE"; \
		else \
			echo "Error: Namespace '$$SELECTED_NAMESPACE' not found."; \
		fi

# Variables
GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
GIT_COMMIT := $(shell git rev-parse --short HEAD)

# Create git archive
.PHONY: archive
archive:
	@echo "Creating git archive..."
	git archive --format=tar.gz --output=archive-$(GIT_BRANCH)-$(GIT_COMMIT).tar.gz HEAD
	@echo "Archive created: archive-$(GIT_BRANCH)-$(GIT_COMMIT).tar.gz"

# Create git bundle
.PHONY: bundle
bundle:
	@echo "Creating git bundle..."
	git bundle create bundle-$(GIT_BRANCH)-$(GIT_COMMIT).bundle --all
	@echo "Bundle created: bundle-$(GIT_BRANCH)-$(GIT_COMMIT).bundle"

# Clean up generated files
.PHONY: clean
clean:
	@rm -f archive-*.tar.gz bundle-*.bundle manifest.yaml manifest.json

# Create a Git tag and release on GitHub
.PHONY: release
release:
	@echo "Creating Git tag and releasing on GitHub..."
	@read -p "Enter the version number (e.g., v1.0.0): " version; \
	git tag -a $$version -m "Release $$version"; \
	git push origin $$version; \
	gh release create $$version --generate-notes
	@echo "Release $$version created and pushed to GitHub."

# Create a Kubernetes secret with VERSION and Git Commit SHA
.PHONY: create-release
create-release:
	@echo "Creating Kubernetes secret with VERSION set to Git commit SHA..."
	@SECRET_NAME="app-version-secret"; \
	JSON_DATA="{\"VERSION\":\"$(GIT_COMMIT)\"}"; \
	kubectl create secret generic $$SECRET_NAME \
		--from-literal=version.json="$$JSON_DATA" \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "Secret created successfully: app-version-secret"

# Remove the dynamically created Kubernetes secret
.PHONY: remove-release
remove-release:
	@echo "Deleting Kubernetes secret: app-version-secret..."
	@SECRET_NAME="app-version-secret"; \
	kubectl delete secret $$SECRET_NAME 2>/dev/null || true
	@echo "Secret deleted successfully: app-version-secret"

# Pretty print and decode the Kubernetes secret
.PHONY: show-release
show-release:
	@SECRET_NAME="app-version-secret"; \
	kubectl get secret $$SECRET_NAME -o jsonpath='{.data.version\.json}' | base64 --decode | jq -r .VERSION

.PHONY: convert-to-json
convert-to-json:
	@$(foreach manifest,$(manifests),echo "$(manifest)" | yq eval -o=json -P '.' -;)

.PHONY: validate-server
validate-server:
	@echo "Validating JSON manifests against the Kubernetes API (server-side validation)..."
	@$(foreach manifest,$(manifests), \
		echo "Validating manifest: $(manifest)" && \
		printf '%s' "$(manifest)" | yq eval -o=json -P '.' - | kubectl apply --dry-run=server -f - || exit 1; \
	)
	@echo "All JSON manifests passed server-side validation successfully."

.PHONY: validate-client
validate-client:
	@echo "Validating JSON manifests against the Kubernetes API (client-side validation)..."
	@$(foreach manifest,$(manifests), \
		echo "Validating manifest: $(manifest)" && \
		printf '%s' "$(manifest)" | yq eval -o=json -P '.' - | kubectl apply --dry-run=client -f - || exit 1; \
	)
	@echo "All JSON manifests passed client-side validation successfully."

.PHONY: dump-manifests
# New target to dump manifests in both YAML and JSON formats
dump-manifests: template convert-to-json
	@echo "Dumping manifests to manifest.yaml and manifest.json..."
	@make template > manifest.yaml
	@make convert-to-json > manifest.json
	@echo "Manifests successfully dumped to manifest.yaml and manifest.json."

# Target to list all variables, their origin, and value
list-vars:
	@echo "Variable Name       Origin"
	@echo "-------------------- -----------"
	@$(foreach var, $(filter-out .% %_FILES, $(.VARIABLES)), \
		$(if $(filter-out default automatic, $(origin $(var))), \
			printf "%-20s %s\\n" "$(var)" "$(origin $(var))"; \
		))

.PHONY: package
package:
	@echo "Creating a tar.gz archive of the entire directory..."
	@DIR_NAME=$$(basename $$(pwd)); \
	TAR_FILE="$$DIR_NAME.tar.gz"; \
	tar -czvf $$TAR_FILE .; \
	echo "Archive created successfully: $$TAR_FILE"
