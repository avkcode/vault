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
