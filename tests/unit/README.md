# Chalk Unit Testing

This directory contains unit tests for chalk. These tests are run via `make unit-tests` from the chalk repository root, which uses `docker compose` to run the `chalk` container which runs `nimble test`.

The unit tests also be run directly via `nimble test` in the chalk repository root.

Both of these options will run all tests in the `tests-nim` directory.

(Note that the (Python-based) integration tests are in the `tests` directory instead.)

## Running A Single Test

Following the pattern for integration tests, arguments can be passed to `make` to run a single unit test, ex:

```
make unit-tests args="pattern 'tests-nim/test_semver.nim'"
```

This will run the `test_semver.nim` file and only this file.

Similarly, args can be passed to `nimble test:

```
nimble test args="pattern 'tests-nim/test_semver.nim'"
```

which will accomplish the same as above.
