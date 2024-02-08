## `chalk.nimble` imports this file to set its `version` value.
## It'd be better for the below proc to be in `src/config.nim`, but
## `nimble build` currently fails when the nimble file imports that module.
## So we have this separate file for now.
import std/[os, strscans, strutils]

proc getChalkVersion*(withSuffix = true): string =
  ## Returns the value of `chalk_version` in `base_keyspecs.c4m`.
  result = ""
  const path = currentSourcePath().parentDir() / "configs" / "base_keyspecs.c4m"
  for line in path.staticRead().splitLines():
    const pattern = """chalk_version$s:=$s"$i.$i.$i$*"$."""
    let (isMatch, major, minor, patch, suffix) = line.scanTuple(pattern)
    if isMatch and major >= 0 and minor >= 0 and patch >= 0:
      let version = $major & '.' & $minor & '.' & $patch
      if withSuffix:
        return version & suffix
      else:
        return version
  raise newException(ValueError, "Couldn't get `chalk_version` value from " & path)
