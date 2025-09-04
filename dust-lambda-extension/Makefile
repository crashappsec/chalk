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
	mkdir -p ./_build
	zip -r $@ extensions/
	@echo "Lambda Layer package created: $@"

deploy-layer: ## TODO
	@echo "Deploying..."

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
