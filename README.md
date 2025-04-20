## Table of Contents

- [Preface](#preface)
- [How it works](#how-it-works)
- [Helm Critique](#helm)
- [Kustomize Critique](#kustomize)
- [Alternative Approaches](#alternative-approaches)
- [KISS (Keep It Simple)](#KISS)
- [Constraints](#constraints)
- [Diff Utilities](#diff)
- [Helm Chart Generation](#helm-charts)

## Preface

Running make without any targets outputs the help:
```bash
make
Available targets:
  generate-chart    - Generate Helm chart from Kubernetes manifests
  template          - Generate Kubernetes manifests from templates
  apply             - Apply generated manifests to the Kubernetes cluster
  delete            - Delete Kubernetes resources defined in the manifests
  validate-%        - Validate a specific manifest using yq, e.g. make validate-rbac
  print-%           - Print the value of a specific variable
  get-vault-ui      - Fetch the Vault UI Node IP and NodePort
  build-vault-image - Build the Vault Docker image
  exec              - Execute a shell in the vault pod
  logs              - Stream logs from the vault pod
  switch-namespace  - Switch the current Kubernetes namespace
  archive           - Create a git archive
  bundle            - Create a git bundle
  clean             - Clean up generated files
  release           - Create a Git tag and release on GitHub
  get-vault-keys    - Initialize Vault and retrieve unseal and root keys
  show-params       - Show contents of the parameter file for the current environment
  interactive       - Start an interactive session
  create-release    - Create a Kubernetes secret with VERSION set to Git commit SHA
  remove-release    - Remove the dynamically created Kubernetes secret
  dump-manifests    - Dump manifests in both YAML and JSON formats to the current directory
  convert-to-json   - Convert manifests to JSON format
  validate-server   - Validate JSON manifests against the Kubernetes API (server-side)
  validate-client   - Validate JSON manifests against the Kubernetes API (client-side)
  list-vars         - List all non-built-in variables, their origins, and values.
  package           - Create a tar.gz archive of the entire directory
  diff              - Interactive diff selection menu
  diff-live         - Compare live cluster state with generated manifests
  diff-previous     - Compare previous applied manifests with current generated manifests
  diff-revisions    - Compare manifests between two git revisions
  diff-environments - Compare manifests between two environments
  diff-params       - Compare parameters between two environments
  help              - Display this help message
```
## How it works

When you run make apply, several steps are executed in sequence to apply the Kubernetes manifests to your cluster.
```
+-------------------+
|   make apply      |
+-------------------+
          |
          v
+-------------------+
| 1. Create Release |
|   - Generates a   |
|     Kubernetes    |
|     secret with   |
|     VERSION set   |
|     to Git commit |
|     SHA.          |
+-------------------+
          |
          v
+--------------------+
| 2. Apply Manifests |
|   - Iterates over  |
|     the list of    |
|     manifests      |
|     (rbac, config- |
|     map, services, |
|     statefulset)   |
|   - Applies each   |
|     manifest to    |
|     the cluster    |
|     using kubectl  |
|     apply.         |
+--------------------+
          |
          v
+-------------------+
| 3. Output Status  |
|   - Outputs the   |
|     status of the |
|     applied       |
|     resources.    |
+-------------------+
```
Every time you run make apply, the Makefile is designed to automatically trigger the create-release target as part of the process. This ensures that a Kubernetes secret is created with the current Git commit SHA, which helps track the version of the app being deployed. By including this step, the Makefile guarantees that the release information is always up-to-date and stored in the cluster whenever the manifests are applied. This makes it easier to identify which version of the app is running and maintain consistency across deployments. Make delete triggers remove-release target.

The `global.param` file contains shared parameters that apply to all environments unless explicitly overridden. For example, it might define default values for `VAULT_NAMESPACE`, `DOCKER_IMAGE`, or resource allocation (`CPU_REQUEST`, `MEMORY_REQUEST`, etc.).
`global.param`
This Makefile contains configuration variables for deploying HashiCorp Vault in a Kubernetes environment. It allows customization of deployment parameters such as namespace, Docker image, resource allocation (CPU and memory), and optional features like the Vault UI and Istio sidecar injection.

dev.param - enviroment variables
It’s possible to override parameters via CLI:
```
make apply \
VAULT_NAMESPACE=my-vault-namespace \
DOCKER_IMAGE=hashicorp/vault:1.17.0 \
REPLICA_NUM=3 \
CPU_REQUEST="4000m" \
MEMORY_REQUEST="1024Mi" \
ENABLE_ISTIO_SIDECAR='false'
```

## Helm

Helm was designed to simplify Kubernetes application deployment, but it has become another abstraction layer that introduces unnecessary complexity. Helm charts often hide the underlying process with layers of Go templating and nested `values.yaml` files, making it difficult to understand what is actually being deployed. Debugging often requires navigating through these files, which can obscure the true configuration. This approach shifts from infrastructure-as-code to something less transparent, making it harder to manage and troubleshoot.

```yaml
  imagePullPolicy: {{ .Values.defaultBackend.image.pullPolicy }}
{{- if .Values.defaultBackend.extraArgs }}
  args:
  {{- range $key, $value := .Values.defaultBackend.extraArgs }}
    {{- /* Accept keys without values or with false as value */}}
    {{- if eq ($value | quote | len) 2 }}
    - --{{ $key }}
    {{- else }}
    - --{{ $key }}={{ $value }}
    {{- end }}
  {{- end }}
{{- end }}
```

YAML itself isn’t inherently problematic, and with modern IDE support, schema validation, and linting tools, it can be a clear and effective configuration format. The issues arise when YAML is combined with Go templating, as seen in Helm. While each component is reasonable on its own, their combination creates complexity. Go templates in YAML introduce fragile constructs, where whitespace sensitivity and imperative logic make configurations difficult to read, maintain, and test. This blending of logic and data undermines transparency and predictability, which are crucial in infrastructure management.

Helm's dependency management also adds unnecessary complexity. Dependencies are fetched into a `charts/` directory, but version pinning and overrides often become brittle. Instead of clean component reuse, Helm encourages nested charts with their own `values.yaml`, which complicates customization and requires understanding multiple charts to override a single value. In practice, Helm’s dependency management can feel like nesting shell scripts inside other shell scripts.

## Kustomzie

[Kustomize](https://github.com/kubernetes-sigs/kustomize) offers a declarative approach to managing Kubernetes configurations, but its structure often blurs the line between declarative and imperative. Kustomize applies transformations to a base set of Kubernetes manifests, where users define overlays and patches that _appear_ declarative, but are actually order-dependent and procedural.

It supports various patching mechanisms, which require a deep understanding of Kubernetes objects and can lead to verbose, hard-to-maintain configurations. Features like generators pulling values from files or environment variables introduce dynamic behavior, further complicating the system. When built-in functionality falls short, users can use KRM (Kubernetes Resource Model) functions for transformations, but these are still defined in structured data, leading to a complex layering of data-as-code that lacks clarity.

While Kustomize avoids explicit templating, it introduces a level of orchestration that can be just as opaque and requires extensive knowledge to ensure predictable results.

---

In many Kubernetes environments, the configuration pipeline has become a complex chain of tools and abstractions. What the Kubernetes API receives — plain YAML or JSON — is often the result of multiple intermediate stages, such as Helm charts, Helmsman, or GitOps systems like Flux or Argo CD. As these layers accumulate, they can obscure the final output, preventing engineers from easily accessing the fully rendered manifests.

This lack of visibility makes it hard to verify what will actually be deployed, leading to operational challenges and a loss of confidence in the system. When teams cannot inspect or reproduce the deployment artifacts, it becomes difficult to review changes or troubleshoot issues, ultimately turning a once-transparent process into a black box that complicates debugging and undermines reliability.

## Other approaches

Apple’s [pkl](https://pkl-lang.org/index.html) (short for "Pickle") is a configuration language designed to replace YAML, offering greater flexibility and dynamic capabilities. It includes features like classes, built-in packages, methods, and bindings for multiple languages, as well as IDE integrations, making it resemble a full programming language rather than a simple configuration format.

However, the complexity of pkl may be unnecessary. Its extensive documentation and wide range of features may be overkill for most use cases, especially when YAML itself can handle configuration management needs. If the issue is YAML’s repetitiveness, a simpler approach, such as sandboxed JavaScript, could generate clean YAML without the overhead of a new language.
## KISS

Kubernetes configuration management is ultimately a string manipulation problem. Makefiles, combined with standard Unix tools, are ideal for solving this. Make provides a declarative way to define steps to generate Kubernetes manifests, with each step clearly outlined and only re-run when necessary. Tools like `sed`, `awk`, `cat`, and `jq` excel at text transformation and complement Make’s simplicity, allowing for quick manipulation of YAML or JSON files.

This approach is transparent — you can see exactly what each command does and debug easily when needed. Unlike more complex tools, which hide the underlying processes, Makefiles and Unix tools provide full control, making the configuration management process straightforward and maintainable.

https://github.com/avkcode/vault

HashiCorp Vault is a tool for managing secrets and sensitive data, offering features like encryption, access control, and secure storage. It was used as an example of critical infrastructure deployed on Kubernetes without Helm, emphasizing manual, customizable management of resources.

[This Makefile](https://raw.githubusercontent.com/avkcode/vault/refs/heads/main/Makefile) automates Kubernetes deployment, Docker image builds, and Git operations. It handles environment-specific configurations, validates Kubernetes manifests, and manages Vault resources like Docker image builds, retrieving unseal/root keys, and interacting with Vault pods. It also facilitates Git operations such as creating tags, pushing releases, and generating archives or bundles. The file includes tasks for managing Kubernetes resources like services, statefulsets, and secrets, switching namespaces, and cleaning up generated files. Additionally, it supports interactive deployment sessions, variable listing, and manifest validation both client and server-side.

---

The `rbac` variable in the Makefile is defined using the `define` keyword to store a multi-line YAML configuration for Kubernetes RBAC, including a `ServiceAccount` and `ClusterRoleBinding`. The `${VAULT_NAMESPACE}` placeholder is used for dynamic substitution. The variable is exported with `export rbac` and then included in the `manifests` variable. This allows the YAML to be templated with environment variables and reused in targets like `template` and `apply` for Kubernetes deployment.

```make
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
```

```make
manifests += $${rbac}
manifests += $${configmap}
manifests += $${services}
manifests += $${statefulset}

.PHONY: template apply delete

template:
	@$(foreach manifest,$(manifests),echo "$(manifest)";)

apply: create-release
	@$(foreach manifest,$(manifests),echo "$(manifest)" | kubectl apply -f - ;)

delete: remove-release
	@$(foreach manifest,$(manifests),echo "$(manifest)" | kubectl delete -f - ;)

validate-%:
	@echo "$$$*" | yq eval -P '.' -

print-%:
	@echo "$$$*"
```

The `manifests` array holds the multi-line YAML templates for Kubernetes resources, including RBAC, ConfigMap, Services, and StatefulSet. In the `apply` target, each manifest is processed and passed to `kubectl apply` to deploy them to the Kubernetes cluster. This approach uses `foreach` to iterate over the `manifests` array, applying each resource one by one. Similarly, the `delete` target uses `kubectl delete` to remove the resources defined in the manifests.

---

Using Make with tools like `curl` is a super flexible way to handle Kubernetes deployments, and it can easily replace some of the things Helm does. For example, instead of using Helm charts to manage releases, we’re just using `kubectl` in a Makefile to create and delete Kubernetes secrets. By running simple shell commands and using `kubectl`, we can manage things like versioning and configuration directly in Kubernetes without all the complexity of Helm. This approach gives us more control and is lighter weight, which is perfect for projects where you want simplicity and flexibility without the overhead of managing full Helm charts.

```make
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

```

Since the `manifests` array contains all the Kubernetes resource definitions, we can easily dump them into both YAML and JSON formats. The `dump-manifests` target runs `make template` to generate the YAML output and `make convert-to-json` to convert the same output into JSON. By redirecting the output to `manifest.yaml` and `manifest.json`, you're able to keep both versions of the resources for further use. It’s a simple and efficient way to generate multiple formats from the same set of manifests.

```make
.PHONY: dump-manifests
dump-manifests: template convert-to-json
	@echo "Dumping manifests to manifest.yaml and manifest.json..."
	@make template > manifest.yaml
	@make convert-to-json > manifest.json
	@echo "Manifests successfully dumped to manifest.yaml and manifest.json."
```

With the `validate-%` target, you can easily validate any specific manifest by piping it through `yq` to check the structure or content in a readable format. This leverages external tools like `yq` to validate and process YAML directly within the Makefile, without needing to write complex scripts. Similarly, the `print-%` target allows you to quickly print the value of any Makefile variable, giving you an easy way to inspect variables or outputs. By using external tools like `yq`, you can enhance the flexibility of your Makefile, making it easy to validate, process, and manipulate manifests directly.
```make
# Validates a specific manifest using `yq`.
validate-%:
	@echo "$$$*" | yq eval -P '.' -

# Prints the value of a specific variable.
print-%:
	@echo "$$$*"
```

With Makefile and simple Bash scripting, you can easily implement auxiliary functions like getting Vault keys. In this case, the `get-vault-keys` target lists available Vault pods, prompts for the pod name, and retrieves the Vault unseal key and root token by executing commands on the chosen pod. The approach uses basic tools like `kubectl`, `jq`, and Bash, making it much more flexible than dealing with Helm’s syntax or other complex tools. It simplifies the process and gives you full control over your deployment logic without having to rely on heavyweight tools or charts.
```make
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
```

## Constrains

When managing complex workflows, especially in DevOps or Kubernetes environments, constraints play a vital role in ensuring consistency, preventing errors, and maintaining control over the build process. In Makefiles, constraints can be implemented to validate inputs, restrict environment configurations, and enforce best practices. Let’s explore how this works with a practical example.

What Are Constraints in Makefiles?

Constraints are rules or conditions that ensure only valid inputs or configurations are accepted during execution. For instance, you might want to limit the environments (dev, sit, uat, prod) where your application can be deployed, or validate parameter files before proceeding with Kubernetes manifest generation.

Example: Restricting Environment Configurations

Consider the following snippet from the provided Makefile:
```make
ENV ?= dev
ALLOWED_ENVS := global dev sit uat prod

ifeq ($(filter $(ENV),$(ALLOWED_ENVS)),)
    $(error Invalid ENV value '$(ENV)'. Allowed values are: $(ALLOWED_ENVS))
endif
```

Here’s how this works:

Default Value : The ENV variable defaults to dev if not explicitly set.
Allowed Values : The ALLOWED_ENVS variable defines a list of valid environments.
Validation Check : The ifeq block checks if the provided ENV value exists in the ALLOWED_ENVS list. If not, it throws an error and stops execution.
 For example:

Running make apply ENV=test will fail because test is not in the allowed list.
Running make apply ENV=prod will proceed as prod is valid.

This snippet validates that the MEMORY_REQUEST and MEMORY_LIMIT values are within the acceptable range of 128Mi to 4096Mi. It extracts the numeric value, converts units (e.g., Gi to Mi), and checks if the values fall within the specified bounds. If not, it raises an error to prevent invalid configurations from being applied.
```make
# Validate memory ranges (e.g., 128Mi <= MEMORY_REQUEST <= 4096Mi)
MEMORY_REQUEST_VALUE := $(subst Mi,,$(subst Gi,,$(MEMORY_REQUEST)))
MEMORY_REQUEST_UNIT := $(suffix $(MEMORY_REQUEST))
ifeq ($(MEMORY_REQUEST_UNIT),Gi)
  MEMORY_REQUEST_VALUE := $(shell echo $$(($(MEMORY_REQUEST_VALUE) * 1024)))
endif
ifeq ($(shell [ $(MEMORY_REQUEST_VALUE) -ge 128 ] && [ $(MEMORY_REQUEST_VALUE) -le 4096 ] && echo true),)
  $(error Invalid MEMORY_REQUEST value '$(MEMORY_REQUEST)'. It must be between 128Mi and 4096Mi.)
endif

MEMORY_LIMIT_VALUE := $(subst Mi,,$(subst Gi,,$(MEMORY_LIMIT)))
MEMORY_LIMIT_UNIT := $(suffix $(MEMORY_LIMIT))
ifeq ($(MEMORY_LIMIT_UNIT),Gi)
  MEMORY_LIMIT_VALUE := $(shell echo $$(($(MEMORY_LIMIT_VALUE) * 1024)))
endif
ifeq ($(shell [ $(MEMORY_LIMIT_VALUE) -ge 128 ] && [ $(MEMORY_LIMIT_VALUE) -le 4096 ] && echo true),)
  $(error Invalid MEMORY_LIMIT value '$(MEMORY_LIMIT)'. It must be between 128Mi and 4096Mi.)
endif
```

## diff

Advanced diff capabilities to compare Kubernetes manifests across different states: live cluster vs generated, previous vs current, git revisions, and environments.

diff - Interactive diff menu
diff-live - Compare live cluster vs generated manifests
diff-previous - Compare previous vs current manifests
diff-revisions - Compare between git revisions
diff-environments - Compare manifests across environments
diff-params - Compare parameter files between environments

[![diff](https://e.radikal.host/2025/04/20/Screenshot-2025-04-20-at-12.34.177b52f3271477030f.png)](https://radikal.host/i/IW7oZX)

## Helm charts

If you’re absolutely required to distribute a Helm chart but don’t have one pre-made, no worries—it’s totally possible to generate one from the manifests produced by this Makefile. The gen_helm_chart.py script (referenced via include helm.mk) automates this process. It takes the Kubernetes manifests generated by the Makefile and packages them into a Helm chart. This way, you can still meet the requirement for a Helm chart while leveraging the existing templates and workflows in the Makefile.

---

Sometimes, the simplest way of using just Unix tools is the best way. By relying on basic utilities like `kubectl`, `jq`, `yq`, and Make, you can create powerful, customizable workflows without the need for heavyweight tools like Helm. These simple, straightforward scripts offer greater control and flexibility. Plus, with LLMs (large language models) like this one, generating and refining code has become inexpensive and easy, making automation accessible. However, when things go wrong, debugging complex tools like Helm can become exponentially more expensive in terms of time and effort. Using minimal tools lets you stay in control, reduce complexity, and make it easier to fix issues when they arise. Sometimes, less really is more.
