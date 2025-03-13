.PHONY: template

MAKEFLAGS += --no-print-directory
MAKEFLAGS += --keep-going
MAKEFLAGS += --ignore-errors

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  template          - Generate Kubernetes manifests from templates"
	@echo "  apply             - Apply generated manifests to the Kubernetes cluster"
	@echo "  delete            - Delete Kubernetes resources defined in the manifests"
	@echo "  kubescore         - Run kube-score against the generated manifests"
	@echo "  validate-%        - Validate a specific manifest using yq"
	@echo "  print-%           - Print the value of a specific variable"
	@echo "  get-vault-ui      - Fetch the Vault UI Node IP and NodePort"
	@echo "  help              - Display this help message"

##########
##########

ENV ?= dev
ALLOWED_ENVS := global dev sit uat prod

ifeq ($(filter $(ENV),$(ALLOWED_ENVS)),)
    $(error Invalid ENV value '$(ENV)'. Allowed values are: $(ALLOWED_ENVS))
endif

PARAM_FILE := $(ENV).param
ifeq ($(wildcard $(PARAM_FILE)),)
	$(error Parameter file for environment '$(ENV)' not found: $(PARAM_FILE))
endif
include $(PARAM_FILE)

##########
##########

define rbac
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault
  namespace: ${nameSpace}
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
  name: vault
  namespace: ${nameSpace}
endef
export rbac

define configmap
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
  namespace: ${nameSpace}
data:
  extraconfig-from-values.hcl: |-
    disable_mlock = true
    ui = ${vaultUI}
    
    listener "tcp" {
      tls_disable = 1
      address = "[::]:8200"
      cluster_address = "[::]:8201"
    }
    storage "file" {
      path = "/vault/data"
    }
endef
export configmap

define services
---
apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: ${nameSpace}
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
  namespace: ${nameSpace}
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
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vault
  namespace: ${nameSpace}
  labels:
    environment: ${ENV}
    app.kubernetes.io/name: vault
    app.kubernetes.io/instance: vault
spec:
  serviceName: vault-internal
  replicas: ${replicaNum}
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
        sidecar.istio.io/inject: ${injectIstioSidecar}
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
          image: ${dockerImage}
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
          readinessProbe:
            exec:
              command: ["/bin/sh", "-ec", "vault status -tls-skip-verify"]
            failureThreshold: 2
            initialDelaySeconds: 5
            periodSeconds: 5
            successThreshold: 1
            timeoutSeconds: 3
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

template:
	@$(foreach manifest,$(manifests),echo "$(manifest)";)

apply:
	@$(foreach manifest,$(manifests),echo "$(manifest)" | kubectl apply -f - ;)

delete:
	@$(foreach manifest,$(manifests),echo "$(manifest)" | kubectl delete -f - ;)

kubescore:
	@$(foreach manifest,$(manifests),echo "$(manifest)" | kube-score score - ;)

validate-%:
	@echo "$$$*" | yq eval -P '.' -

print-%:
	@echo "$$$*"

# Variables for Docker image
VAULT_IMAGE_NAME ?= vault
VAULT_IMAGE_TAG  ?= latest
DOCKERFILE_PATH  ?= ./Dockerfile

# New target to build the Vault Docker image
build-vault-image:
    @echo "Building Vault Docker image..."
    @docker build -t $(VAULT_IMAGE_NAME):$(VAULT_IMAGE_TAG) -f $(DOCKERFILE_PATH) .
    @echo "Vault Docker image built successfully: $(VAULT_IMAGE_NAME):$(VAULT_IMAGE_TAG)"

get-vault-ui:
	@echo "Fetching Vault UI Node IP and NodePort..."
	@NODE_PORT=$$(kubectl get svc -o jsonpath='{.items[?(@.spec.ports[].name=="http")].spec.ports[?(@.name=="http")].nodePort}'); \
	NODE_IP=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}'); \
	if [ -z "$$NODE_IP" ]; then \
		NODE_IP=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'); \
	fi; \
	echo "Vault UI is accessible at: http://$$NODE_IP:$$NODE_PORT"
