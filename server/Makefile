SHELL=bash

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

version:
	@echo $(VERSION)
