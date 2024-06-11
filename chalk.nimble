import std/[cmdline, strformat, strscans, strutils]
from src/config_version import getChalkVersion

version       = getChalkVersion(withSuffix = false)
author        = "John Viega"
description   = "Software artifact metadata to make it easy to tie " &
                "deployments to source code and collect metadata."
license       = "GPLv3"
srcDir        = "src"
bin           = @["chalk"]

# Dependencies
requires "nim >= 2.0.0"
requires "https://github.com/crashappsec/con4m#dc5e76564d7abb962dc6519fd81f34760091b34d"
requires "https://github.com/viega/zippy == 0.10.7" # MIT

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

before build:
  con4mDevMode()

# Add --trace if needed.
after build:
  when not defined(debug):
    exec "set -x && strip " & bin[0]
  exec "set -x && ./" & bin[0] & " --debug --no-use-external-config --skip-command-report load default"

task debug, "Get a debug build":
  # additional flags are configured in config.nims
  exec "nimble build --define:debug"

task release, "Package the release build":
  exec "nimble build"

let completion_script_version = version

task mark_completion, "Replace the chalk mark in a completion script, including the articact version":

  exec """cat > tmpcfg.c4m << EOF
keyspec.ARTIFACT_VERSION.value = "REPLACE_ME"
keyspec.CHALK_PTR.value = ("This mark determines when to update the script." +
" If there is no mark, or the mark is invalid it will be replaced. " +
" To customize w/o Chalk disturbing it when it can update, add a valid " +
" mark with a version key higher than the current chalk verison, or " +
" use version 0.0.0 to prevent updates")

mark_template.mark_default.key.BRANCH.use = false
mark_template.mark_default.key.CHALK_RAND.use = false
mark_template.mark_default.key.CODE_OWNERS.use = false
mark_template.mark_default.key.COMMIT_ID.use = false
mark_template.mark_default.key.PLATFORM_WHEN_CHALKED.use = false
EOF
""".replace("REPLACE_ME", completion_script_version)

  exec "./chalk --use-external-config --config-file=./tmpcfg.c4m --no-use-embedded-config --skip-command-report insert src/autocomplete"
  exec "rm ./tmpcfg.c4m"
