# Makefile for generating Vault Helm chart from Kubernetes manifests

# Configuration
CHART_NAME ?= vault-helm
INPUT_YAML ?= manifests.yaml
OUTPUT_DIR ?= $(CHART_NAME)
PYTHON ?= python3

# Define the Python conversion script
define GENERATE_HELM_SCRIPT
import os
import yaml
import sys
from pathlib import Path

def make_helm_compatible(value):
    """Convert values to Helm template syntax where appropriate"""
    if isinstance(value, dict):
        return {k: make_helm_compatible(v) for k, v in value.items()}
    elif isinstance(value, list):
        return [make_helm_compatible(v) for v in value]
    elif isinstance(value, str) and value.isdigit():
        return f"{{{{ .Values.{value} }}}"
    return value

# Create chart directory structure
base_path = Path('$(OUTPUT_DIR)')
(base_path / "templates").mkdir(parents=True, exist_ok=True)

# Create Chart.yaml
chart_yaml = {
    "apiVersion": "v2",
    "name": "$(CHART_NAME)",
    "description": "HashiCorp Vault Helm Chart",
    "type": "application",
    "version": "0.1.0",
    "appVersion": "1.18.0",
    "dependencies": [
        {
            "name": "vault",
            "version": "0.1.0",
            "repository": "https://helm.releases.hashicorp.com",
            "condition": "vault.enabled"
        }
    ]
}

with open(base_path / "Chart.yaml", "w") as f:
    yaml.dump(chart_yaml, f, sort_keys=False)

# Create values.yaml with configurable parameters
values = {
    "replicaCount": 1,
    "image": {
        "repository": "hashicorp/vault",
        "tag": "1.18.0",
        "pullPolicy": "IfNotPresent"
    },
    "service": {
        "type": "NodePort",
        "nodePort": 32000,
        "ports": {
            "http": 8200,
            "https-internal": 8201
        }
    },
    "resources": {
        "requests": {
            "cpu": "2000m",
            "memory": "512Mi"
        },
        "limits": {
            "cpu": "2000m",
            "memory": "1024Mi"
        }
    },
    "storage": {
        "size": "2Gi"
    },
    "config": {
        "disable_mlock": True,
        "ui": False,
        "listener": {
            "tcp": {
                "tls_disable": 1,
                "address": "[::]:8200",
                "cluster_address": "[::]:8201"
            }
        },
        "storage": {
            "file": {
                "path": "/vault/data"
            }
        }
    },
    "serviceAccount": {
        "create": True,
        "name": "vault-service-account"
    },
    "rbac": {
        "create": True
    }
}

with open(base_path / "values.yaml", "w") as f:
    yaml.dump(values, f, sort_keys=False)

# Process input manifests
try:
    with open('$(INPUT_YAML)') as f:
        docs = list(yaml.safe_load_all(f))

    for doc in docs:
        if not doc:
            continue

        kind = doc.get("kind", "template").lower()
        name = doc["metadata"]["name"]
        filename = f"{kind}-{name}.yaml"

        # Convert static values to Helm templates
        if kind == "statefulset":
            doc["spec"]["replicas"] = "{{ .Values.replicaCount }}"
            doc["spec"]["template"]["spec"]["containers"][0]["image"] = "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
            doc["spec"]["template"]["spec"]["containers"][0]["imagePullPolicy"] = "{{ .Values.image.pullPolicy }}"
            doc["spec"]["template"]["spec"]["containers"][0]["resources"] = "{{ .Values.resources }}"
            doc["spec"]["volumeClaimTemplates"][0]["spec"]["resources"]["requests"]["storage"] = "{{ .Values.storage.size }}"

        if kind == "service" and name == "vault-service":
            doc["spec"]["ports"][0]["nodePort"] = "{{ .Values.service.nodePort }}"
            doc["spec"]["ports"][0]["port"] = "{{ .Values.service.ports.http }}"
            doc["spec"]["ports"][1]["port"] = "{{ .Values.service.ports.https-internal }}"

        with open(base_path / "templates" / filename, "w") as f:
            f.write("{{- if .Values." + kind + ".enabled }}\n")
            yaml.dump(doc, f, sort_keys=False)
            f.write("{{- end }}\n")

    print(f"Successfully generated Helm chart at: {base_path.absolute()}")
except Exception as e:
    print(f"Error: {str(e)}", file=sys.stderr)
    sys.exit(1)
endef

.PHONY: all clean generate-chart

all: generate-chart

generate-chart: dump-manifests
	@echo "Generating Helm chart from $(INPUT_YAML)"
	@echo "$$GENERATE_HELM_SCRIPT" | $(PYTHON) -
