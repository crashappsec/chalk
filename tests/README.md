# About

Basic sanity tests for chalk

### Requirements

The following requirements are assuming to be there

- An alpine binary to be used in tests (`make testdeps`)

### Running tests

Please ensure you have an up-to-date container with `docker compose build tests`

From the root of the repo:

- build docker containers with `docker compose build tests`
- Run all tests via `make test`
- Run a single test file `docker compose run --service-ports --use-aliases --rm tests test_elf.py`
- Run a single test inside the test file by `docker compose run --rm --service-ports --use-aliases tests test_elf.py::test_virtual_valid`
- See [pytest docs](https://docs.pytest.org/en/7.1.x/how-to/usage.html) for more invocation options

##### Debugging a failed test

Add a `breakpoint()` before the failing assertion and manually invoke the single test.

OR for a single failing test, `--pdb` with the failing test will automatically start debugger.
