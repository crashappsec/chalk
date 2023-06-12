version       = "0.4.3"
author        = "John Viega"
description   = "Software artifact metadata to make it easy to tie " &
                "deployments to source code and collect metadata."
license       = "GPLv3"
srcDir        = "src"
bin           = @["chalk"]

# Dependencies
requires "nim >= 1.6.8"
requires "https://github.com/crashappsec/con4m == 0.7.16"
requires "https://github.com/crashappsec/nimutils == 0.4.0"
requires "nimSHA2 == 0.1.1"
requires "glob == 0.11.2"
requires "https://github.com/viega/zippy == 0.10.7"

#% INTERNAL
task debug, "Package the debug build":
  # additional flags are configured in config.nims
  exec "nimble build"

task release, "Package the release build":
  # additional flags are configured in config.nims
  exec "nimble build --define:release --opt:size"
  exec "strip " & bin[0]

let bucket = "crashoverride-chalk-binaries"

task s3, "Publish release build to S3 bucket. Requires AWS cli + creds":
  exec "nimble release"
  exec "ls -lh " & bin[0]
  exec "aws s3 cp " & bin[0] & " s3://" & bucket & "/latest/$(uname -m)"
  exec "aws s3 cp " & bin[0] & " s3://" & bucket &
          "/" & version & "/$(uname -m)"
