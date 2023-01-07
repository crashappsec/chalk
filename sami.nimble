# Package

version       = "0.2.0"
author        = "John Viega"
description   = "Reference implementation of the SAMI spec for inserting metadata into software artifacts"
license       = "Apache-2.0"
srcDir        = "src"
bin           = @["sami"]

# Dependencies

requires "nim >= 1.6.8"
requires "https://github.com/crashappsec/con4m == 0.4.2"
requires "https://github.com/crashappsec/nimutils == 0.1.1"
requires "argparse == 3.0.0"
requires "nimsha2 == 0.1.1"
requires "https://github.com/viega/nimaws == 0.3.4"
requires "glob == 0.11.2"

# Docs generated with
# nimble --project --index:on --git.url:https://github.com/crashappsec/con4m.git --git.commit:`version`
# --outdir:docs src/con4m.nim
