# At the time of writing, `nimble build` fails when this proc is in `src/config.nim`
import std/[os, strscans, strutils]

proc getChalkVersion*(): string =
  ## Returns the value of `chalk_version` in `base_keyspecs.c4m`.
  result = ""
  const path = currentSourcePath().parentDir() / "configs" / "base_keyspecs.c4m"
  for line in path.staticRead().splitLines():
    const pattern = """chalk_version$s:=$s"$i.$i.$i$*"$."""
    let (isMatch, major, minor, patch, suffix) = line.scanTuple(pattern)
    if isMatch and major == 0 and minor in 0..100 and patch in 0..100 and suffix == "":
      return $major & '.' & $minor & '.' & $patch
  raise newException(ValueError, "Couldn't get `chalk_version` value from " & path)
