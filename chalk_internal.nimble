version       = "0.1.1"
author        = "John Viega"
description   = "Software artifact metadata to make it easy to tie " &
                "deployments to source code and collect metadata."
license       = "GPLv3"
srcDir        = "src"
bin           = @["chalk"]

# Dependencies
requires "nim >= 1.6.12 & < 2.0"
requires "https://github.com/crashappsec/con4m == 0.8.10"
requires "https://github.com/crashappsec/nimutils == 0.4.7"
requires "nimSHA2 == 0.1.1"
requires "glob == 0.11.2"
requires "https://github.com/viega/zippy == 0.10.7"

# this allows to get version externally without grepping for it in the file
task version, "Show current version":
  echo version

proc con4mDevMode() =
  ## The devmode script is for use when doing combined work across
  ## chalk and con4m / nimutils; it simply copies any con4m and nimble
  ## source code into your most recent nimble directory before running
  ## build.
  ##
  ## Note that by default the script assumes that con4m/ and nimtuils/
  ## repos live under ../con4m/ and ../nimutils/ locally, and that
  ## nimble's package directory is at ~/.nimble/pkgs. But you can use
  ## environment variables: `CON4M_DIR`, `NIMUTILS_DIR`, `NIMBLE_PKGS`.
  ##
  ## And, the script only does stuff if `CON4M_DEV` is set in your
  ## environment (the value doesn't matter).
  exec "bin/devmode"

proc depCheck() =
  ## At compile time, this will generate c4autoconf if the file doesn't
  ## exist, or if the spec file has a newer timestamp.
  echo "Running dependency test on chalk.c42spec"
  echo staticexec("if test \\! src/c4autoconf.nim -nt " &
                  "src/configs/chalk.c42spec; " &
                  "then echo 'Config file schema changed. Regenerating " &
                  "c4autoconf.nim.' ; con4m gen src/configs/chalk.c42spec " &
                  "--language=nim --output-file=src/c4autoconf.nim; else " &
                  "echo No change to chalk.c42spec; fi")

before build:
  con4mDevMode()
  depCheck()

before install:
  depCheck()

# Add --trace if needed.
after build:
  exec "./chalk --no-use-external-config --skip-command-report load default"

task debug, "Get a debug build":
  # additional flags are configured in config.nims
  exec "nimble build --define:debug"

#% INTERNAL
task release, "Package the release build":
  exec "nimble build"
  exec "strip " & bin[0]

let bucket = "crashoverride-chalk-binaries"

task s3, "Publish release build to S3 bucket. Requires AWS cli + creds":
  exec "nimble release"
  exec "ls -lh " & bin[0]
  exec "aws s3 cp " & bin[0] & " s3://" & bucket & "/latest/$(uname -m)"
  exec "aws s3 cp " & bin[0] & " s3://" & bucket &
          "/" & version & "/$(uname -m)"
