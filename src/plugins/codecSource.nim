##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This codec is intended for handling interpreted languages that ship
## source code, including shell scripts. It considers the shebang line
## if any, and the file extension.

from std/unicode import validateUtf8
import ".."/[config, plugin_api, util]

template seemsToBeUtf8(stream: FileStream): bool =
  try:
    let s = stream.peekStr(256)
    # The below call returns the position of the first bad byte, or -1
    # if it *is* valid.
    if s.validateUtf8() != -1:
      false
    else:
      true

  except:
    false

proc extractSheblanguage(stream: FileStream, path: string): string =
  try:
    let
      line      = stream.readLine()[2 .. ^1].strip()
      args      = line.split(" ") # Could end up w/ empty items but OK
      pathParts = args[0].splitPath()

    if pathParts.tail != "env":
      return pathParts.tail

    for item in args[1 .. ^1]:
      if item == "" or item.startswith("-"):
        continue

      let
        secondArgParts = item.splitPath()

      result = secondArgParts.tail

      var
        endIx = len(result) - 1

      while endIx != 0:
        if result[endIx].isDigit or result[endIx] == '.':
          endIx -= 1
          continue
        else:
          break

      if endIx != 0:
        result = result[0 .. endIx]


    # If they env nothing, we'll return the empty string, so no worries
  except:
    warn(path & ": No newline found in shebang file; skipping mark.")

proc sourceScan*(self: Plugin, path: string): Option[ChalkObj] {.cdecl.} =
  let
    isExe   = path.isExecutable()
  var
    hasBang = false

  if not isExe and isChalkingOp() and
     chalkConfig.get[:bool]("source_marks.only_mark_when_execute_set"):
    return none(ChalkObj)

  var
    parts = path.splitFile()
    ext   = parts.ext
    lang:          string
    commentPrefix: string

  if ext != "":
    ext  = ext[1 .. ^1] # No need for the period.
    if ext in chalkConfig.get[:seq[string]]("source_marks.text_only_extensions"):
      return none(ChalkObj)

    if ext in chalkConfig.srcConfig.extensionsToLanguagesMap:
      # We might revise this if there's a shebang line; it takes precidence.
      lang = chalkConfig.srcConfig.extensionsToLanguagesMap[ext]
      trace(path & ": By file type, language is: " & lang)

  withFileStream(path, mode = fmRead, strict = false):
    if stream == nil:
      return none(ChalkObj)

    try:
      let bytes = stream.peekStr(2)

      if bytes != "#!":
        if isChalkingOp() and chalkConfig.get[:bool]("source_marks.only_mark_shebangs"):
          return none(ChalkObj)
        elif not stream.seemsToBeUtf8():
          return none(ChalkObj)
      else:
        lang    = stream.extractSheblanguage(path)
        trace(path & ": After shebang is processed, language is: " & lang)
        hasBang = if lang == "": false else: true
    except:
      warn(path & ": source codec could not read from open file.")

    # While we already checked this above, if the shebang was there,
    # but was invalid, we'll behave as if it wasn't there at all.
    if not hasBang and isChalkingOp() and
       chalkConfig.get[:bool]("source_marks.only_mark_shebangs"):
      return none(ChalkObj)

    if lang == "":
      # Assume shell script.
      lang = "sh"

    # At this point, *if* there's a custom_logic callback, we need to
    # call it, otherwise we are done.

    let opt = chalkConfig.getOpt[:CallbackObj]("source_marks.custom_logic")

    if opt.isSome():
      let
        args    = @[pack(path), pack(lang), pack(ext), pack(hasBang), pack(isExe)]
        proceed = unpack[bool](runCallback(opt.get(), args).get())

      if not proceed:
        return none(ChalkObj)

    if lang in chalkConfig.srcConfig.languageToCommentMap:
      commentPrefix = chalkConfig.srcConfig.languageToCommentMap[lang]
    else:
      commentPrefix = "#"

    result = self.scriptLoadMark(stream, path, commentPrefix)

    if result.isSome():
      let chalk = result.get()
      chalk.detectedLang  = lang
      chalk.commentPrefix = commentPrefix


proc sourceGetChalkTimeArtifactInfo*(self: Plugin, chalk: ChalkObj):
                                   ChalkDict {.cdecl.} =
  result = ChalkDict()

  result.setIfNeeded("ARTIFACT_TYPE", chalk.detectedLang)


proc sourceGetRunTimeArtifactInfo*(self:  Plugin, chalk: ChalkObj, ins: bool):
                              ChalkDict {.cdecl.} =
  result = ChalkDict()

  result.setIfNeeded("_OP_ARTIFACT_TYPE", chalk.detectedLang)

proc loadCodecSource*() =
  newCodec("source",
         scan          = ScanCb(sourceScan),
         ctArtCallback = ChalkTimeArtifactCb(sourceGetChalkTimeArtifactInfo),
         rtArtCallback = RunTimeArtifactCb(sourceGetRunTimeArtifactInfo),
         handleWrite   = HandleWriteCb(scriptHandleWrite))
