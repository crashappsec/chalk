# Building Chalk

For a majority of users downloading a pre-compiled [stable Chalk release](https://github.com/crashappsec/chalk/releases)
is the recommended way to use Chalk, however if you would prefer to
build Chalk from source please follow the instructions and ensure you
have the correct dependencies installed.

## Building Chalk in a Container (Recommended)

If you are running on an **x64 Linux** distribution the easiest way to build 
the project is to use the supplied container to both compile and run Chalk. 
This requires that you have [docker installed](https://docs.docker.com/engine/install/).

To build and run Chalk run the following command from the root of the repository:

```
docker compose run --rm chalk-compile
```

alternatively the Makefile has a target defined that runs the above command:

```
make chalkcontainer
```

Once the compilation has finished the resulting static `chalk` binary will be 
written to the current working directory and can be run directly on any x64
Linux system:

```
./chalk
```

By default debug versions of Chalk are compiled to aid in development, if
you would like to build a release version of simply use the following commands 
in place of those above:

```
docker compose run --rm chalk-compile-release
```

or

```
make chalkcontainerrelease
```

You will likely notice that the `release` binary runs quicker than the `debug`.


## Building Chalk Natively

If you would like to build Chalk natively on your system you will need to have 
the [nimble](https://github.com/nim-lang/nimble) package manager installed. 

To build Chalk natively on an **x64 Linux** distribution run the following 
command from the root of the repository:

```
nimble build
```
Nimble will do the rest and download additional dependencies at the correct versions

alternatively the Makefile has a target defined that runs the above command:

```
make chalk
```

If you are running on an **ARM64 macOS** system ensure that you have [OpenSSL 3 
installed via homebrew](https://formulae.brew.sh/formula/openssl@3) (Instructions for installing homebrew can be found [here](https://brew.sh/)). 

```
brew install openssl@3
```

Once OpenSSL3 is install Chalk for Mac can be compiled by running the following 
commands from the root of the repository:

```
DYLD_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib con4m gen ./src/configs/chalk.c42spec --language=nim --output-file=./src/c4autoconf.nim
nimble build
```
alternatively the Makefile has a target defined that runs the above command:

```
make chalkosx
```

By default debug versions of Chalk are compiled to aid in development, if
you would like to build a release version of simply use the following command 
in place of the above:

```
nimble build -d:release
```
or
```
make chalkrelease
```
or
```
make chalkosxrelease
```

You should notice that the `release` build runs noticibly quicker than the `debug` build.

## Issues

If you encounter any issues with building Chalk using the above instructions
please submit an issue in [Chalk GitHub repository](https://github.com/crashappsec/chalk/issues)            