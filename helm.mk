# Makefile for generating Vault Helm chart from Kubernetes manifests

# Configuration
CHART_NAME ?= vault-chart
INPUT_YAML ?= $(PWD)/manifest.yaml
OUTPUT_DIR ?= $(CHART_NAME)
PYTHON ?= python3

generate-chart: dump-manifests
	@echo "Generating Helm chart from $(INPUT_YAML)"
	@if [ ! -f "$(INPUT_YAML)" ]; then \
		echo "Error: $(INPUT_YAML) not found. Run 'make dump-manifests' first."; \
		exit 1; \
	fi
	@$(PYTHON) gen_helm_chart.py
	@if [ ! -d "$(OUTPUT_DIR)" ]; then \
		echo "Error: Helm chart generation failed. Output directory not created."; \
		exit 1; \
	fi
	@echo "Helm chart successfully generated at: $(OUTPUT_DIR)"
