SHELL := /bin/bash

# Check if DEBUG=1 is set, and conditionally add MAKEFLAGS
ifeq ($(DEBUG),1)
	MAKEFLAGS += --no-print-directory
	MAKEFLAGS += --keep-going
	MAKEFLAGS += --ignore-errors
	.SHELLFLAGS = -x -c
endif

# Default goal
.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Available targets:"
	@echo ""
	@echo "  generate-chart    - Generate Helm chart from Kubernetes manifests"
	@echo "  template          - Generate Kubernetes manifests from templates"
	@echo "  apply             - Apply generated manifests to the Kubernetes cluster"
	@echo "  delete            - Delete Kubernetes resources defined in the manifests"
	@echo "  validate-%        - Validate a specific manifest using yq, e.g. make validate-rbac"
	@echo "  print-%           - Print the value of a specific variable"
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
	@echo "  diff              - Interactive diff selection menu"
	@echo "  diff-live         - Compare live cluster state with generated manifests"
	@echo "  diff-previous     - Compare previous applied manifests with current generated manifests"
	@echo "  diff-revisions    - Compare manifests between two git revisions"
	@echo "  diff-environments - Compare manifests between two environments"
	@echo "  diff-params       - Compare parameters between two environments"
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

# Example of generating Helm charts
include helm.mk

# Vault specific
include vault.mk

# Canary
include canary.mk

##########
##########

define rbac
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${VAULT_SERVICE_ACCOUNT_NAME} 
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
  name: vault
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
      serviceAccountName: ${VAULT_SERVICE_ACCOUNT_NAME} 
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
            storage: ${VAULT_STORAGE}
endef
export statefulset

##########
##########

manifests += $${rbac}
manifests += $${configmap}
manifests += $${services}
manifests += $${statefulset}

.PHONY: template apply delete

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

GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
GIT_COMMIT := $(shell git rev-parse --short HEAD)

.PHONY: archive
archive:
	@echo "Creating git archive..."
	git archive --format=tar.gz --output=archive-$(GIT_BRANCH)-$(GIT_COMMIT).tar.gz HEAD
	@echo "Archive created: archive-$(GIT_BRANCH)-$(GIT_COMMIT).tar.gz"

.PHONY: bundle
bundle:
	@echo "Creating git bundle..."
	git bundle create bundle-$(GIT_BRANCH)-$(GIT_COMMIT).bundle --all
	@echo "Bundle created: bundle-$(GIT_BRANCH)-$(GIT_COMMIT).bundle"

.PHONY: clean
clean:
	@rm -f archive-*.tar.gz bundle-*.bundle manifest.yaml manifest.json

.PHONY: release
release:
	@echo "Creating Git tag and releasing on GitHub..."
	@read -p "Enter the version number (e.g., v1.0.0): " version; \
	git tag -a $$version -m "Release $$version"; \
	git push origin $$version; \
	gh release create $$version --generate-notes
	@echo "Release $$version created and pushed to GitHub."

.PHONY: create-release
create-release:
	@echo "Creating Kubernetes secret with VERSION set to Git commit SHA..."
	@SECRET_NAME="app-version-secret"; \
	JSON_DATA="{\"VERSION\":\"$(GIT_COMMIT)\"}"; \
	kubectl create secret generic $$SECRET_NAME \
		--from-literal=version.json="$$JSON_DATA" \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "Secret created successfully: app-version-secret"

.PHONY: remove-release
remove-release:
	@echo "Deleting Kubernetes secret: app-version-secret..."
	@SECRET_NAME="app-version-secret"; \
	kubectl delete secret $$SECRET_NAME 2>/dev/null || true
	@echo "Secret deleted successfully: app-version-secret"

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
dump-manifests: template convert-to-json
	@echo "Dumping manifests to manifest.yaml and manifest.json..."
	@make template > manifest.yaml
	@make convert-to-json > manifest.json
	@echo "Manifests successfully dumped to manifest.yaml and manifest.json."

.PHONY: list-vars
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

.PHONY: diff
diff: ## Show differences between various states (live vs generated, previous vs current, etc.)
	@echo "Select diff type:"
	@echo "1. Live cluster vs generated manifests"
	@echo "2. Previous apply vs current generated manifests"
	@echo "3. Between two git revisions"
	@echo "4. Between two environments"
	@read -p "Enter choice (1-4): " choice; \
	case "$$choice" in \
		1) $(MAKE) diff-live;; \
		2) $(MAKE) diff-previous;; \
		3) $(MAKE) diff-revisions;; \
		4) $(MAKE) diff-environments;; \
		*) echo "Invalid choice"; exit 1;; \
	esac

.PHONY: diff-live
diff-live: ## Compare live cluster state with generated manifests
	@echo "Comparing live cluster state with generated manifests..."
	@mkdir -p tmp/diff
	@# Get live state
	@kubectl get all,configmap,secret,serviceaccount,role,rolebinding -l app.kubernetes.io/name=vault -o yaml > tmp/diff/live-state.yaml
	@# Generate current manifests
	@$(MAKE) template > tmp/diff/generated-manifests.yaml
	@# Diff them
	@diff -u tmp/diff/live-state.yaml tmp/diff/generated-manifests.yaml > tmp/diff/live.diff || true
	@if [ -s tmp/diff/live.diff ]; then \
		echo "Differences found:"; \
		bat --paging=never -l diff tmp/diff/live.diff; \
	else \
		echo "No differences found between live cluster and generated manifests"; \
	fi

.PHONY: diff-previous
diff-previous: ## Compare previous applied manifests with current generated manifests
	@echo "Comparing previous applied manifests with current generated manifests..."
	@mkdir -p tmp/diff
	@if [ -f manifest.yaml ]; then \
		$(MAKE) template > tmp/diff/current-manifests.yaml; \
		diff -u manifest.yaml tmp/diff/current-manifests.yaml > tmp/diff/previous.diff || true; \
		if [ -s tmp/diff/previous.diff ]; then \
			echo "Differences found:"; \
			bat --paging=never -l diff tmp/diff/previous.diff; \
		else \
			echo "No differences found between previous and current manifests"; \
		fi; \
	else \
		echo "No previous manifest.yaml found - nothing to compare with"; \
	fi

.PHONY: diff-revisions
diff-revisions: ## Compare manifests between two git revisions
	@echo "Comparing manifests between two git revisions..."
	@read -p "Enter older revision (commit hash/tag/branch): " old_rev; \
	read -p "Enter newer revision (commit hash/tag/branch): " new_rev; \
	mkdir -p tmp/diff; \
	git show $$old_rev:Makefile > tmp/diff/Makefile.old; \
	git show $$new_rev:Makefile > tmp/diff/Makefile.new; \
	$(MAKE) -f tmp/diff/Makefile.old template > tmp/diff/manifests.old.yaml; \
	$(MAKE) -f tmp/diff/Makefile.new template > tmp/diff/manifests.new.yaml; \
	diff -u tmp/diff/manifests.old.yaml tmp/diff/manifests.new.yaml > tmp/diff/revisions.diff || true; \
	if [ -s tmp/diff/revisions.diff ]; then \
		echo "Differences between $$old_rev and $$new_rev:"; \
		bat --paging=never -l diff tmp/diff/revisions.diff; \
	else \
		echo "No differences found between $$old_rev and $$new_rev"; \
	fi

.PHONY: diff-environments
diff-environments: ## Compare manifests between two environments
	@echo "Comparing manifests between two environments..."
	@echo "Available environments: $(ALLOWED_ENVS)"; \
	read -p "Enter first environment: " env1; \
	read -p "Enter second environment: " env2; \
	if [ "$$env1" = "$$env2" ]; then \
		echo "Cannot compare the same environment"; \
		exit 1; \
	fi; \
	mkdir -p tmp/diff; \
	$(MAKE) --no-print-directory ENV=$$env1 template > tmp/diff/manifests.$$env1.yaml; \
	$(MAKE) --no-print-directory ENV=$$env2 template > tmp/diff/manifests.$$env2.yaml; \
	diff -u tmp/diff/manifests.$$env1.yaml tmp/diff/manifests.$$env2.yaml > tmp/diff/environments.diff || true; \
	if [ -s tmp/diff/environments.diff ]; then \
		echo "Differences between $$env1 and $$env2 environments:"; \
		bat --paging=never -l diff tmp/diff/environments.diff; \
	else \
		echo "No differences found between $$env1 and $$env2 environments"; \
	fi

.PHONY: diff-params
diff-params: ## Compare parameters between two environments
	@echo "Comparing parameters between two environments..."
	@echo "Available environments: $(ALLOWED_ENVS)"; \
	read -p "Enter first environment: " env1; \
	read -p "Enter second environment: " env2; \
	if [ "$$env1" = "$$env2" ]; then \
		echo "Cannot compare the same environment"; \
		exit 1; \
	fi; \
	mkdir -p tmp/diff; \
	diff -u $$env1.param $$env2.param > tmp/diff/params.diff || true; \
	if [ -s tmp/diff/params.diff ]; then \
		echo "Parameter differences between $$env1 and $$env2:"; \
		bat --paging=never -l diff tmp/diff/params.diff; \
	else \
		echo "No parameter differences between $$env1 and $$env2"; \
	fi

# Target to print all variables
print-variables:
	@echo "Printing all variables:"
	@$(foreach var,$(.VARIABLES), \
		$(info $(var) = $($(var))) \
	)
