#!/usr/bin/env python3

import os
import yaml
from pathlib import Path

# Path to your input YAML file
input_yaml_path = "manifest.yaml"
chart_name = "vault-chart"
base_path = Path(chart_name)

# Create Helm chart directory structure
(base_path / "templates").mkdir(parents=True, exist_ok=True)

# Create Chart.yaml
chart_yaml = {
    "apiVersion": "v2",
    "name": chart_name,
    "description": "A Helm chart for deploying HashiCorp Vault",
    "type": "application",
    "version": "0.1.0",
    "appVersion": "1.18.0"
}

with open(base_path / "Chart.yaml", "w") as f:
    yaml.dump(chart_yaml, f)

# Create a basic values.yaml
values = {
    "replicaCount": 1,
    "image": {
        "repository": "hashicorp/vault",
        "tag": "1.18.0",
        "pullPolicy": "Always"
    },
    "resources": {
        "limits": {
            "cpu": "2000m",
            "memory": "1024Mi"
        },
        "requests": {
            "cpu": "2000m",
            "memory": "512Mi"
        }
    },
    "service": {
        "type": "NodePort",
        "nodePort": 32000
    }
}

with open(base_path / "values.yaml", "w") as f:
    yaml.dump(values, f)

# Split and convert YAML documents into Helm template files
with open(input_yaml_path) as f:
    docs = list(yaml.safe_load_all(f))

for i, doc in enumerate(docs):
    kind = doc.get("kind", f"template{i}")
    name = doc["metadata"]["name"]
    filename = f"{kind.lower()}-{name}.yaml"
    
    # Convert to YAML string
    content = yaml.dump(doc)

    # Optional: add Helm templating here for values.yaml (e.g. replicas, image tag, etc.)
    # For a full production chart, you’d replace hardcoded values with {{ .Values.xxx }}

    with open(base_path / "templates" / filename, "w") as f:
        f.write(content)

print(f"Helm chart generated at: {base_path.absolute()}")

