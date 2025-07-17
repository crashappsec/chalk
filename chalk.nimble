import std/[cmdline, strformat, strscans, strutils, os]

when fileExists("src/config_version.nim"):
  from src/config_version import getChalkVersion
else:
  proc getChalkVersion(): string = "0"

version       = getChalkVersion().split("-")[0]
author        = "John Viega"
description   = "Software artifact metadata to make it easy to tie " &
                "deployments to source code and collect metadata."
license       = "GPLv3"
srcDir        = "src"
bin           = @["chalk"]

# Dependencies
requires "nim >= 2.0.8"
requires "https://github.com/crashappsec/con4m#97990545e21f2862d28eb1d736fd376fa0d766be"
requires "https://github.com/viega/zippy == 0.10.7" # MIT
requires "https://github.com/NimParsers/parsetoml == 0.7.1" # MIT

# this allows us to get version externally
task version, "Show current version":
  echo version

task test, "Run the unit tests":
  var args = ""
  for s in commandLineParams():
    discard s.scanf("args=$+", args) # Sets `args` to any user-provided value.
  if args == "":
    args = "--verbose pattern 'tests/unit/*.nim'" # By default, run all unit tests.
  exec "testament " & args

# Add --trace if needed.
after build:
  # ideally this should work:
  # when not defined(debug):
  # however debug symbol doesnt seem to be defined by nimble?
  # and it always runs strip
  # instead we check env var set by Makefile
  if getEnv("DEBUG", "false") != "true":
    exec "set -x && strip " & bin[0]
  exec "set -x && ./" & bin[0] & " --debug --no-use-external-config --skip-command-report load default"

task debug, "Get a debug build":
  # additional flags are configured in config.nims
  exec "nimble build --define:debug"

task release, "Package the release build":
  exec "nimble build"

task performance, "Get a build that adds execution profiling support":
  exec "nimble build --profiler:on --stackTrace:on -d:cprofiling"

task memprofile, "Get a build that adds memory profiling to the binary":
  exec "nimble build --profiler:off --stackTrace:on -d:memProfiler -d:cprofiling"
