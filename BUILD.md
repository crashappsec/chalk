# Building Chalk

For a majority of users downloading a pre-compiled
[stable Chalk release](https://github.com/crashappsec/chalk/releases)
is the recommended way to use Chalk, however if you would prefer to
build Chalk from source please follow the instructions and ensure you
have the correct dependencies installed.

## Release vs Debug

Chalk can be compile in either `debug` or `release` mode.
`debug` mode can aid in debugging `chalk` however you will likely notice
that the `release` binary runs quicker than the `debug` binary.
Below instructions show commands for building `release` binary
but the comments in the code snippets will show how to build
the `debug` binary instead. In most cases the difference
is either:

- setting `CHALK_BUILD` to either `release` or `debug`
- calling appropriate `make` target - `release` or `debug`

## Building Chalk in a Container (Recommended)

If you are running on an **x64 Linux** distribution the easiest way to build
the project is to use the supplied container to both compile and run Chalk.
This requires that you have [docker installed](https://docs.docker.com/engine/install/).

To build `chalk` run the following command from the root of the repository:

```sh
make chalk   # rebuilds only if source files changed
make release # always builds release binary
# for debug build equivalent:
# CHALK_BUILD=debug make chalk
# make debug
```

Once the compilation has finished the resulting static `chalk` binary will be
written to the current working directory and can be run directly on any x64
Linux system:

```sh
./chalk
```

## Building Chalk Natively

If you would like to build Chalk natively on your system you will need to have
the [nimble](https://github.com/nim-lang/nimble) package manager installed.

To build Chalk natively on an **x64 Linux** distribution the commands are
the same as for docker builds except they will require disabling docker
by setting `DOCKER` environment variable to an empty string:

```sh
export DOCKER=
make chalk   # rebuilds only if source files changed
make release # always builds release binary
# for debug build equivalent
# CHALK_BUILD=debug make chalk
# make debug
```

Nimble will do the rest and download additional dependencies at the correct versions

### MacOS Requirements

If you are running on an **macOS** system ensure that you have
[OpenSSL 3 installed via homebrew](https://formulae.brew.sh/formula/openssl@3)
(Instructions for installing homebrew can be found [here](https://brew.sh/)).

```sh
brew install openssl@3
```

Once MacOS requirements are satisfied, the same commands can be used as
above to compile chalk on MacOS.

## Issues

If you encounter any issues with building Chalk using the above instructions
please submit an issue in
[Chalk GitHub repository](https://github.com/crashappsec/chalk/issues)
