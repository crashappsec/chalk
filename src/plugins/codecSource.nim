##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This codec is intended for handling interpreted languages that ship
## source code, including shell scripts. It considers the shebang line
## if any, and the file extension.

import ".."/[
  config,
  plugin_api,
  run_management,
  types,
  utils/files,
]

type
  SourceCache = ref object of RootRef
    ext*:           string
    hasShebang*:    bool
    commentPrefix*: string
    detectedLang*:  string

const basePrefixLen = 2 # size of the prefix w/o the comment char(s)

proc extractShebangLanguage(stream: FileStream, path: string): string =
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

proc detectCache(path: string): SourceCache =
  let
    parts   = path.splitFile()
    isExe   = path.isExecutable()
  var
    ext     = parts.ext
    hasBang = false
    lang    = ""

  if ext != "":
    ext = ext[1 .. ^1] # No need for the period.
    if ext in attrGet[seq[string]]("source_marks.text_only_extensions"):
      return SourceCache(nil)

    let exts = attrGet[TableRef[string, string]]("source_marks.extensions_to_languages_map")
    if ext in exts:
      # We might revise this if there's a shebang line; it takes precidence.
      lang = exts[ext]
      trace(path & ": By file type, language is: " & lang)

  withFileStream(path, mode = fmRead, strict = false):
    if stream == nil:
      return SourceCache(nil)

    try:
      let bytes = stream.peekStr(2)

      if bytes != "#!":
        if not stream.seemsToBeUtf8():
          return SourceCache(nil)
      else:
        lang    = stream.extractShebangLanguage(path)
        hasBang = lang != ""
        trace(path & ": After shebang is processed, language is: " & lang)
    except:
      warn(path & ": source codec could not read from open file due to: " & getCurrentExceptionMsg())

  if lang == "":
    # Assume shell script.
    lang = "sh"

  let
    langs = attrGet[TableRef[string, string]]("source_marks.language_to_comment_map")
    comment = langs.getOrDefault(lang, "#")

  return SourceCache(
    ext:           ext,
    hasShebang:    hasBang,
    detectedLang:  lang,
    commentPrefix: comment,
  )

proc getUnmarkedScriptContent(current: string,
                              chalk:   ChalkObj,
                              comment: string,
                              quiet  = false,
                              ): (string, ChalkDict) =
  ## This function is intended to be used from plugins for artifacts
  ## where we have text files that are marked by adding one-line
  ## comments.
  ##
  ## Specifically, this function gets used in two scenarios:
  ##
  ## a) When we first scan the file.  In that scenario, we need the
  ## hash of the as-unmarked artifact and the extracted info, if any.
  ##
  ## b) When we remove a chalk mark, and want to write out the new
  ## content.
  ##
  ## To support those use cases, we return the contents of the file
  ## (it can then be either hashed or written), along with the dict
  ## extracted from Json, which the delete operation will just be
  ## ignoring.
  ##
  ## Generally, we expect this to get called 2x on a delete operation.
  ## We *could* cache contents, or a location in the file stream, but
  ## there are some cases where we might want to NOT cache and might
  ## possibly have underlying file changes (specifically, ZIP files
  ## and any other nested content will have their objects stick around
  ## until the outmost object is done processing).
  ##
  ## The protocol here for removing chalk marks that aren't on a
  ## comment boundary exactly as we would have added them is that we
  ## replace the mark's JSON with: { "MAGIC" : "dadfedabbadabbed" }
  ##
  ## We call this the "chalk placeholder".
  ##
  ## If the user hand-added it before we replaced the mark, we might not
  ## get the spacing quite the same as what the user had before hand,
  ## because we make no move to perserve that.
  ##
  ## To ensure consistency of the hashes we use to generate CHALK IDs,
  ## when using the placeholder, the hash we use for the purposes of
  ## chalking should be based on the placeholder with spacing as above,
  ## instead of the user's spacing.  That means, the hash we use as the
  ## 'pre-chalk' hash might be different than the on-file-system hash,
  ## were you to run sha256 on the as-is-file.
  ##
  ## Seems like a decent enough trade-off, and we have already made a
  ## similar one in ZIP files.

  var (cs, r, extract) = current.findFirstValidChalkMark(chalk.fsRef, quiet)

  if cs == -1:
    # There was no mark to find, so the input is the output, which we
    # indicate with "" to help prevent unnecessary I/O.
    return (current, nil)

    # If we are on a comment line by ourselves, in the format that we
    # would have written, then we will delete the entire line.
    # Otherwise, we replace the mark with the constant `emptyMark`.
    #
    # For us to delete the comment line, we require the following
    # conditions to be true:
    #
    # 1. Before the mark, we must see EXACTLY a newline, the comment
    #    sequence (usually just #) and then a single space.
    #
    # 2. After the mark ends, we must see EITHER a newline or EOF.
    #
    # In any other case, we treat the mark location as above where we
    # insert `emptyMark` instead of removing the whole line.
    #
    # We do it this way because, if we don't see `emptyMark` in an
    # unmarked file, this is the way we will add the mark, full stop.
    # If there's a marked file with extra spaces on the comment line,
    # either it was tampered with after marking (which the unchalked
    # hash would then be able to determine), *or* the user wanted the
    # comment line to look the way it does, and indicated such by
    # adding `emptyMark`.
    #
    # Below, we call the string that is either emptyMark or ""
    # 'remnant' because I can't come up with a better name.
  let
    ourEnding    = "\n" & comment & " "
    preMark      = current[0 ..< cs]
    addEmptyMark = if not preMark.endsWith(ourEnding):            true
                   elif r != len(current) and current[r] != '\n': true
                   else:                                         false
    remnant      = if addEmptyMark: emptyMark else: ""

  # If we're not adding empty mark, we need to excise the prefix,
  # which includes the newline, the comment marker and a space.
  if not addEmptyMark:
    cs -= (basePrefixLen + len(comment))

  # If r is positioned at the end of the string we don't want to get
  # an array indexing error.
  if r == len(current):
    return (current[0 ..< cs] & remnant, extract)
  else:
    return (current[0 ..< cs] & remnant & current[r .. ^1], extract)

proc getMarkedScriptContents(fileContents: string,
                             chalk:        ChalkObj,
                             markContents: string,
                             ): string =
  ## This helper function can be used for script plugins to calculate
  ## their new output.  It assumes you've either cached the input
  ## (which isn't a great idea if chalking large zip files or other
  ## artifacts that lead to recursive chalking) or, more likely,
  ## re-read the contents when it came time to write.
  ##
  ## We look again for a valid chalk mark (if we saved the state we
  ## could jump straight there, of coure).  If there's a mark found,
  ## we replace it.
  ##
  ## If there's no mark found, we shove it at the end of the output,
  ## with our comment prelude added beforehand.
  var (cs, r, _) = fileContents.findFirstValidChalkMark(chalk.fsRef,
                                                             true)

  if cs == -1:
    # If the file had a trailing newline, we preserve it, adding a new
    # newline at the end, to indicate that there was a newline before
    # the mark when the file was unmarked.
    #
    # When the file ended w/o a newline, we need to add a newline
    # before the mark (the comment should start a new line!).
    # But in that case, we *don't* add the newline to the end, indicating
    # that there wasn't one there before.

    let cache = SourceCache(chalk.cache)
    if len(fileContents) != 0 and fileContents[^1] == '\n':
      return fileContents & cache.commentPrefix & " " & markContents & "\n"
    else:
      return fileContents & "\n" & cache.commentPrefix & " " & markContents

  # At this point, we don't care about the newline situation; we are
  # just going to replace an *existing* chalk mark (which may be the
  # placeholder mark referenced above).
  #
  # The only 'gotcha' is that r *might* be pointing at EOF and not
  # safe to read.
  if r == len(fileContents):
    return fileContents[0 ..< cs] & markContents
  else:
    return fileContents[0 ..< cs] & markContents & fileContents[r .. ^1]

proc scriptLoadMark(codec:   Plugin,
                    path:    string,
                    comment: string,
                    ): Option[ChalkObj] =
  ## We expect this helper function will work for MOST
  ## codecs for scripting languages and similar, after checking
  ## conditions to figure out if you want to handle the thing.  But
  ## you don't have to use it, if it's not appropriate!

  withFileStream(path, mode = fmRead, strict = false):
    let
      contents       = stream.readAll()
      chalk          = newChalk(name         = path,
                                fsRef        = path,
                                codec        = codec,
                                resourceType = {ResourceFile})
      (toHash, dict) = contents.getUnmarkedScriptContent(chalk, comment)

    result = some(chalk)

    chalk.cachedUnchalkedHash = toHash.sha256Hex()
    if dict != nil and len(dict) > 0:
      # When len(dict) == 1, that's the 'placeholder chalk mark', which
      # we consider to be not a chalk mark for script files.
      chalk.marked  = true
      chalk.extract = dict

proc initCache(self: ChalkObj): SourceCache {.discardable.} =
  if self.cache == nil:
    result = self.fsRef.detectCache()
    if result == nil:
      raise newException(ValueError, "Could not determine script file params for soruce codec")
    self.cache = RootRef(result)
  else:
    result = SourceCache(self.cache)

proc scriptWriteMark(plugin:  Plugin,
                     chalk:   ChalkObj,
                     encoded: Option[string]) {.cdecl.} =
  let cache = chalk.initCache()
  var contents: string

  withFileStream(chalk.fsRef, mode = fmRead, strict = true):
    contents = stream.readAll()

  if encoded.isNone():
    let (toWrite, existingMark) = contents.getUnmarkedScriptContent(
      chalk,
      cache.commentPrefix,
      quiet = true,
    )
    # only delete chalk-mark if mark already exists
    if existingMark != nil:
      if not chalk.fsRef.replaceFileContents(toWrite):
        chalk.opFailed = true
        return
    chalk.cachedEndingHash = toWrite.sha256Hex()
  else:
    let toWrite = contents.getMarkedScriptContents(chalk, encoded.get())
    if not chalk.fsRef.replaceFileContents(toWrite):
      chalk.opFailed = true
    else:
      chalk.cachedEndingHash = toWrite.sha256Hex()

proc sourceScan(self: Plugin, path: string): Option[ChalkObj] {.cdecl.} =
  let isExe = path.isExecutable()
  if not isExe and isChalkingOp() and
     attrGet[bool]("source_marks.only_mark_when_execute_set"):
    return none(ChalkObj)

  let cache = path.detectCache()
  if cache == nil:
    return none(ChalkObj)

  if not cache.hasShebang and isChalkingOp() and attrGet[bool]("source_marks.only_mark_shebangs"):
    return none(ChalkObj)

  # At this point, *if* there's a custom_logic callback, we need to
  # call it, otherwise we are done.
  let opt = attrGetOpt[CallbackObj]("source_marks.custom_logic")
  if opt.isSome():
    let
      args    = @[
        pack(path),
        pack(cache.detectedLang),
        pack(cache.ext),
        pack(cache.hasShebang),
        pack(isExe),
      ]
      proceed = unpack[bool](runCallback(opt.get(), args).get())
    if not proceed:
      return none(ChalkObj)

  result = self.scriptLoadMark(path, cache.commentPrefix)
  if result.isSome():
    let chalk = result.get()
    chalk.cache = RootRef(cache)

proc getUnchalkedHash(self: Plugin, chalk: ChalkObj): Option[string] {.cdecl.} =
  withFileStream(chalk.fsRef, mode = fmRead, strict = true):
    let
      cache = chalk.initCache()
      (toHash, _) = stream.readAll().getUnmarkedScriptContent(chalk, cache.commentPrefix)
    return some(toHash.sha256Hex())

proc sourceGetChalkTimeArtifactInfo(self: Plugin,
                                    chalk: ChalkObj,
                                    ): ChalkDict {.cdecl.} =
  let cache = chalk.initCache()
  result = ChalkDict()
  result.setIfNeeded("ARTIFACT_TYPE", cache.detectedLang)

proc sourceGetRunTimeArtifactInfo(self:  Plugin,
                                   chalk: ChalkObj,
                                   ins: bool,
                                   ): ChalkDict {.cdecl.} =
  let cache = chalk.initCache()
  result = ChalkDict()
  result.setIfNeeded("_OP_ARTIFACT_TYPE", cache.detectedLang)

proc loadCodecSource*() =
  newCodec("source",
           scan             = ScanCb(sourceScan),
           ctArtCallback    = ChalkTimeArtifactCb(sourceGetChalkTimeArtifactInfo),
           rtArtCallback    = RunTimeArtifactCb(sourceGetRunTimeArtifactInfo),
           handleWrite      = HandleWriteCb(scriptWriteMark),
           getUnchalkedHash = UnchalkedHashCb(getUnchalkedHash))
