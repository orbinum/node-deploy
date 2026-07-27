.PHONY: help install lint fmt check

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

install: ## Install git hooks (run once)
	pre-commit install

lint: ## Run all linters/formatters on all files
	pre-commit run --all-files

fmt: ## Format YAML/JSON/Markdown only
	pre-commit run prettier --all-files

check: ## Lint without modifying files (CI-equivalent gate)
	pre-commit run --all-files --show-diff-on-failure
