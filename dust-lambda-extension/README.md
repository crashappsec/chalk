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

- Bash >=5.1
- GNU Make
- Python >=3.12
- venv
- pip
- zip

To see what individual commands are available target the `help` goal:

```bash
make help
```

## development.

Bootstrap the development environment with `make init` which creates sets up a
Python virtualenv and development dependencies.

Run lint the project with `make lint` which will format documentation and the
extension application code.

## deployment.

Crash Override maintains a public release of the `dust` Lambda Extension which
is availble for use but you may also build and publish your own version of
`dust` if that is required for your deployment strategy.

### Using Crash Override's Published Extension

<!--TODO-->

### Building, publishing and Deploying Yourself

<!--TODO-->
