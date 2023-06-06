.PHONY: test
test:
	rm -f chalk
	docker compose run --rm chalk-compile
	docker compose run --rm tests
