# Readme

Runs basic tests for chalk

# Setup

Assumes that chalk has already been compiled.
To do so run `docker compose build chalk-ubuntu` and subsequently run tests
via `docker compose run --rm tests` from
the root level repo (for non docker tests) or directly invoking pytest locally
for docker tests. Alternatively type `make test`, however this step will
compile chalk twice - one to be used within docker, and one to be used locally
in your platform.

# Running tests

- Run all tests via `make test`
- Run a single test passing by invoking pytest directly `docker compose run --rm tests pytest tests/test_elf.py::test_virtual`
