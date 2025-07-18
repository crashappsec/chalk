##
## Copyright (c) 2023-2025, Crash Override, Inc.
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

import std/[
  algorithm,
]
import "."/[
  chalkjson,
  run_management,
  types,
  utils/strings,
  utils/files,
]

# These things don't check for null pointers, because they should only
# get called when plugins declare stuff in the config file, so this
# should all be pre-checked.

proc callGetChalkTimeHostInfo*(plugin: Plugin): ChalkDict =
  if not plugin.enabled:
    return ChalkDict()

  let cb = plugin.getChalkTimeHostInfo

  # explicit callback check - otherwise it results in segfault
  if cb == nil:
    error("Plugin " & plugin.name & ": getChalkTimeHostInfo callback is missing")
    result = ChalkDict()
  else:
    result = cb(plugin)

proc callGetChalkTimeArtifactInfo*(plugin: Plugin, obj: ChalkObj):
         ChalkDict =
  if not plugin.enabled:
    return ChalkDict()

  let cb = plugin.getChalkTimeArtifactInfo

  # explicit callback check - otherwise it results in segfault
  if cb == nil:
    error("Plugin " & plugin.name & ": getChalkTimeArtifactInfo callback is missing")
    result = ChalkDict()
  else:
    result = cb(plugin, obj)

proc callGetRunTimeArtifactInfo*(plugin: Plugin, obj: ChalkObj, b: bool):
         ChalkDict =
  if not plugin.enabled:
    return ChalkDict()

  let cb = plugin.getRunTimeArtifactInfo

  # explicit callback check - otherwise it results in segfault
  if cb == nil:
    error("Plugin " & plugin.name & ": getRunTimeArtifactInfo callback is missing")
    result = ChalkDict()
  else:
    result = cb(plugin, obj, b)

proc callGetRunTimeHostInfo*(plugin: Plugin, objs: seq[ChalkObj]):
         ChalkDict =
  if not plugin.enabled:
    return ChalkDict()

  let cb = plugin.getRunTimeHostInfo

  # explicit callback check - otherwise it results in segfault
  if cb == nil:
    error("Plugin " & plugin.name & ": getRunTimeHostInfo callback is missing")
    result = ChalkDict()
  else:
    result = cb(plugin, objs)

proc callScan*(plugin: Plugin, s: string): Option[ChalkObj] =
  let cb = plugin.scan
  if cb != nil:
    return cb(plugin, s)
  return none(ChalkObj)

proc callSearch*(plugin: Plugin, s: string): seq[ChalkObj] =
  let cb = plugin.search
  if cb != nil:
    return cb(plugin, s)
  return @[]

proc callSearchEnvVar*(plugin: Plugin, k: string, v: string): seq[ChalkObj] =
  let cb = plugin.searchEnvVar
  if cb != nil:
    return cb(plugin, k, v)
  return @[]

proc callGetUnchalkedHash*(obj: ChalkObj): Option[string] =
  if obj.cachedUnchalkedHash != "":
    return some(obj.cachedUnchalkedHash)
  let
    plugin = obj.myCodec
    cb     = plugin.getUnchalkedHash
  result = cb(plugin, obj)
  if result.isSome():
    obj.cachedUnchalkedHash = result.get()

proc callGetPrechalkingHash*(obj: ChalkObj): Option[string] =
  if obj.cachedPrechalkingHash != "":
    return some(obj.cachedPrechalkingHash)
  let
    plugin = obj.myCodec
    cb     = plugin.getPrechalkingHash
  result = cb(plugin, obj)
  if result.isSome():
    obj.cachedEndingHash = result.get()

proc callGetEndingHash*(obj: ChalkObj): Option[string] =
  if obj.cachedEndingHash != "":
    return some(obj.cachedEndingHash)
  let
    plugin = obj.myCodec
    cb     = plugin.getEndingHash
  result = cb(plugin, obj)
  if result.isSome():
    obj.cachedEndingHash = result.get()

proc callGetChalkId*(obj: ChalkObj): string =
  let
    plugin = obj.myCodec
    cb     = plugin.getChalkId
  result = cb(plugin, obj)

proc callHandleWrite*(obj: ChalkObj, toWrite: Option[string]) =
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
    error(loc & ": Scan canceled: " & getCurrentExceptionMsg())
    dumpExOnDebug()

proc searchLocation(self: Plugin, loc: string): seq[ChalkObj] =
  try:
    return callSearch(self, loc)
  except:
    error(loc & ": Search canceled: " & getCurrentExceptionMsg())
    dumpExOnDebug()

proc searchEnvironmentVariable(self: Plugin, k: string, v: string): seq[ChalkObj] =
  try:
    return callSearchEnvVar(self, k, v)
  except:
    error(k & ": Search env var canceled: " & getCurrentExceptionMsg())
    dumpExOnDebug()

iterator scanArtifactLocationsWith*(state:  ArtifactIterationInfo,
                                    codecs: seq[Plugin],
                                    ): ChalkObj =
  # This will call scan() with a file stream, and you pass back a
  # Chalk object if chalk is there.

  let
    symLinkBehaviorConfig =
      if isChalkingOp():
        "symlink_behavior_chalking"
      else:
        "symlink_behavior_non_chalking"
    symLinkBehavior = attrGet[string](symLinkBehaviorConfig)

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
    fileLinks: PathBehavior
    skipLinks: bool

  case symLinkBehavior
  of "skip", "ignore":
    # yield links but then show warning that they are skipped
    fileLinks = PathBehavior.Yield
    skipLinks = true
  of "clobber", "follow":
    fileLinks = PathBehavior.Follow
    skipLinks = false
  else:
    fileLinks = PathBehavior.Yield
    skipLinks = false

  # note the outer loop is over file paths, not codecs (it used to be at some point)
  # to get efficient FS scanning. For example when scanning '/' there is some overhead
  # as getAllFileNames() need to walk the FS tree which means:
  # * a bunch of lstat calls in order to determine whether found paths are files/dirs/etc
  # * keep track of which dirs were already seen to handle circular loops
  # * open FD for each found path
  # As such its a lot more efficient to walk by all paths first and then
  # attempt to find chalk artifact for each path by checking all codecs as that:
  # * pays above overhead once
  # * reuses opened FDs between codecs hence less open()/close() overhead
  # Cnanging loop topology scanning ubuntu container '/' went from ~180sec to ~100sec
  for path in state.filePaths:
    trace(path & ": beginning scan")
    let p = path.resolvePath()
    for i in p.getAllFileNames(
      recurse     = state.recurse,
      fileLinks   = fileLinks,
      ignore      = state.fileExclusions,
      ignoreRegex = state.skips,
    ):
      if skipLinks and i.isSymlink():
        warn(i.name & ": skipping symbolic link. Customize behavior with config " & symLinkBehaviorConfig)
        continue

      # with symlinks same file can be referenced multiple times
      # and so we lookup any existing chalk and if present, ignore this i.name
      var alreadyScanned = false
      for chalk in getAllChalks() & getAllArtifacts():
        if chalk.fsRef == i.name:
          alreadyScanned = true
          break
      if alreadyScanned:
        trace(i.name & ": was already previously scanned. ignoring")
        continue

      for codec in codecs:
        var found = false
        trace(i.name & ": scanning file with " & codec.name)
        let opt = codec.scanLocation(i.name)
        if opt.isSome():
          let chalk = opt.get()
          yield chalk
          found = true
        for chalk in codec.searchLocation(i.name):
          yield chalk
          found = true
        if found:
          break

  if state.envVars:
    for k, v in envPairs():
      for codec in codecs:
        if codec.searchEnvVar == nil:
          continue
        var found = false
        trace(k & ": scanning env var with " & codec.name)
        for chalk in codec.searchEnvironmentVariable(k, v):
          yield chalk
          found = true
        if found:
          break

proc simpleHash(self: Plugin, chalk: ChalkObj): Option[string] =
  # The default if the stream can't be acquired.
  result = none(string)

  withFileStream(chalk.fsRef, mode = fmRead, strict = false):
    if stream != nil:
      result = some(stream.readAll().sha256Hex())

proc defUnchalkedHash(self: Plugin, obj: ChalkObj): Option[string] {.cdecl.} =
  ## This is called in computing the CHALK_ID. If the artifact already
  ## hash chalk marks they need to be removed.
  ##
  ## The default assumes that this was cached during scan, and if the
  ## hash isn't cached, it doesn't exist.
  if obj.cachedUnchalkedHash != "":
    return some(obj.cachedUnchalkedHash)
  return none(string)

proc defPrechalkingHash(self: Plugin, chalk: ChalkObj): Option[string] {.cdecl.} =
  ## This is called before chalking is done.
  if chalk.cachedPrechalkingHash != "":
    return some(chalk.cachedPrechalkingHash)
  return simpleHash(self, chalk)

proc defEndingHash(self: Plugin, chalk: ChalkObj): Option[string] {.cdecl.} =
  ## This is called after chalking is done.  We check the cache first.
  if chalk.cachedEndingHash != "":
    return some(chalk.cachedEndingHash)
  return simpleHash(self, chalk)

proc randChalkId(self: Plugin, chalk: ChalkObj): string {.cdecl.} =
  var
    b      = secureRand[array[32, char]]()
    preRes = newStringOfCap(32)

  for ch in b:
    preRes.add(ch)

  return preRes.idFormat()

proc defaultChalkId(self: Plugin, chalk: ChalkObj): string {.cdecl.} =
  let hashOpt = chalk.callGetUnchalkedHash()

  if hashOpt.isSome():
    return hashOpt.get().idFormat()

  info(chalk.name & ": In plugin '" & self.name &
       "', no hash for chalk ID; using a random value.")

  return self.randChalkId(chalk)

proc defaultRtArtInfo*(self: Plugin, chalk: ChalkObj, ins: bool):
                     ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_CURRENT_HASH", chalk.callGetEndingHash())

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
  if not chalk.fsRef.replaceFileContents(contents):
    chalk.opFailed = true

var codecs: seq[Plugin] = @[]

proc checkPlugin(plugin: Plugin, codec: bool): bool {.inline.} =
  let
    name    = plugin.name
    section = "plugin." & name

  if not sectionExists(section):
    error("No config provided for plugin " & name & ". Plugin ignored.")
  elif not attrGet[bool](section & ".enabled"):
      trace("Plugin " & name & " is disabled via config file.")
  elif name in installedPlugins:
    error("Double install of plugin named: " & name)
  elif attrGet[bool](section & ".codec") != codec:
    if codec:
      error("Codec expected, but the config file does not declare that it " &
        "is a codec.")
    else:
      error("Plugin expected, but the config file declares that it's a codec.")
  else:
    trace("Installed plugin: " & name)
    installedPlugins[name] = plugin
    return true

proc getAllPlugins*(): seq[Plugin] =
  var preResult: seq[(int, Plugin)] = @[]
  for name, plugin in installedPlugins:
    let tup = (attrGet[int]("plugin." & plugin.name & ".priority"), plugin)
    preResult.add(tup)

  preResult.sort()
  for (_, plugin) in preResult:
    result.add(plugin)

proc getPluginByName*(s: string): Plugin =
  return installedPlugins[s]

proc getPluginsByName*(s: seq[string]): seq[Plugin] =
  for i in s:
    result.add(getPluginByName(i))

proc getOptionalPluginNames*(c: ChalkObj): seq[string] =
  ## get all optional plugins
  ## optional plugin is neither a system plugin or the chalk codec plugin
  result = newSeq[string]()
  for p in getAllPlugins():
    if not p.isSystem and p != c.myCodec:
      result.add(p.name)

proc getOptionalPluginNames*(): seq[string] =
  result = newSeq[string]()
  for p in getAllPlugins():
    if not p.isSystem and not p.isCodec:
      result.add(p.name)

proc getAllCodecs*(): seq[Plugin] =
  once:
    for item in getAllPlugins():
      if item.isCodec:
        codecs.add(item)
  return codecs

proc getNativeCodecs*(): seq[Plugin] =
  for codec in getAllCodecs():
    if hostOS notin codec.nativeObjPlatforms:
      continue
    result.add(codec)

proc getFileCodecs*(): seq[Plugin] =
  let fileCodecs =
    if len(getOnlyCodecs()) > 0:
      getOnlyCodecs()
    else:
      getAllCodecs()
  for codec in fileCodecs:
    if codec.name == "docker":
      continue
    result.add(codec)

proc newPlugin*(
  name:           string,
  clearCallback:  PluginClearCb       = PluginClearCb(nil),
  ctHostCallback: ChalkTimeHostCb     = ChalkTimeHostCb(nil),
  ctArtCallback:  ChalkTimeArtifactCb = ChalkTimeArtifactCb(nil),
  rtArtCallback:  RunTimeArtifactCb   = RunTimeArtifactCb(nil),
  rtHostCallback: RunTimeHostCb       = RunTimeHostCb(nil),
  cache:          RootRef             = RootRef(nil),
  resourceTypes:  set[ResourceType]   = defResourceTypes,
  isSystem:       bool                = false,
): Plugin {.discardable, cdecl.} =
  result = Plugin(name:                     name,
                  clearState:               clearCallback,
                  getChalkTimeHostInfo:     ctHostCallback,
                  getChalkTimeArtifactInfo: ctArtCallback,
                  getRunTimeArtifactInfo:   rtArtCallback,
                  getRunTimeHostInfo:       rtHostCallback,
                  internalState:            cache,
                  resourceTypes:            resourceTypes,
                  enabled:                  true,
                  isSystem:                 isSystem)

  if not result.checkPlugin(codec = false):
    result = Plugin(nil)

proc newCodec*(
  name:               string,
  scan:               ScanCb              = ScanCb(nil),
  search:             SearchCb            = SearchCb(nil),
  searchEnvVar:       SearchEnvVarCb      = SearchEnvVarCb(nil),
  ctHostCallback:     ChalkTimeHostCb     = ChalkTimeHostCb(nil),
  ctArtCallback:      ChalkTimeArtifactCb = ChalkTimeArtifactCb(nil),
  rtArtCallback:      RunTimeArtifactCb   = RunTimeArtifactCb(defaultRtArtInfo),
  rtHostCallback:     RunTimeHostCb       = RunTimeHostCb(nil),
  getUnchalkedHash:   UnchalkedHashCb     = UnchalkedHashCb(defUnchalkedHash),
  getPrechalkingHash: PrechalkingHashCb   = PrechalkingHashCb(defPrechalkingHash),
  getEndingHash:      EndingHashCb        = EndingHashCb(defEndingHash),
  getChalkId:         ChalkIdCb           = ChalkIdCb(defaultChalkId),
  handleWrite:        HandleWriteCb       = HandleWriteCb(defaultCodecWrite),
  nativeObjPlatforms: seq[string]         =  @[],
  cache:              RootRef             = RootRef(nil),
  commentStart:       string              = "#",
  enabled:            bool                = true):
    Plugin {.discardable, cdecl.} =

  result = Plugin(name:                     name,
                  scan:                     scan,
                  search:                   search,
                  searchEnvVar:             searchEnvVar,
                  getChalkTimeHostInfo:     ctHostCallback,
                  getChalkTimeArtifactInfo: ctArtCallback,
                  getRunTimeArtifactInfo:   rtArtCallback,
                  getRunTimeHostInfo:       rtHostCallback,
                  getUnchalkedHash:         getUnchalkedHash,
                  getPrechalkingHash:       getPrechalkingHash,
                  getEndingHash:            getEndingHash,
                  getChalkId:               getChalkId,
                  handleWrite:              handleWrite,
                  nativeObjPlatforms:       nativeObjPlatforms,
                  internalState:            cache,
                  commentStart:             commentStart,
                  enabled:                  enabled,
                  isCodec:                  true)

  if not result.checkPlugin(codec = true):
    result = Plugin(nil)
