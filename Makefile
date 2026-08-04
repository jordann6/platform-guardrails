TF_DIR ?= terraform
CONFTEST_VERSION ?= 0.56.0

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

.PHONY: check
check: fmt lint policy scan ## Run every static gate locally (what CI runs)

.PHONY: fmt
fmt: ## Terraform format check
	terraform -chdir=$(TF_DIR) fmt -check -recursive

.PHONY: lint
lint: ## Terraform validate
	terraform -chdir=$(TF_DIR) init -backend=false
	terraform -chdir=$(TF_DIR) validate

.PHONY: policy
policy: ## Run the org policy suite against $(TF_DIR)
	conftest test --parser hcl2 --combine --policy policy \
		$$(find $(TF_DIR) -name '*.tf' -not -path '*/.terraform/*')

.PHONY: scan
scan: ## Checkov + secret scan
	checkov -d $(TF_DIR) --framework terraform --quiet --compact
	gitleaks detect --no-banner

.PHONY: test
test: ## Prove the policies still gate: pass fixture clean, fail fixture blocked
	@echo "--> pass fixture (expect 0 failures)"
	@conftest test --parser hcl2 --combine --policy policy examples/pass/main.tf
	@echo "--> fail fixture (expect failures)"
	@if conftest test --parser hcl2 --combine --policy policy examples/fail/main.tf; then \
		echo "FAIL: the non-compliant fixture passed. The policies are not gating."; \
		exit 1; \
	else \
		echo "OK: non-compliant fixture was blocked as expected."; \
	fi
	@echo "--> destroy guard"
	@scripts/destroy-guard.sh examples/plans/safe-plan.json
	@if scripts/destroy-guard.sh examples/plans/destructive-plan.json; then \
		echo "FAIL: destroy guard allowed a protected resource deletion."; \
		exit 1; \
	else \
		echo "OK: destroy guard blocked the deletion."; \
	fi

.PHONY: guard
guard: ## Plan and run the destroy guard against the real plan
	terraform -chdir=$(TF_DIR) plan -out=tfplan
	terraform -chdir=$(TF_DIR) show -json tfplan > $(TF_DIR)/plan.json
	scripts/destroy-guard.sh $(TF_DIR)/plan.json

.PHONY: tools
tools: ## Install conftest locally (macOS arm64)
	curl -sSL "https://github.com/open-policy-agent/conftest/releases/download/v$(CONFTEST_VERSION)/conftest_$(CONFTEST_VERSION)_Darwin_arm64.tar.gz" \
		| tar -xz -C /usr/local/bin conftest
