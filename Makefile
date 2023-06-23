.PHONY: testdeps
testdeps:
	rm -f chalk
	docker compose run --rm chalk-compile

.PHONY: test
test:
	docker compose run --rm --service-ports --use-aliases tests

.PHONY: configdeps
configdeps:
	mkdir -p .config-tool-bin
	rm -f chalk
	docker compose run --rm chalk-compile sh -c 'nimble --verbose build -d:release'
	mv chalk .config-tool-bin/chalk-release
	docker compose run --rm chalk-compile sh -c 'nimble debug'
	mv chalk .config-tool-bin
	docker compose build chalk-config-compile

.PHONY: chalkconf
chalkconf:
	docker compose run --rm chalk-config-compile \
		sh -c "pyinstaller --onefile chalk-config/chalkconf.py --collect-all textual --collect-all rich && mv dist/chalkconf /config-bin/"

.PHONY: config
config:
	docker compose run --rm chalk-config-compile sh -c "python chalk-config/chalkconf.py"

.PHONY: configfmt
configfmt:
	docker compose run --rm chalk-config-compile sh -c "autoflake --remove-all-unused-imports -r chalk-config -i"
	docker compose run --rm chalk-config-compile sh -c "isort --profile \"black\" chalk-config"
	docker compose run --rm chalk-config-compile sh -c "black chalk-config"

.PHONY: configlint
configlint:
	docker compose run --rm chalk-config-compile sh -c "flake8 --extend-ignore=D chalk-config"
	docker compose run --rm chalk-config-compile sh -c "isort --profile \"black\" --check chalk-config"
	docker compose run --rm chalk-config-compile sh -c "black --check chalk-config"
	docker compose run --rm chalk-config-compile sh -c "mypy chalk-config"
