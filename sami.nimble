version       = "0.2.0"
author        = "John Viega"
description   = "Reference implementation of the SAMI spec for inserting metadata into software artifacts"
license       = "Apache-2.0"
srcDir        = "src"
bin           = @["sami"]

# Dependencies

requires "nim >= 1.6.8"
requires "https://github.com/crashappsec/con4m >= 0.4.8"
requires "https://github.com/crashappsec/nimutils >= 0.1.7"
requires "nimsha2 == 0.1.1"
requires "glob == 0.11.2"
requires "https://github.com/guibar64/formatstr == 0.2.0"

# Docs generated with
# nimble --project --index:on --git.url:https://github.com/crashappsec/con4m.git --git.commit:`version`
# --outdir:docs src/con4m.nim

task debug, "Package the debug build":
  # additional flags are configured in config.nims
  exec "nimble build"

task release, "Package the release build":
  # additional flags are configured in config.nims
  exec "nimble build --define:release --opt:size"
  exec "strip " & bin[0]
