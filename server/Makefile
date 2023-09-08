SHELL=bash
BINARY=chalkserver

VERSION=$(shell $(MAKE) -s -C .. version)

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

$(BINARY):
	docker compose build server-release
	docker compose run \
		--rm \
		--user=$$(id -u):$$(id -g) \
		--entrypoint=cp \
		server-release /bin/chalkserver $@
	ls -la $@
	file $@

.PHONY: release
release:
	-rm -f $(BINARY)
	$(MAKE) $(BINARY)

.PHONY: version
version:
	@echo $(VERSION)

include ../.github/Makefile.dist
