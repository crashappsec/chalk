SHELL=bash

.PHONY: server
server:
	docker compose run --rm --service-ports --use-aliases server $(args)

.PHONY: http
http:
	docker compose up server

.PHONY: https tls
https tls:
	docker compose up server-tls

.PHONY: sqlite
sqlite:
	docker compose up -d --wait sqlite
	docker compose logs sqlite | head

.PHONY: release
release:
	mkdir -p dist
	docker compose build server-release
	docker compose run \
		--rm \
		--user=$$(id -u):$$(id -g) \
		--entrypoint=cp \
		server-release /bin/chalkserver dist/chalkserver
	ls -la dist
	file dist/chalkserver

.PHONY: version
version:
	@$(MAKE) -s -C .. $@
