# Dust Lambda Extension

## overview.

The `dust` extension is meant to be used with zip archive based AWS Lambda
deployments that have had both a chalk mark and a chalk binary injected into
them (i.e., `chalk insert --inject-binary serverless.zip`).

## getting started.

A [Makefile](./Makefile) is provided for convenience to perform common setup and
development operations, including bootstrapping your development environment.
After satisfying the [dependencies](#dependencies) below, simply run
`make init`.

**dependencies:**

- GNU Make
- pre-commit (can be installed via pip, pipx, brew, pacman, etc.)
- zip

To see what individual commands are available target the `help` goal:

```bash
make help
```

## deployment.

Crash Override maintains a public release of the `dust` Lambda Extension which
is availble for use but you may also build and publish your own version of
`dust` if that is required for your deployment strategy.

### Using Crash Override's Published Extension

<!--TODO-->

### Building, publishing and Deploying Yourself

<!--TODO-->
