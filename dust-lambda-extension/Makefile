ifneq (,)
.error This Makefile requires GNU Make.
endif

# makefile config
MAKEFLAGS += --warn-undefined-variables
COMMA=,

#> DEPLOYMENT

VERSION:=$(shell git describe --match "dust-*" HEAD 2>/dev/null | cut -d- -f2-)
ifeq "$(VERSION)" ""
VERSION:=0.0.0
endif
DIST?=dist
ARCHIVE_NAME?=dust-lambda-extension-$(VERSION).zip
REGIONS?=
ALL_REGIONS=$(subst $(COMMA), ,$(REGIONS))
NAME?=crashoverride-dust-extension
DESCRIPTION?=CrashOverride Dust extension ($(VERSION)) for emitting chalk reports from zip lambda functions
COMPATIBLE_RUNTIMES?=provided.al2 provided.al2023
COMPATIBLE_ARCHITECTURES?=x86_64 arm64
PUBLIC?=

package-layer: $(DIST)/$(ARCHIVE_NAME).sha256 ## create a zip archive for AWS Lambda Layer deployment

$(DIST)/%: extensions/%
	mkdir -p $(@D)
	cp $< $@
	chalk insert $@

$(DIST)/$(ARCHIVE_NAME): $(DIST)/dust
	zip -r $@ $<

$(DIST)/%.sha256: $(DIST)/%
	cd $(@D) && sha256sum $(<F) | tee $(@F)

$(DIST)/%.json: $(DIST)/$(ARCHIVE_NAME) $(DIST)/$(ARCHIVE_NAME).sha256
	aws lambda publish-layer-version \
		--layer-name "$(NAME)" \
		--description "$(DESCRIPTION)" \
		--zip-file "fileb://$<" \
		--compatible-runtimes $(COMPATIBLE_RUNTIMES) \
		--compatible-architectures $(COMPATIBLE_ARCHITECTURES) \
		--region "$*" \
		--output json \
		| tee $@ || (rm $@ && exit 1)

$(DIST)/%.arn: $(DIST)/%.json
	jq -r '.LayerVersionArn' $< \
		| tee $@ || (rm $@ && exit 1)

$(DIST)/%.public: $(DIST)/%.json
	aws lambda add-layer-version-permission \
		--layer-name "$(NAME)" \
		--version-number "$$(jq -r '.Version' $<)" \
		--principal "*" \
		--statement-id "public-access" \
		--action "lambda:GetLayerVersion" \
		--region "$*" \
		| tee $@ || (rm $@ && exit 1)

$(DIST)/%.delete:
	set -x && \
	for version in $$(\
		aws lambda list-layer-versions \
			--layer-name "$(NAME)" \
			--region "$*" \
			--query 'LayerVersions[].Version' \
			--output text \
	); do \
		aws lambda delete-layer-version \
			--layer-name "$(NAME)" \
			--version-number "$$version" \
			--region "$*" \
			| cat; \
	done
	rm $(DIST)/$** 2> /dev/null || true

deploy-layer: ## deploy AWS Lambda Layer to AWS
deploy-layer: $(patsubst %,$(DIST)/%.json,$(ALL_REGIONS))
deploy-layer: $(patsubst %,$(DIST)/%.arn,$(ALL_REGIONS))
ifeq "$(PUBLIC)" "true"
deploy-layer: $(patsubst %,$(DIST)/%.public,$(ALL_REGIONS))
endif

delete-layer: ## delete already deployed AWS Lambda Layer
delete-layer: $(patsubst %,$(DIST)/%.delete,$(ALL_REGIONS))

#> TESTS

AWS_LAMBDA_RUNTIME_API?=localhost:8585
TASK_PATH?=..
export AWS_LAMBDA_RUNTIME_API
export TASK_PATH

test: ## test dust script against fake lambda runtime
	docker compose up -d --wait server
	./extensions/dust

#> UTILITIES

version: ## show extension version
	@echo $(VERSION)

.PHONY: clean
clean: ## delete Lambda layer zip archives
	rm -rf $(DIST)

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
