.PHONY: testdeps
testdeps:
	rm -f chalk
	docker compose run --rm chalk-compile

.PHONY: test
test:
	docker compose run --rm --service-ports --use-aliases tests

.PHONY: chalkcontainer
chalkcontainer:
	rm -f chalk
	docker compose run --rm chalk-compile

.PHONY: chalkcontainerrelease
chalkcontainerrelease:
	rm -f chalk
	docker compose run --rm chalk-compile-release

.PHONY: chalk
chalk:
	rm -f chalk
	nimble build

.PHONY: chalkrelease
chalkrelease:
	rm -f chalk
	nimble build -d:release

.PHONY: chalkosx
chalkosx:
	rm -f chalk-macos-arm64
	DYLD_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib con4m gen ./src/configs/chalk.c42spec --language=nim --output-file=./src/c4autoconf.nim
	nimble build
	mv chalk chalk-macos-arm64

.PHONY: chalkosxrelease
chalkosxrelease:
	rm -f chalk-macos-arm64-release
	DYLD_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib con4m gen ./src/configs/chalk.c42spec --language=nim --output-file=./src/c4autoconf.nim
	nimble build -d:release
	mv chalk chalk-macos-arm64-release

.PHONY: configtool
configtool:
	docker compose run --rm chalk-config

.PHONY: configfmt
configfmt:
	docker compose run --rm chalk-config sh -c "autoflake --remove-all-unused-imports -r chalk_config -i"
	docker compose run --rm chalk-config sh -c "isort --profile \"black\" chalk_config"
	docker compose run --rm chalk-config sh -c "black chalk_config"

.PHONY: configlint
configlint:
	docker compose run --rm chalk-config sh -c "flake8 --extend-ignore=D chalk_config"
	docker compose run --rm chalk-config sh -c "isort --profile \"black\" --check chalk_config"
	docker compose run --rm chalk-config sh -c "black --check chalk_config"
	docker compose run --rm chalk-config sh -c "mypy chalk_config"
