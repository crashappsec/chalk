# Chalk Testing

This directory contains all the basic functionality tests for chalk. Tests are run via `make tests`, which uses `docker compose` to run the `tests` container which internally uses the `pytest` framework.

While `pytest` can be used to run the tests directly, it is recommended to use the makefile script instead, as that provides a more consistent developer experience.

## Setup

Before running tests, ensure that `docker` and `docker compose` are installed.

### Tests Container

Please ensure you have an up-to-date container with:

```sh
docker compose build tests
```

Note that building the `tests` container will set up the `pytest` framework needed to run the tests, but the container will NOT have a copy of the chalk binary to test against. This is discussed in the next section.

### Chalk Binary

Upon starting a test run, the script will first look for an up-to-date chalk binary in the root directory of the repo. If there is no chalk binary, or if the chalk binary is not up to date (ie, there are local code changes that have not yet been built), the script will rebuild the chalk binary.

WARNING: If there is already a chalk binary in the root directory that the script considers "out of date", this binary will be DELETED. If you want to keep this binary, move or rename it.

Tests will always rebuild the binary if it detects a code change in the underlying nim code. However, you will need to build `chalk` manually when switching between `release` and `debug` builds:

1. By default, the testing script will build a `release` binary for chalk, so if you want to test against the `debug` build instead you must build it yourself.
2. If you have been working with a `debug` build so far, but want to switch to `release`, you will need to rebuild manually as the test script will not rebuild if there have not been any code changes.

The quickest way to manually build a binary with the current local changes is:

1. Build chalk deps container:

   ```sh
   docker compose build chalk
   ```

   (this step can be skipped if the `chalk` container is up to date)

2. Compile `chalk`. For a release build:
   ```sh
   # root of the repo
   make chalk
   ```
   For a debug build:
   ```sh
   # root of the repo
   make debug
   ```

The second command should drop a `chalk` binary that is usable by tests. You can also manually build with `nimble build`, but this is not recommended as it doesn't guarantee that the architecture will be compatible with the `tests` container.

WARNING: Debug builds are very slow, so it is not recommended to run the entire test suite on a debug build.

## Running Tests

### Makefile

The easiest way to run tests is via the makefile. All commands given are assumed to be run from the root of the repo.

To run all tests:

```sh
# root of the repo
make tests
```

To run all tests within a test file:

```sh
# root of the repo
make tests args="[TESTFILE]"
```

where `TESTFILE` is the path of the test file (ex: `test_command.py`, `test_zip.py`).

Note: the path **MUST** be relative to `tests/` folder (NOT the repo root).

To run a single test within a test file:

```sh
# root of the repo
make tests args="[TESTFILE]::[TESTNAME]"
```

where `TESTFILE` is as above, and `TESTNAME` is the name of the test
within the test file (ex: `test_elf.py::test_virtual_valid`).

To run a single case of a single test:

```sh
# root of the repo
make tests args="[TESTFILE]::[TESTNAME][test-case]"
```

ex:

```sh
make tests args="test_elf.py::test_virtual_valid[copy_files0]"
```

Any arguments passed in through `args` will be directly passed through to the underlying `pytest` call. See [pytest docs](https://docs.pytest.org/en/7.1.x/how-to/usage.html) for more invocation options.

### Running Tests Directly

While tests can be run directly via `pytest`, this is not recommended; they are intended to be run through the `docker compose` environment, and many of them are likely to fail without the correct setup.

WARNING: These tests are ELF only.

If you would really like to run tests directly, ensure that you have the following:

- `python` version 3.11 or greater
- `pipx` (recommended) or `pip` package installer for python
- `docker` for the docker tests

To set up the testing framework:

1. Install poetry with `pipx install poetry`
2. From the repository root: `cd ./tests`
3. Install dependencies with `poetry install` (the list of dependencies to be installed is located at `tests/pyproject.toml`)

To run the tests:

1. From the repository root: `cd ./tests`
2. Start poetry shell with `poetry shell`
3. Run tests with `pytest` (flags and arguments as in the previous section)

WARNING: Since the chalk tests were intended to be run via `docker compose`, running them directly through `pytest` will cause a number of failures. In particular:

- Several tests rely on the chalk server or other services to be started by `docker compose`, and these tests will not run if the services are not available.
- Several tests that act on elf binaries expect the binaries to be found on host (ex: at `/usr/bin/ls`), and if these binaries don't exist, the test will fail.
- Any tests involving an elf binary will fail on MacOS.
- Several tests attempt to read or write files on host outside of the repository root (ex: config tests will attempt to put a chalk config in `/etc/chalk`). If the test process doesn't have the appropriate permissions to do so, the test will fail.

Also note that some files may not be cleaned up, like chalk intermediate files when building docker. These files will need to be manually deleted.

### Pytest Flags

#### Slow Tests

To run slower tests which are by default skipped add the `--slow` argument:

```sh
# root of the repo
make tests args="--slow"
```

#### Live Logs

By default logs will only show for failed tests. To show all logs of running tests as they run, add the `--logs` argument:

```sh
make tests args="--logs"
```

#### Parallel Tests

To run tests in parallel, add `-nauto` argument which will run tests
in number of workers as there are CPU cores on the system:

```sh
make tests args="-nauto"
```

If you would like you can also hardcode number of workers like `-n4`.
Note that parallel tests does not work with various other pytest flags
such as `--pdb`.

## Debugging a Failed Test

### PDB

Simplest approach is for `pytest` to enter a debugger on test failure.
To do that run test(s) with `--pdb` flag:

```sh
# root of the repo
make tests args="[TESTFILE]::[TESTNAME] --pdb"
```

Alternatively you can add `breakpoint()` before the failing assertion and manually invoke the single test.

### Container Shell

You can also drop into a shell in the ` tests` container via `docker compose run --entrypoint=sh tests`, and from there run `pytest` manually.

## Adding a Test

Currently, all tests in the `tests` directory are functional tests for the chalk binary. Any unit tests should NOT be added here -- they should go into the nim source code per nim testing conventions.

All python tests must follow `pytest` conventions to be picked up by the test runner:

- New test files should be added to the `tests/` directory as `test_filename.py`. A new test file should be created to test new functionality, for example if support has been added for a new codec.
- Individual tests should be added to a test file as a new function as `test_functionname`. Each individual test in a test file should test some aspect of that test file's functionality; if the test you want to add doesn't fit, consider if it would be more appropriate to create a new test file and add it there instead.
- A new test case for an existing test can be added via the pytest `paramatrize` fixture, if appropriate.

### Datafile Location

All new test files should be added to the `tests/` directory, and any test data should be added to the `tests/data` directory.

WARNING: Any files (including test files and data files) that are NOT in the root directory of the reporistory will not be accessible from within the `tests` container. Any data files that need to be in a specific path for testing (ex: config files loaded from `/etc/chalk`) must be stored in `tests/data`, and then as part of test setup which happens inside the container after startup, copied to the target path. A config file located in `/etc/chalk` on host WILL NOT be available from inside the testing container.

### Test Fixtures

Global test fixtures are defined in `conftest.py`. Any test fixtures used across multiple test files should be defined in `conftest.py`; any test fixtures used only in a single test file should be defined in the test file.

More information about fixtures can be found [here](https://docs.pytest.org/en/7.2.x/fixture.html).

The following is a summary of the most commonly used fixtures in chalk testing:

- `tmp_data_dir`: creates a temporary data directory for each test that will be destroyed at the end of that test. All tests are run from within their temporary directories, and each test has its own temporary directory that does not conflict with any other temporary directories. It is recommended that any tests that mutate data (ex: chalking a system binary) first copy that data into the `tmp_data_dir` and then act on the copy, so that subsequent or parallel tests don't run into conflicts.
- `copy_files`: copies files into the temporary directory.
- `chalk`: retrieves the chalk binary to be used in testing (which will be the chalk binary at the root of the repository), and loads it with the default testing configuration which subscribes to console output (ensuring that we get chalk reports to stdout even if chalk is not run in a tty). Note that the scope of this fixture is `session`, so this will be the SAME chalk binary for ALL tests in a single invocation of `make tests`. If your test needs to make any changes to the chalk binary itself, use `chalk_copy` instead.
- `chalk_copy`: makes a copy of the chalk binary loaded with the default testing configuration into the test's `tmp_data_dir`. The test will invoke this copy, and it will be removed as part of the test's cleanup afterwards. Any tests that make changes to the chalk binary, such as the ones that change `config` in `test_config.py`, should use this fixture so that the changes don't persist across the remaining tests.
- `chalk_default`: retrieves the chalk binary without loading the default testing configuration.

### Running Chalk Within A Test

`tests/chalk` contains `runner.py` which provides some utility functions for the `chalk` object returned by the fixture, including calling `chalk insert` and `chalk extract` and returning the resulting chalk report in json format.

To validate the chalk reports, there are some utility functions provided in `tests/chalk/validate.py`.

### Docker

Since chalk supports some docker commands, some tests may need to call docker build/run/push. Note that only `test_docker.py` has a fixture to clean up images or containers afterwards, so if you are adding a test that calls docker in a different file, ensure that the test cleans up after ifself (such as by running with `--rm`, or calling `docker prune` afterwards). Otherwise the test images/containers created will persist ON HOST until they are manually removed.
