ifneq (,)
.error This Makefile requires GNU Make.
endif

# makefile config
.ONESHELL:
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --warn-undefined-variables

# user config
PYTHON3 ?= python3.12
VENV_DIR := .venv-dust-lambda-extension
VENV_PYTHON3 := ${VENV_DIR}/bin/python3

#> ENVIRONMENT SETUP
init: venv pre-commit-configured ## initialize the development environment
.PHONY: init

pre-commit-configured: pre-commit-installed ## configure pre-commit hooks
	source $(VENV_DIR)/bin/activate
	$(VENV_DIR)/bin/pre-commit install
.PHONY: pre-commit-configured

pre-commit-installed: $(VENV_DIR)/ ## install pre-commit in venv
	$(VENV_DIR)/bin/pip install pre-commit
.PHONY: pre-commit-installed

venv: $(VENV_DIR) ## create Python virtualenv
.PHONY: venv

$(VENV_DIR):
	@echo "Creating venv with $(PYTHON3)"
	$(PYTHON3) -m venv $@

#> LINTING
lint:  ## run bash and markdown linters
	pre-commit run --all-files
.PHONY: lint

#> DEPLOYMENT
package-layer: ## create a zip archive for AWS Lambda Layer deployment
	@echo "Creating Lambda Layer package..."
	# Determine archive name based on git status and tags
	@if git diff-index --quiet HEAD --; then \
		if git describe --exact-match HEAD >/dev/null 2>&1; then \
			TAG=$$(git describe --exact-match HEAD 2>/dev/null); \
			# if commit is tagged and worktree is clean, use the tag
			ARCHIVE_NAME="dust-lambda-extension-$$TAG.zip"; \
		else \
			SHORT_HASH=$$(git rev-parse --short HEAD); \
			# if commit is untagged and worktree is clean, use short hash
			ARCHIVE_NAME="dust-lambda-extension-$$SHORT_HASH.zip"; \
		fi; \
	else \
		SHORT_HASH=$$(git rev-parse --short HEAD); \
		# if commit is untagged and worktree is dirty, use {short hash}-dirty
		ARCHIVE_NAME="dust-lambda-extension-$$SHORT_HASH-dirty.zip"; \
	fi; \
	@echo "Creating archive: $$ARCHIVE_NAME"; \
	zip -r "$$ARCHIVE_NAME" extensions/; \
	@echo "Lambda Layer package created: $$ARCHIVE_NAME"
.PHONY: package-layer

deploy-layer: ## TODO
	@echo "Deploying..."

#> UTILS
clean: ## delete Lambda layer zip archives
	rm -f dust-lambda-extension-*.zip
.PHONY: clean

clean-all: clean ## remove zip archives and development environment
	rm -fr $(VENV_DIR)
.PHONY: clean-all

help: ## show this help
	@echo "Specify a command from the list below:"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "}; \
		/^#> / { \
			gsub(/^#> /, "", $$0); \
			printf "\n\n\033[1;35m%s\033[m\n", $$0; \
			next \
		} \
		/^[0-9a-zA-Z_-]+:.*?## / { \
			printf "  \033[0;36m%-25s\033[m %s\n", $$1, $$2 \
		}' $(MAKEFILE_LIST)
	@echo ""
.PHONY: help
