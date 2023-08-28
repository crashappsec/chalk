# Building Chalk

For a majority of users downloading a pre-compiled
[stable Chalk release](https://github.com/crashappsec/chalk/releases)
is the recommended way to use Chalk, however if you would prefer to
build Chalk from source please follow the instructions and ensure you
have the correct dependencies installed.

## Building Chalk in a Container (Recommended)

If you are running on a **Linux** distribution the easiest way to
build the project is to use the supplied container to both compile and
run Chalk, which will install all dependencies properly.  This
requires that you have [docker
installed](https://docs.docker.com/engine/install/).

To build `chalk` run the following command from the root of the repository:

```sh
make  # rebuilds only if source files changed
```

You can build a debug build with `make debug`, which will result in a
considerably slower binary, but will enable stack traces.

Once the compilation has finished the resulting static `chalk` binary will be
written to the current working directory and can be run directly on any x64
Linux system:

```sh
./chalk
```

## Building Chalk Natively

If you would like to build Chalk natively on your system (particularly
on MacOs), you will need to have Nim installed, generally with the
Nimble package manager.

The easiest way to do this, is with `choosenim` and then setting it to
version 1.6.14 (Chalk does not work with Nim 2.0):

```sh
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
export PATH=$PATH:~/.nimble/bin/
choosenim 1.6.14
```

All nim tools will live in ~/.nimble/bin, if you want to update in
your shell's config file. Then, from the root of the repository, you
can build chalk simply by typing:

```sh
nimble build
```

Nimble will do the rest and download a few additional
dependencies. Nimble keeps all its state in ~/.nimble; choosenim keeps
the compiler in ~/.choosenim; you can delete the 2.0 toolchain if
desired.

## Issues

If you encounter any issues with building Chalk using the above instructions
please submit an issue in
[Chalk GitHub repository](https://github.com/crashappsec/chalk/issues)
