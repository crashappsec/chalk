version       = "0.1.1"
author        = "John Viega"
description   = "Software artifact metadata to make it easy to tie " &
                "deployments to source code and collect metadata."
license       = "GPLv3"
srcDir        = "src"
bin           = @["chalk"]

# Dependencies
requires "nim >= 1.6.12"
# TODO figure out why == does not work here
requires "https://github.com/crashappsec/con4m.git#v0.1.3"
requires "https://github.com/crashappsec/nimutils.git#v0.1.3"
requires "https://github.com/viega/zippy == 0.10.7"
requires "https://github.com/aruZeta/QRgen == 3.0.0"

import std/strformat

# this allows us to get version externally without grepping for it in the file
task version, "Show current version":
  echo version

proc con4mDevMode() =
  let script = "bin/devmode"
  # only missing in Dockerfile compile step
  if not fileExists(script):
    return
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
  exec script

proc depCheck() =
  ## At compile time, this will generate c4autoconf if the file doesn't
  ## exist, or if the spec file has a newer timestamp.
  echo "Looking for changes to src/configs/chalk.c42spec"

  echo staticexec("""
OUTFILE=src/c4autoconf.nim
SPEC=src/configs/chalk.c42spec

# Docker build won't see the spec file when building, and shouldn't error.
if [ ! -e ${SPEC} ] ; then
  exit 0
fi

if [ ! ${OUTFILE} -nt  ${SPEC} ] ; then
  echo Config schema changed. Regenerating c4autoconf.nim.
  con4m gen ${SPEC} --language=nim --output-file=${OUTFILE}
else
  echo No change to chalk.c42spec
fi
""")

before build:
  con4mDevMode()
  depCheck()

before install:
  depCheck()

# Add --trace if needed.
after build:
  when not defined(debug):
    exec "set -x && strip " & bin[0]
  exec "set -x && ./" & bin[0] & " --no-use-external-config --skip-command-report load default"

task debug, "Get a debug build":
  # additional flags are configured in config.nims
  exec "nimble build --define:debug"

#% INTERNAL
task release, "Package the release build":
  exec "nimble build"

let bucket = "crashoverride-chalk-binaries"

task s3, "Publish release build to S3 bucket. Requires AWS cli + creds":
  exec "nimble release"
  exec "ls -lh " & bin[0]
  exec "aws s3 cp " & bin[0] & " s3://" & bucket & "/latest/$(uname -m)"
  exec "aws s3 cp " & bin[0] & " s3://" & bucket &
          "/" & version & "/$(uname -m)"
