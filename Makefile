.PHONY: build
build:
	docker compose build chalk-ubuntu

# this is really just a helper for running tests locally and assumes that
# you have instaleld the few reuqired dependencies for testlocal already
.PHONY: test
test: testdocker testlocal

.PHONY: testdocker
testdocker:
	rm -f chalk
	docker compose build chalk-ubuntu
	docker compose run --rm tests

# this is really just a helper for running tests locally and assumes that
# you have instaleld the few reuqired dependencies already
.PHONY: testlocal
testlocal:
	rm -f chalk
	nimble build
	# assumes dependencies are installed locally via
	# pip3.11 install --user pytest structlog
	python3.11 -m pytest tests/test_docker.py
