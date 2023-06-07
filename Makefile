.PHONY: test
test:
	rm -f chalk
	docker compose run --rm chalk-compile
	docker compose run --rm tests

.PHONY: configdeps
configdeps:
	mkdir -p .config-tool-bin
	rm -f chalk
	docker compose run --rm chalk-compile sh -c 'nimble build -d:release'
	mv chalk .config-tool-bin/chalk-release
	docker compose run --rm chalk-compile sh -c 'nimble debug'
	mv chalk .config-tool-bin

.PHONY: chalkconf
chalkconf:
	docker compose run --rm chalk-config-compile \
		sh -c "pyinstaller --onefile chalk-config/chalkconf.py --collect-all textual --collect-all rich && mv dist/chalkconf /config-bin/"

.PHONY: config
config:
	docker compose run --rm chalk-config-compile sh -c "python chalk-config/chalkconf.py"
