version       = "0.1.0"
author        = "John Viega"
description   = "Software artifact metadata to make it easy to tie " &
                "deployments to source code and collect metadata."
license       = "GPLv3"
srcDir        = "src"
bin           = @["chalk"]

# Dependencies
requires "nim >= 1.6.8"
requires "https://github.com/crashappsec/con4m == 0.8.5"
requires "https://github.com/crashappsec/nimutils == 0.4.6"
requires "nimSHA2 == 0.1.1"
requires "glob == 0.11.2"
requires "https://github.com/viega/zippy == 0.10.7"

#% INTERNAL
task debug, "Package the debug build":
  # additional flags are configured in config.nims
  exec "nim c --passL:-static ./src/getlibpath.nim"
  exec "nimble build"

task release, "Package the release build":
  var flags =
    when defined(macosx):
      ""
    else:
      "--passL:-static"
  exec "nim c " & flags & " ./src/getlibpath.nim"
  exec "nimble build --define:release --opt:size " & flags
  exec "strip " & bin[0]

let bucket = "crashoverride-chalk-binaries"

task s3, "Publish release build to S3 bucket. Requires AWS cli + creds":
  exec "nimble release"
  exec "ls -lh " & bin[0]
  exec "aws s3 cp " & bin[0] & " s3://" & bucket & "/latest/$(uname -m)"
  exec "aws s3 cp " & bin[0] & " s3://" & bucket &
          "/" & version & "/$(uname -m)"

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
  depCheck()

before install:
  depCheck()


# Add --trace if needed.
after build:
  exec "./chalk --no-use-external-config --skip-command-report load default"

after install:
  exec "./chalk --no-use-external-config --skip-command-report load default"
