##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  options,
  posix,
]
import "."/[
  chalkjson,
  collect,
  config_version,
  plugin_api,
  run_management,
  selfextract,
  subscan,
  types,
  utils/fd_cache,
  utils/files,
]

const
  staticScriptLoc = "autocomplete/default.bash"
  bashScript      = staticRead(staticScriptLoc)
  autoCompleteLoc = "~/.local/share/bash_completion/completions/chalk.bash"

when hostOS == "linux":
  proc makeCompletionAutoSource(dst: string) =
    let
      ac       = "~/.bash_completion"
      acpath   = resolvePath(ac)
      toWrite  = ". " & dst
      contents = tryToLoadFile(acpath)
    if toWrite in contents:
      return
    withFileStream(acpath, mode = fmAppend, strict = false):
      if stream == nil:
        warn("Cannot write to " & acpath & " to turn on autocomplete.")
        return
      try:
        if len(contents) != 0 and contents[^1] != '\n':
          stream.writeLine("")
        stream.writeLine(toWrite)
      except:
        warn("Cannot write to ~/.bash_completion to turn on autocomplete.")
        dumpExOnDebug()
        return
      info("Added sourcing of autocomplete to ~/.bash_completion file")

elif hostOS == "macosx":
  proc makeCompletionAutoSource(dst: string) =
    let
      ac       = "~/.zshrc"
      acpath   = resolvePath(ac)
      srcLine  = "source " & dst
      contents = tryToLoadFile(acpath)
      lines    = contents.splitLines()
    var
      foundbci = false
      foundci  = false
      foundsrc = false

    for line in lines:
      # This is not even a little precise but should be ok
      let words = line.split(" ")
      if "bashcompinit" in words:
        foundbci = true
      elif "compinit" in words:
        foundci = true
      elif line == srcLine and foundci and foundbci:
        foundsrc = true

    if foundbci and foundci and foundsrc:
      return

    withFileStream(acpath, mode = fmAppend, strict = false):
      if stream == nil:
        warn("Cannot write to " & acpath & " to turn on autocomplete.")
        return
      if len(contents) != 0 and contents[^1] != '\n':
        stream.write("\n")

      if not foundbci:
        stream.writeLine("autoload bashcompinit")
        stream.writeLine("bashcompinit")

      if not foundci:
        stream.writeLine("autoload -Uz compinit")
        stream.writeLine("compinit")

      if not foundsrc:
        stream.writeLine(srcLine)

      info("Set up sourcing of basic autocomplete in ~/.zshrc")
      info("Script should be sourced automatically on your next login.")

else:
  proc makeCompletionAutoSource(dst: string) = discard

proc validateMetaData*(obj: ChalkObj): ValidateResult {.importc.}

proc autocompleteFileCheck*() =
  if isatty(0) == 0 or attrGet[bool]("install_completion_script") == false:
    return
  # compiling chalk itself
  if existsEnv("CHALK_BUILD"):
    return

  var dst = ""
  try:
    dst = resolvePath(autoCompleteLoc)
  except:
    # resolvePath can fail on ~ when uid doesnt have home dir
    return

  let alreadyExists = fileExists(dst)
  if alreadyExists:
    let
      subscan   = runChalkSubScan(@[dst], "extract")
      allChalks = subscan.getAllChalks()

    if len(allChalks) != 0 and allChalks[0].extract != nil:
      if (
        "HASH" in allChalks[0].extract and
        "CHALK_VERSION" in allChalks[0].extract and
        allChalks[0].validateMetaData() == vOk
      ):
        const chalkVersion = getChalkVersion()
        let
          boxedVersion   = allChalks[0].extract["CHALK_VERSION"]
          foundVersion   = unpack[string](boxedVersion)
          boxedHash      = allChalks[0].extract["HASH"]
          foundHash      = unpack[string](boxedHash)
          embedHash      = bashScript.sha256Hex()

        trace("Extracted semver string from existing autocomplete file: " & foundVersion)

        # compare if the autocomplete script actually changed
        # vs comparing chalk version
        if foundHash != embedHash:
          info("Updating autocomplete script to current version: " & chalkVersion)
        else:
          trace("Autocomplete script is up to date. Skipping.")
          return
    else:
      info("Autocomplete file exists but is missing chalkmark. Updating.")

  if not alreadyExists:
    try:
      createDir(resolvePath(dst.splitPath().head))
    except:
      warn("No permission to create auto-completion directory: " &
        dst.splitPath().head)
      return

  if not tryToWriteFile(dst, bashScript):
    warn("Could not write to auto-completion file: " & dst)
    return

  let selfChalkOpt = getSelfExtraction()
  if selfChalkOpt.isSome():
    let
      selfChalk = selfChalkOpt.get()
      autoCompleteChalk = newChalk(
        dst,
        fsRef         = dst,
        codec         = getPluginByName("source"),
        noAttestation = true,
      ).copyCollectedDataFrom(selfChalk)
    withSuspendChalkCollectionFor(autoCompleteChalk.getOptionalPluginNames()):
      initCollection()
      collectChalkTimeHostInfo()
      collectChalkTimeArtifactInfo(autoCompleteChalk, override = true)
    let chalkMark = autoCompleteChalk.getChalkMarkAsStr()
    autoCompleteChalk.callHandleWrite(some(chalkMark))

  info("Installed bash auto-completion file to: " & dst)
  if not alreadyExists:
    makeCompletionAutoSource(dst)

proc setupAutocomplete*() =
  try:
    autocompleteFileCheck()
  except:
    warn("could not check autocomplete file due to: " & getCurrentExceptionMsg())
    dumpExOnDebug()
