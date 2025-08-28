ifneq (,)
.error This Makefile requires GNU Make.
endif

# makefile config
MAKEFLAGS += --warn-undefined-variables

#> DEPLOYMENT

SHORT_HASH := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
TAG := $(shell git describe --exact-match HEAD 2>/dev/null)
IS_DIRTY := $(shell git diff-index --quiet HEAD -- 2>/dev/null || echo "dirty")
SOURCES := $(wildcard extensions/*)
BUILD_PREFIX ?= "."
BUILD_DIR ?= $(BUILD_PREFIX)/_build
AWS_LAMBDA_RUNTIME_API?=localhost:8585
TASK_PATH?=..
export AWS_LAMBDA_RUNTIME_API
export TASK_PATH

# AWS deployment configuration
AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
LAYER_NAME ?= crashoverride-dust-extension
REGION_FILTER ?= all
BATCH_SIZE ?= 5
LAYER_VERSION ?=
DELETE_ALL ?=
SKIP_CONFIRMATION ?=
VERBOSE ?=
DRY_RUN ?=

# Determine archive name based on git status
ifeq ($(TAG),)
  ifeq ($(IS_DIRTY),dirty)
    ARCHIVE_NAME := $(BUILD_DIR)/dust-lambda-extension-$(SHORT_HASH)-dirty.zip
  else
    ARCHIVE_NAME := $(BUILD_DIR)/dust-lambda-extension-$(SHORT_HASH).zip
  endif
else
  ARCHIVE_NAME := $(BUILD_DIR)/dust-lambda-extension-$(TAG).zip
endif

package-layer: $(ARCHIVE_NAME) ## create a zip archive for AWS Lambda Layer deployment
.PHONY: package-layer

$(ARCHIVE_NAME): $(SOURCES)
	@echo "Creating Lambda Layer package: $@"
	@mkdir -p ./_build
	@zip -r $@ extensions/
	@echo "Lambda Layer package created: $@"

deploy-layer: package-layer ## Deploy Lambda layer to all AWS regions with public access
	@# Check if repository is dirty
	@if [ "$(IS_DIRTY)" = "dirty" ]; then \
		@echo "Error: Git repository has uncommitted changes."; \
		@echo "Please commit or stash your changes before deploying."; \
		exit 1; \
	fi
	@# Check if AWS_ACCOUNT_ID is set
	@if [ -z "$(AWS_ACCOUNT_ID)" ]; then \
		echo "Error: AWS_ACCOUNT_ID is not set."; \
		echo "Please set it as an environment variable or pass it as a make argument:"; \
		echo "  make deploy-layer AWS_ACCOUNT_ID=123456789012"; \
		exit 1; \
	fi
	@# Deploy the layer
	@echo "Deploying layer to AWS regions..."
	@echo "  AWS Account ID: $(AWS_ACCOUNT_ID)"
	@echo "  Layer Name: $(LAYER_NAME)"
	@echo "  Region Filter: $(REGION_FILTER)"
	@echo "  Archive: $(ARCHIVE_NAME)"
	@echo ""
	@sh $(CURDIR)/scripts/deploy-layer.sh \
		-a "$(AWS_ACCOUNT_ID)" \
		-n "$(LAYER_NAME)" \
		-r "$(REGION_FILTER)" \
		-b "$(BATCH_SIZE)" \
		"$(ARCHIVE_NAME)"
.PHONY: deploy-layer

deploy-layer-dry-run: package-layer ## Perform a dry-run of layer deployment (no actual changes)
	@# Check if repository is dirty
	@if [ "$(IS_DIRTY)" = "dirty" ]; then \
		echo "Warning: Git repository has uncommitted changes."; \
		echo "In a real deployment, this would fail."; \
		echo ""; \
	fi
	@# Check if AWS_ACCOUNT_ID is set
	@if [ -z "$(AWS_ACCOUNT_ID)" ]; then \
		echo "Error: AWS_ACCOUNT_ID is not set."; \
		echo "Please set it as an environment variable or pass it as a make argument:"; \
		echo "  make deploy-layer-dry-run AWS_ACCOUNT_ID=123456789012"; \
		exit 1; \
	fi
	@# Perform dry-run deployment
	@echo "DRY-RUN: Simulating layer deployment to AWS regions..."
	@echo "  AWS Account ID: $(AWS_ACCOUNT_ID)"
	@echo "  Layer Name: $(LAYER_NAME)"
	@echo "  Region Filter: $(REGION_FILTER)"
	@echo "  Archive: $(ARCHIVE_NAME)"
	@echo ""
	@sh $(CURDIR)/scripts/deploy-layer.sh \
		-a "$(AWS_ACCOUNT_ID)" \
		-n "$(LAYER_NAME)" \
		-r "$(REGION_FILTER)" \
		-b "$(BATCH_SIZE)" \
		-d \
		"$(ARCHIVE_NAME)"
.PHONY: deploy-layer-dry-run

test: ## test dust script against fake lambda runtime
	./extensions/dust

#> UTILITIES

clean: ## delete Lambda layer zip archives
	rm -rf $(BUILD_DIR)
.PHONY: clean

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
