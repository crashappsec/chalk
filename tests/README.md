# Chalk Testing

This directory contains all the basic functionality tests for chalk. Tests are run via docker compose in a separate `tests` container which internally uses the pytest framework.

### Requirements

#### Chalk Binary

Tests assume that a chalk binary is present in the root directory of `chalk-internal`, and will use that binary in all tests cases.

More details on building the chalk binary can be found in the main README, but the quickest way to get a binary with the current local changes is:
1. `docker compose build chalk-compile` (this step can be skipped if the `chalk-compile` container is up to date)
2. `docker compose run chalk-compile`

The second command should drop a `chalk` binary in `chalk-internal` that is usable by tests.

#### Tests Container

Please ensure you have an up-to-date container with `docker compose build tests`.

### Running Tests

All commands given are assumed to be run from the root of the repo.

To run all tests:
```
docker compose run --service-ports --use-aliases --rm tests
```

To run all tests within a test file:
```
docker compose run --service-ports --use-aliases --rm tests [TESTFILE]
```
where TESTFILE is the path of the test file *relative to the TESTS directory* (ex: `test_command.py`, `test_zip.py`).


To run a single test within a test file:
```
docker compose run --rm --service-ports --use-aliases tests [TESTFILE]::[TESTNAME]
```
where TESTFILE is as above, and TESTNAME is the name of the test within the test file (ex: `test_elf.py::test_virtual_valid`).

See [pytest docs](https://docs.pytest.org/en/7.1.x/how-to/usage.html) for more invocation options.

### Debugging a Failed Test

Add a `breakpoint()` before the failing assertion and manually invoke the single test.

OR for a single failing test, `--pdb` with the failing test will automatically start the python debugger within the container.

### Adding a Test

#### Pytest Convention
All python tests must follow pytest conventions to be picked up by the test runner.
- New test files should be added to the `chalk-internal/tests` directory as `test_filename.py`.
- Individual tests within the test file should be named `test_testname`.

#### Test Data
All test data should be added to `chalk-internal/tests/data` directory.

#### Test Fixtures
Global test fixtures are defined in `conftest.py`. Currently there are two fixtures that are used across all tests:
- `tmp_data_dir`: creates a temporary data directory for each test that will be destroyed at the end of that test. All tests are run from within the temporary directory.
- `chalk`: retrieves the chalk binary in `chalk-internal` to be used in testing. Of note that the scope of this fixture is `session`, so this will be the SAME chalk binary for ALL tests in a single run. Some tests, such as the ones that change config in `test_config.py`, modify the chalk binary itself -- those tests should make a copy of the `chalk` object and modify the copy, instead of acting directly on the binary returned by the fixture.

#### Running Chalk Within A Test
`chalk-internal/tests/chalk` contains `runner.py` which provides some utility functions for the `chalk` object returned by the fixture, including calling `chalk insert` and `chalk extract`. The chalk binary can also be run directly using `subprocess.run`.