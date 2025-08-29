ifneq (,)
.error This Makefile requires GNU Make.
endif

# makefile config
MAKEFLAGS += --warn-undefined-variables

#> DEPLOYMENT

SHORT_HASH := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
TAG := $(shell git describe --exact-match HEAD 2>/dev/null)
IS_DIRTY := $(shell git diff-index --quiet HEAD -- 2>/dev/null || echo "dirty")

# Determine Dust extension version
DUST_TAG := $(shell git describe --exact-match --match "dust-*" --tags HEAD 2>/dev/null)
ifneq ($(DUST_TAG),)
  # Extract version from tag (dust-v1.0.0 -> 1.0.0)
  DUST_VERSION := $(patsubst dust-%,%,$(DUST_TAG))
else
  # Use dev version with short hash
  DUST_VERSION := dust-dev-$(SHORT_HASH)
endif

# Add dirty suffix if working tree is dirty
ifeq ($(IS_DIRTY),dirty)
  ifneq ($(findstring dust-dev,$(DUST_VERSION)),)
    DUST_VERSION := $(DUST_VERSION)-dirty
  else
    DUST_VERSION := $(DUST_VERSION)-dirty
  endif
endif
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

delete-layer: ## Delete Lambda layer versions from AWS regions
	@# Check if AWS_REGIONS is set
	@if [ -z "$(AWS_REGIONS)" ]; then \
		echo ""; \
		echo "Error: AWS_REGIONS is required"; \
		echo ""; \
		echo "Usage:"; \
		echo "  make delete-layer AWS_REGIONS=\"us-east-1\""; \
		echo "  make delete-layer AWS_REGIONS=\"us-east-1,us-west-2\""; \
		echo ""; \
		echo "Options:"; \
		echo "  AWS_ACCOUNT_ID=123456789012    # AWS Account ID (auto-detected if not set)"; \
		echo "  LAYER_VERSION=5                # Delete specific version"; \
		echo "  DELETE_ALL=true                # Delete all versions"; \
		echo "  DRY_RUN=true                   # Preview deletions without executing"; \
		echo ""; \
		echo "Example:"; \
		echo "  make delete-layer AWS_REGIONS=\"us-east-1\" DELETE_ALL=true"; \
		echo "  make delete-layer AWS_ACCOUNT_ID=123456789012 AWS_REGIONS=\"us-east-1\" LAYER_VERSION=5"; \
		echo ""; \
		exit 1; \
	fi
	@# Check if AWS_ACCOUNT_ID is set
	@if [ -z "$(AWS_ACCOUNT_ID)" ]; then \
		echo ""; \
		echo "Error: Unable to determine AWS Account ID"; \
		echo ""; \
		echo "Please ensure you are authenticated with AWS CLI or provide AWS_ACCOUNT_ID:"; \
		echo "  make delete-layer AWS_ACCOUNT_ID=123456789012 AWS_REGIONS=\"us-east-1\" DELETE_ALL=true"; \
		echo ""; \
		exit 1; \
	fi
	@# Determine version flag
	@if [ -n "$(LAYER_VERSION)" ]; then \
		VERSION_FLAG="-V $(LAYER_VERSION)"; \
	elif [ "$(DELETE_ALL)" = "true" ]; then \
		VERSION_FLAG="-A"; \
	else \
		echo "Error: Must specify either LAYER_VERSION or DELETE_ALL=true"; \
		exit 1; \
	fi
	@# Run delete script
	@sh $(CURDIR)/scripts/delete-layer.sh \
		-a "$(AWS_ACCOUNT_ID)" \
		-n "$(LAYER_NAME)" \
		-R "$(AWS_REGIONS)" \
		$$VERSION_FLAG \
		$(if $(filter true,$(DRY_RUN)),-d) \
		$(if $(filter true,$(SKIP_CONFIRMATION)),-y) \
		$(if $(filter true,$(VERBOSE)),-v)
.PHONY: delete-layer

delete-layer-dry-run: ## Preview layer deletions without executing (dry-run)
	@$(MAKE) delete-layer DRY_RUN=true DELETE_ALL=true
.PHONY: delete-layer-dry-run

list-extension-arns: ## List all published Lambda extension ARNs in tab-delimited format
	@sh $(CURDIR)/scripts/list-extension-arns.sh \
		$(if $(AWS_ACCOUNT_ID),-a "$(AWS_ACCOUNT_ID)") \
		$(if $(LAYER_NAME),-n "$(LAYER_NAME)") \
		$(if $(AWS_REGIONS),-R "$(AWS_REGIONS)") \
		$(if $(REGION_FILTER),-r "$(REGION_FILTER)")
.PHONY: list-extension-arns

#> UTILITIES

version: ## show the Dust extension version
	@echo $(DUST_VERSION)
.PHONY: version

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
