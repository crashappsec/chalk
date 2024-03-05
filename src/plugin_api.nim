##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This provides the base methods for plugins / codecs.
## Additionally, it provides utility functions to be used
## by plugins, as well as code for registering plugins.
##
## All of the data collection these plugins do is orchestrated in
## collect.nim

import std/[re, algorithm]
import "."/[config, chalkjson, util]

# These things don't check for null pointers, because they should only
# get called when plugins declare stuff in the config file, so this
# should all be pre-checked.

proc callGetChalkTimeHostInfo*(plugin: Plugin): ChalkDict =
  let cb = plugin.getChalkTimeHostInfo

  # explicit callback check - otherwise it results in segfault
  if cb == nil:
    error("Plugin " & plugin.name & ": getChalkTimeHostInfo callback is missing")
    result = ChalkDict()
  else:
    result = cb(plugin)

proc callGetChalkTimeArtifactInfo*(plugin: Plugin, obj: ChalkObj):
         ChalkDict =
  let cb = plugin.getChalkTimeArtifactInfo

  # explicit callback check - otherwise it results in segfault
  if cb == nil:
    error("Plugin " & plugin.name & ": getChalkTimeArtifactInfo callback is missing")
    result = ChalkDict()
  else:
    result = cb(plugin, obj)

proc callGetRunTimeArtifactInfo*(plugin: Plugin, obj: ChalkObj, b: bool):
         ChalkDict =
  let cb = plugin.getRunTimeArtifactInfo

  # explicit callback check - otherwise it results in segfault
  if cb == nil:
    error("Plugin " & plugin.name & ": getRunTimeArtifactInfo callback is missing")
    result = ChalkDict()
  else:
    result = cb(plugin, obj, b)

proc callGetRunTimeHostInfo*(plugin: Plugin, objs: seq[ChalkObj]):
         ChalkDict =
  let cb = plugin.getRunTimeHostInfo

  # explicit callback check - otherwise it results in segfault
  if cb == nil:
    error("Plugin " & plugin.name & ": getRunTimeHostInfo callback is missing")
    result = ChalkDict()
  else:
    result = cb(plugin, objs)

template callScan*(plugin: Plugin, s: string):
         Option[ChalkObj] =
  let cb = plugin.scan

  cb(plugin, s)

template callGetUnchalkedHash*(obj: ChalkObj): Option[string] =
  let
    plugin = obj.myCodec
    cb     = plugin.getUnchalkedHash

  cb(plugin, obj)

template callGetEndingHash*(obj: ChalkObj): Option[string] =
  let
    plugin = obj.myCodec
    cb     = plugin.getEndingHash

  cb(plugin, obj)

template callGetChalkId*(obj: ChalkObj): string =
  let
    plugin = obj.myCodec
    cb     = plugin.getChalkId

  cb(plugin, obj)

template callHandleWrite*(obj: ChalkObj, toWrite: Option[string]) =
  let
    plugin = obj.myCodec
    cb     = plugin.handleWrite

  cb(plugin, obj, toWrite)

proc findFirstValidChalkMark*(s:            string,
                              artifactPath: string,
                              quiet                = false):
                                (int, int, ChalkDict) =
  # We're generally going to use this when looking for existing chalk
  # marks in text files.
  #
  # The pattern will generally be, look once when scanning, and if we
  # do find it, and then are potentially replacing it, we will rescan
  # instead of trusting the cached location, just to avoid any risk of
  # the underlying file having changed out from underneath us.  Still,
  # generally the file won't have changed, so if there's any logging
  # that happens, it should only happen on the first scan, rather than
  # being duplicated.
  var
    asStream        = newStringStream(s)
    curIx           = -1

  while true:
    # The previous loop will have curIx pointing to the start of a
    # mark.  If we don't advance this by one somewhere, we'd keep
    # getting the same mark back (forever).
    curIx = s.find(magicUTF8, curIx + 1)

    if curIx == -1:
      return (-1, -1, nil)
    asStream.setPosition(curIx)
    if not asStream.findJsonStart():
      if quiet:
        continue
      error(artifactPath & ": At byte " & $(curIx) &
            ", chalk mark is present, but was not embedded in valid " &
            "chalk JSON. Searching for another mark.")
    try:
      let
        # The stream pointer is backed up from curIx, but we don't
        # want to change curIx in case we need to search for the next
        # mark.  If this mark *is* valid, then we actually will want
        # to return this position, which represents the true start of
        # the mark, being the start of the JSON.  That's what we're
        # expected to be returning, not the location of the magic value.
        curPos   = asStream.getPosition()
        contents = asStream.extractOneChalkJson(artifactPath)
      let endPos = asStream.getPosition()
      asStream.close()
      return (curPos, endPos, contents)
    except:
      if quiet:
        continue
      error(artifactPath & ": Invalid JSON: " & getCurrentExceptionMsg())
      dumpExOnDebug()

proc findFirstValidChalkMark*(s:            Stream,
                              artifactPath: string,
                              quiet                = false):
                                (int, int, ChalkDict) =
  s.setPosition(0)
  return s.readAll().findFirstValidChalkMark(artifactPath, quiet)

const basePrefixLen = 2 # size of the prefix w/o the comment char(s)

proc getUnmarkedScriptContent*(current: string,
                               chalk:   ChalkObj,
                               comment: string,
                               quiet            = false): (string, ChalkDict) =
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
  ## Note that to avoid re-writing unchanged files, this function's
  ## string return value is set to "" if the unmarked output is the
  ## same as the input.  In such a case, the ChalkDict will also be
  ## nil.
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
    return ("", nil)

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

proc getNewScriptContents*(fileContents: string,
                           chalk:        ChalkObj,
                           markContents: string): string =
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

    if len(fileContents) != 0 and fileContents[^1] == '\n':
      return fileContents & chalk.commentPrefix & " " & markContents & "\n"
    else:
      return fileContents & "\n" & chalk.commentPrefix & " " & markContents

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

proc scriptLoadMark*(codec:  Plugin, stream: Stream,
                     path: string, comment: string):
                   Option[ChalkObj] =
  ## We expect this helper function will work for MOST
  ## codecs for scripting languages and similar, after checking
  ## conditions to figure out if you want to handle the thing.  But
  ## you don't have to use it, if it's not appropriate!

  stream.setPosition(0)

  let
    contents       = stream.readAll()
    chalk          = newChalk(name         = path,
                              fsRef        = path,
                              codec        = codec,
                              resourceType = {ResourceFile})
    (toHash, dict) = contents.getUnmarkedScriptContent(chalk, comment)

  result = some(chalk)

  if toHash == "" and dict == nil:
    chalk.cachedPreHash = contents.sha256Hex()
  else:
    chalk.cachedPreHash = toHash.sha256Hex()
  if dict != nil and len(dict) != 1:
    # When len(dict) == 1, that's the 'placeholder chalk mark', which
    # we consider to be not a chalk mark for script files.
    chalk.marked  = true
    chalk.extract = dict

proc scriptHandleWrite*(plugin:  Plugin,
                        chalk:   ChalkObj,
                        encoded: Option[string]) {.cdecl.} =
  ## Same as above, default option for a handleWrite implementation
  ## that should work for most scripting languages.
  var contents: string

  withFileStream(chalk.fsRef, mode = fmRead, strict = true):
    contents = stream.readAll()

  if encoded.isNone():
    if not chalk.marked:  # Unmarked, so nothing to do.
      return
    let (toWrite, _) = contents.getUnmarkedScriptContent(chalk,
                                                chalk.commentPrefix, true)
    if not chalk.replaceFileContents(toWrite):
      chalk.opFailed = true
      return

    chalk.cachedHash = chalk.cachedPreHash
  else:
    let toWrite = contents.getNewScriptContents(chalk, encoded.get())
    if not chalk.replaceFileContents(toWrite):
      chalk.opFailed = true
    else:
      chalk.cachedHash = toWrite.sha256Hex()

proc loadChalkFromFStream*(codec:  Plugin,
                           stream: FileStream,
                           loc:    string): ChalkObj =
  ## A helper function for codecs that use file streams to load
  ## an existing chalk mark.  The stream must be positioned over
  ## the start of the Chalk magic before you call this function.

  result = newChalk(name         = loc,
                    fsRef        = loc,
                    codec        = codec,
                    resourceType = {ResourceFile})

  trace(result.name & ": chalk mark magic @ " & $(stream.getPosition()))

  if not stream.findJsonStart():
    error(loc & ": Invalid JSON: found magic but no JSON start")
    return

  try:
    result.startOffset   = stream.getPosition()
    result.extract       = stream.extractOneChalkJson(result.name)
    result.endOffset     = stream.getPosition()

  except:
    error(loc & ": Invalid JSON: " & getCurrentExceptionMsg())
    dumpExOnDebug()

proc scanLocation(self: Plugin, loc: string): Option[ChalkObj] =
  try:
    result = callScan(self, loc)
  except:
    error(loc & "Scan canceled: " & getCurrentExceptionMsg())
    dumpExOnDebug()

proc mustIgnore(path: string, regexes: seq[Regex]): bool {.inline.} =
  result = false

  for i, item in regexes:
    if path.match(item):
      once:
        trace(path & ": ignored due to matching ignore pattern: " &
          chalkConfig.getIgnorePatterns()[i])
        trace("We will NOT report additional path skips.")
      return true

proc scanArtifactLocations*(self: Plugin, state: ArtifactIterationInfo):
                        seq[ChalkObj] =
  # This will call scan() with a file stream, and you pass back a
  # Chalk object if chalk is there.
  result = @[]

  var
    # The first item we pass to getAllFileNames(). If we're following file
    # links then we're going to set it to false.
    #
    # But if we're skipping all links, we're still going to ask
    # getAllFileNames() to return those links so that we can warn on
    # them.
    #
    # The second item is the ACTUAL desirec behavior, which we check when
    # we determine a link was yielded.
    yieldLinks   = true
    skipLinks    = false
    followFLinks = false

  if isChalkingOp():
    let symLinkBehavior = chalkConfig.getSymlinkBehavior()
    if symLinkBehavior == "skip":
      skipLinks = true
    elif symLinkBehavior == "clobber":
      followFLinks = true
      yieldLinks   = false

  for path in state.filePaths:
    trace("Codec " & self.name & ": beginning scan of " & path)

    let p = path.resolvePath()
    for item in p.getAllFileNames(state.recurse, yieldLinks, followFLinks):
      if item in state.fileExclusions or item.mustIgnore(state.skips):
        continue
      if skipLinks:
        var info: FileInfo
        try:
          info = getFileInfo(path, followSymlink = false)
        except:
          continue
        if info.kind == pcLinkToFile:
          warn("Skipping symbolic link: " & path & """\n
Use --clobber to follow and clobber the linked-to file when inserting,
or --copy to copy the file and replace the symlink.""")
          continue

      trace(item & ": scanning file")
      let opt = self.scanLocation(item)
      if opt.isSome():
        let chalk = opt.get()
        result.add(chalk)

proc simpleHash(self: Plugin, chalk: ChalkObj): Option[string] =
  # The default if the stream can't be acquired.
  result = none(string)

  withFileStream(chalk.fsRef, mode = fmRead, strict = false):
    if stream != nil:
      result = some(stream.readAll().sha256Hex())

proc defUnchalkedHash*(self: Plugin, obj: ChalkObj): Option[string] {.cdecl.} =
  ## This is called in computing the CHALK_ID. If the artifact already
  ## hash chalk marks they need to be removed.
  ##
  ## The default assumes that this was cached during scan, and if the
  ## hash isn't cached, it doesn't exist.

  if obj.cachedPreHash != "": return some(obj.cachedPreHash)
  return none(string)

proc defEndingHash*(self: Plugin, chalk: ChalkObj): Option[string] {.cdecl.} =
  ## This is called after chalking is done.  We check the cache first.
  if chalk.cachedHash != "": return some(chalk.cachedHash)
  return simpleHash(self, chalk)

proc randChalkId*(self: Plugin, chalk: ChalkObj): string {.cdecl.} =
  var
    b      = secureRand[array[32, char]]()
    preRes = newStringOfCap(32)

  for ch in b:
    preRes.add(ch)

  return preRes.idFormat()

proc defaultChalkId*(self: Plugin, chalk: ChalkObj): string {.cdecl.} =
  let hashOpt = chalk.callGetUnchalkedHash()

  if not hashOpt.isNone():
    return hashOpt.get().idFormat()

  info(chalk.name & ": In plugin '" & self.name &
       "', no hash for chalk ID; using a random value.")

  return self.randChalkId(chalk)

proc defaultRtArtInfo*(self: Plugin, chalk: ChalkObj, ins: bool):
                     ChalkDict {.cdecl.} =
  result = ChalkDict()

  let postHashOpt = chalk.callGetEndingHash()

  if postHashOpt.isSome():
    result["_CURRENT_HASH"] = pack(postHashOpt.get())

proc defaultCodecWrite*(s:     Plugin,
                        chalk: ChalkObj,
                        enc:   Option[string]) {.cdecl.} =
  var
    pre:  string
    post: string

  withFileStream(chalk.fsRef, mode = fmRead, strict = true):
    pre = stream.readStr(chalk.startOffset)

    if chalk.endOffset > chalk.startOffset:
      stream.setPosition(chalk.endOffset)
      post = stream.readAll()

  let contents = pre & enc.getOrElse("") & post
  if not chalk.replaceFileContents(contents):
    chalk.opFailed = true

var
  installedPlugins: Table[string, Plugin]
  codecs:           seq[Plugin] = @[]

template isCodec*(plugin: Plugin): bool = plugin.configInfo.codec

proc checkPlugin(plugin: Plugin, codec: bool): bool {.inline.} =
  let
    name  = plugin.name
    maybe = getPluginConfig(name)
    spec  = maybe.getOrElse(PluginSpec(nil))

  if maybe.isNone():
    error("No config provided for plugin " & name & ". Plugin ignored.")
  elif not maybe.get().getEnabled():
      trace("Plugin " & name & " is disabled via config file.")
  elif name in installedPlugins:
    error("Double install of plugin named: " & name)
  elif spec.codec != codec:
    if codec:
      error("Codec expected, but the config file does not declare that it " &
        "is a codec.")
    else:
      error("Plugin expected, but the config file declares that it's a codec.")
  else:
    trace("Installed plugin: " & name)
    plugin.configInfo      = spec
    installedPlugins[name] = plugin
    return true

proc getAllPlugins*(): seq[Plugin] =
  var preResult: seq[(int, Plugin)] = @[]
  for name, plugin in installedPlugins:
    preResult.add((plugin.configInfo.getPriority(), plugin))

  preResult.sort()
  for (_, plugin) in preResult:
    result.add(plugin)

template getPluginByName*(s: string): Plugin = installedPlugins[s]

proc getAllCodecs*(): seq[Plugin] =
  once:
    for item in getAllPlugins():
      if item.isCodec():
        codecs.add(item)

  return codecs

proc newPlugin*(
  name:           string,
  ctHostCallback: ChalkTimeHostCb     = ChalkTimeHostCb(nil),
  ctArtCallback:  ChalkTimeArtifactCb = ChalkTimeArtifactCb(nil),
  rtArtCallback:  RunTimeArtifactCb   = RunTimeArtifactCb(nil),
  rtHostCallback: RunTimeHostCb       = RunTimeHostCb(nil),
  cache:          RootRef             = RootRef(nil)):
    Plugin {.discardable, cdecl.} =
  result = Plugin(name:                     name,
                  getChalkTimeHostInfo:     ctHostCallback,
                  getChalkTimeArtifactInfo: ctArtCallback,
                  getRunTimeArtifactInfo:   rtArtCallback,
                  getRunTimeHostInfo:       rtHostCallback,
                  internalState:            cache)

  if not result.checkPlugin(codec = false):
    result = Plugin(nil)

proc newCodec*(
  name:               string,
  scan:               ScanCb              = ScanCb(nil),
  ctHostCallback:     ChalkTimeHostCb     = ChalkTimeHostCb(nil),
  ctArtCallback:      ChalkTimeArtifactCb = ChalkTimeArtifactCb(nil),
  rtArtCallback:      RunTimeArtifactCb   = RuntimeArtifactCb(defaultRtArtInfo),
  rtHostCallback:     RunTimeHostCb       = RunTimeHostcb(nil),
  getUnchalkedHash:   UnchalkedHashCb     = UnchalkedHashCb(defUnchalkedHash),
  getEndingHash:      EndingHashCb        = EndingHashCb(defEndingHash),
  getChalkId:         ChalkIdCb           = ChalkIdCb(defaultChalkId),
  handleWrite:        HandleWriteCb       = HandleWritecb(defaultCodecWrite),
  nativeObjPlatforms: seq[string]         =  @[],
  cache:              RootRef             = RootRef(nil),
  commentStart:       string              = "#"):
    Plugin {.discardable, cdecl.} =

  result = Plugin(name:                     name,
                  scan:                     scan,
                  getChalkTimeHostInfo:     ctHostCallback,
                  getChalkTimeArtifactInfo: ctArtCallback,
                  getRunTimeArtifactInfo:   rtArtCallback,
                  getRunTimeHostInfo:       rtHostCallback,
                  getUnchalkedHash:         getUnchalkedHash,
                  getEndingHash:            getEndingHash,
                  getChalkId:               getChalkId,
                  handleWrite:              handleWrite,
                  nativeObjPlatforms:       nativeObjPlatforms,
                  internalState:            cache,
                  commentStart:             commentStart)

  if not result.checkPlugin(codec = true):
    result = Plugin(nil)
