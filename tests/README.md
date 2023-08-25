# Chalk Testing

This directory contains all the basic functionality tests for chalk.
Tests are run via docker compose in a separate `tests` container which
internally uses the `pytest` framework.

## Requirements

### Chalk Binary

Tests assume that a chalk binary is present in the root directory of
the repo, and will use that binary in all tests cases.

More details on building the chalk binary can be found in the main
[BUILD.sh](../BUILD.sh), but the quickest way to get a binary with the
current local changes is:

1. Build chalk deps container:

   ```sh
   docker compose build chalk
   ```

   (this step can be skipped if the `chalk` container is up to date)

1. Compile `chalk`:

   ```sh
   # root of the repo
   make chalk
   ```

The second command should drop a `chalk` binary that is usable by tests.

### Tests Container

Please ensure you have an up-to-date container with:

```sh
docker compose build tests
```

### Running Tests

All commands given are assumed to be run from the root of the repo.

To run all tests:

```sh
# root of the repo
./make tests
```

To run all tests within a test file:

```sh
# root of the repo
./make tests [TESTFILE]
```

where `TESTFILE` is the path of the test file
(ex: `test_command.py`, `tests/test_zip.py`).
Note that path could be relative to either `tests/` or root of the repo.

To run a single test within a test file:

```sh
# root of the repo
./make tests [TESTFILE]::[TESTNAME]
```

where `TESTFILE` is as above, and `TESTNAME` is the name of the test
within the test file (ex: `test_elf.py::test_virtual_valid`).

See [pytest docs](https://docs.pytest.org/en/7.1.x/how-to/usage.html)
for more invocation options.

To run slower tests which are by default skipped add `--slow`` argument:

```sh
# root of the repo
./make tests --slow
```

### Debugging a Failed Test

Simplest approach is for `pytest` to enter a debugger on test failure.
To do that run test(s) with `--pdb` flag:

```sh
# root of the repo
./make tests [TESTFILE]::[TESTNAME] --pdb
```

Alternatively you can add `breakpoint()` before the failing assertion
and manually invoke the single test.

### Adding a Test

#### Pytest Convention

All python tests must follow `pytest` conventions to be picked up by the
test runner.

- New test files should be added to the `tests/` directory as
  `test_filename.py`.
- Individual tests within the test file should be named `test_testname`.

#### Test Data

All test data should be added to `tests/data` directory.

#### Test Fixtures

Global test fixtures are defined in `conftest.py`. Currently there are
two fixtures that are used across all tests:

- `tmp_data_dir`: creates a temporary data directory for each test that
  will be destroyed at the end of that test. All tests are run from within
  the temporary directory.
- `chalk`: retrieves the chalk binary to be used in testing. Of note
  that the scope of this fixture is `session`, so this will be the SAME
  chalk binary for ALL tests in a single run.
- `chalk_copy`: Some tests, such as the ones that change `config` in
  `test_config.py`, modify the chalk binary itself -- those tests should
  use this fixture which makes a copy of `chalk` for each test case.

#### Running Chalk Within A Test

`tests/chalk` contains `runner.py` which provides some utility functions
for the `chalk` object returned by the fixture, including calling
`chalk insert` and `chalk extract`. The chalk binary can also be run
directly using `subprocess.run`.
