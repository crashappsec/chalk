SHELL=bash

CHALK_RELEASE=../.config-tool-bin/chalk-release
CHALK_DEBUG=../.config-tool-bin/chalk

.PHONLY: config
config:
	docker compose run --rm config

.PHONY: $(CHALK_RELEASE)
$(CHALK_RELEASE):
	mkdir -p $(@D)
	make -C .. release
	cp ../chalk $@

.PHONY: $(CHALK_DEBUG)
$(CHALK_DEBUG):
	mkdir -p $(@D)
	make -C .. debug
	cp ../chalk $@

.PHONY: deps
deps: $(CHALK_RELEASE) $(CHALK_DEBUG)
	docker compose build config

.PHONY: format
format:
	docker compose run --rm config autoflake --remove-all-unused-imports -r chalk_config -i
	docker compose run --rm config isort --profile black chalk_config
	docker compose run --rm config black chalk_config

.PHONY: lint
lint:
	docker compose run --rm config flake8 --extend-ignore=D chalk_config
	docker compose run --rm config isort --profile black --check chalk_config
	docker compose run --rm config black --check chalk_config
	docker compose run --rm config mypy chalk_config

.PHONY: dist
dist:
	rm -rf dist
	mkdir -p dist # create folder outside of docker for permissions
	docker compose run --rm config poetry build
	ls -la dist

.PHONY: release
release: dist  ## add dummy pypi simple/index.html for dist to be "pypi" server
	-rm -f dist/index.html
	-ls -la dist
	cd dist && timeout 2s python -m http.server 29999 &
	sleep 1
	curl localhost:29999/ -s | sed '/simple/d' > dist/simple.html
	mv dist/simple.html dist/index.html
	ls -la dist
	cat dist/index.html
