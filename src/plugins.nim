## This is the focal point for most of the metadata gathering. While
## it's called from several commands, once the context comes to a
## single artifact, a lot of the work runs through here.
##
## This file itself provides base types for Plugin and Codec (a type
## of Plugin), and functions that manage dispatching to them, etc.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import os, tables, strformat, strutils, algorithm, streams, options, glob
import con4m, nimutils, types, config, io/[fromjson, json]

const
  fmtTraceScanFile  = "{item}: scanning file"
  fmtTraceScanFileP = "{path}: scanning file"
  fmtTraceFIP       = "{chalk.fullpath}: Found @{$pt.startOffset}"
  eBadBin           = "{chalk.fullpath}: Found binary chalk magic, " &
                      "but chalk didn't parse"
  eBadJson          = "{chalk.fullpath}: Invalid input JSON in file"
  ePathNotFound     = "{path}: No such file or directory"
  ePureVirtual      = "Method is not defined; it must be overridden"

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

var installedPlugins: Table[string, Plugin]

proc registerPlugin*(name: string, plugin: Plugin) =
  if name in installedPlugins:
    error("Attempt to install a plugin named " &
          fmt"{name} when one is already installed")
  plugin.name            = name
  installedPlugins[name] = plugin

proc validatePlugins*() =
  for name, plugin in installedPlugins:
    let maybe = getPluginConfig(name)
    if maybe.isNone():
      error(fmt"No configuration provided for plugin {name}. Plugin ignored.")
      installedPlugins.del(name)
    else:
      plugin.configInfo = maybe.get()
      trace(fmt"Installed plugin {name}")

proc getPluginByName*(name: string): Plugin =
  return installedPlugins[name]

proc getPluginsByPriority*(): seq[Plugin] =
  var preResult: seq[(int, Plugin)] = @[]

  for name, plugin in installedPlugins:
    # This may need to be refreshed; the config can be updated
    # after the self-chalk loads.
    plugin.configInfo = getPluginConfig(name).get()
    if not plugin.configInfo.getEnabled():
      continue
    preResult.add((plugin.configInfo.getPriority(), plugin))

  preResult.sort()

  result = @[]

  for (_, plugin) in preResult:
    result.add(plugin)

proc getCodecsByPriority*(): seq[Codec] =
  var preResult: seq[(int, Codec)] = @[]

  for name, plugin in installedPlugins:
    # This may need to be refreshed; the config can be updated
    # after the self-chalk loads.
    plugin.configInfo = getPluginConfig(name).get()
    if not plugin.configInfo.getEnabled():
      continue
    if plugin.configInfo.getCodec():
      preResult.add((plugin.configInfo.getPriority(), Codec(plugin)))

  preResult.sort()

  result = @[]

  for (_, plugin) in preResult:
    result.add(plugin)

method getArtifactInfo*(self: Plugin, chalk: ChalkObj): KeyInfo {.base.} =
  var msg = "In plugin: " & self.name & ": " & ePureVirtual
  raise newException(Exception, msg)

method doVirtualLoad*(self: Codec, chalk: ChalkObj): void {.base.} =
  # Used to load a location when there's no file system object.
  var msg = "In plugin: " & self.name & ": " & ePureVirtual
  raise newException(Exception, msg)

proc getChalks*(self: Codec): seq[ChalkObj] {.inline.} =
  return self.chalks

method scan*(self: Codec, chalk: ChalkObj): bool {.base.} =
  ## Return true if the codec is going to handle this file.  This
  ## function should add position information and presence
  ## information into the chalk.primary: ChalkPoint object.
  ##
  ## If the Codec handles embedded chalks, register them with
  ## addEmbeddedChalkLoc()

  discard

method loadChalkLoc*(self:  Codec,
                     chalk: ChalkObj,
                     pt:    ChalkPoint = chalk.primary) {.base.} =
  var fields: ChalkDict

  trace(fmtTraceFIP.fmt())

  if SkipAutoWrite in chalk.flags:
    self.doVirtualLoad(chalk)
  else:
    chalk.stream.setPosition(pt.startOffset)
    if not chalk.stream.findJsonStart():
      pt.endOffset = pt.startOffset
      pt.valid = false
      return

    var truestart = chalk.stream.getPosition()
    try:
      fields         = chalk.stream.extractOneChalkJson(chalk.fullpath)
      pt.chalkFields = some(fields)
      pt.startOffset = truestart
      pt.endOffset   = chalk.stream.getPosition()
      pt.valid       = true
    except:
      error(eBadJson.fmt() & ": " & getCurrentExceptionMsg())
      pt.startOffset = truestart
      pt.endOffset   = chalk.stream.getPosition()
      pt.valid       = false

var numCachedFds: int = 0

proc acquireFileStream*(chalk: ChalkObj): Option[FileStream] =
  if chalk.stream == nil:
    let handle = newFileStream(chalk.fullpath, fmRead)
    if handle == nil:
      error(fmt"{chalk.fullpath}: could not open file.")
      return none(FileStream)

    trace(fmt"{chalk.fullpath}: File stream opened")
    chalk.stream = handle

    if numCachedFds < chalkConfig.getCacheFdLimit():
      numCachedFds = numCachedFds + 1

    return some(handle)
  else:
    result = some(chalk.stream)

proc closeFileStream*(chalk: ChalkObj) =
    try:
      if chalk.stream != nil:
        chalk.stream.close()
        trace(fmt"{chalk.fullpath}: File stream closed")
    except:
      warn(chalk.fullpath & ": Error when attempting to close file.")
    finally:
      chalk.stream = nil
      numCachedFds -= 1

proc yieldFileStream*(chalk: ChalkObj) =
  if numCachedFds == chalkConfig.getCacheFdLimit():
    chalk.closeFileStream()

proc dispatchFileScan(self:       Codec,
                      filepath:   string,
                      top:        string,
                      exclusions: var seq[string]): (bool, bool) =
  let
    chalk      = ChalkObj(fullpath: filepath, toplevel: top, stream: nil)
    `stream?` = chalk.acquireFileStream()

  if `stream?`.isNone():
    return (false, true)

  let success = self.scan(chalk)

  # If a file scan registers interest, returning the file will
  # automatically lead to the scan loop excluding that file.  However,
  # we want to let codecs exclude multiple files if it makes sense,
  # without polluting the method signature with rarely used variables.
  # So we'll check chalk.exclude here, for extra exclusions.

  if success:
    if len(chalk.exclude) != 0:
      for item in chalk.exclude:
        exclusions.add(item)
    self.chalks.add(chalk)
    if chalk.primary.present:
      self.loadChalkLoc(chalk)
    chalk.yieldFileStream()
    return (true, StopScan in chalk.flags)  # Found a codec to handle.
  else:
    chalk.closeFileStream()
    return (false, false) # This codec isn't handling.

proc mustIgnore*(path: string, globs: seq[Glob]): bool {.inline.} =
  for item in globs:
    if path.matches(item):
      return true
  return false

proc doScan*(self:       Codec,
             searchPath: seq[string],
             exclusions: var seq[string],
             ignoreList: seq[Glob],
             recurse:    bool): bool =
  ## Generate a list of all insertion/extraction points this codec
  ## belives it is responsible for, placing the resulting ChalkPoint
  ## objects into the `chalks` field, whether or not there is a chalk
  ## there to extract.
  ##
  ## Whenever we identify files where we're the proper codec,
  ## we are expected to add them to the exclusion list, so that
  ## there's no redundant work done (we don't want to double-mark
  ## things).
  ##
  ## Note that, if we're scanning for extraction, in most contexts
  ## we'd expect EITHER a single chalk or a set of embedded chalks,
  ## but not both.  However, there could be exceptions to that rule,
  ## for instance, in client-side JavaScript.  Therefore, it's up to
  ## the concrete codec implementation to check for this condition
  ## and warn / error as appropriate.
  result = true # Default is to keep scanning

  if len(searchPath) != 0:
    self.searchPath = searchPath
  else:
    self.searchPath = @[resolvePath("")]

  for path in self.searchPath:
    trace(fmt"Codec beginning scan of {path}")
    var info: FileInfo
    try:
      info = getFileInfo(path)
    except:
      error(ePathNotFound.fmt())
      continue

    if info.kind == pcFile:
      if path in exclusions:
        continue
      if path.mustIgnore(ignoreList):
        continue
      trace(fmtTraceScanFileP.fmt())
      let (handling, stop) = self.dispatchFileScan(path, path, exclusions)
      if handling:
        exclusions.add(path)
      if stop:
        return false
    elif recurse:
      dirWalk(true):
        if item in exclusions:
          continue
        if item.mustIgnore(ignoreList):
          continue
        if getFileInfo(item).kind != pcFile:
          continue
        trace(fmtTraceScanFile.fmt())
        let (handling, stop) = self.dispatchFileScan(item, path, exclusions)
        if handling:
          exclusions.add(item)
        if stop:
          return false
    else:
      dirWalk(false):
        if item in exclusions:
          continue
        if item.mustIgnore(ignoreList):
          continue
        if getFileInfo(item).kind != pcFile:
          continue
        trace(fmt"Non-recursive dir walk examining: {item}")
        let (handling, stop) = self.dispatchFileScan(item, path, exclusions)
        if handling:
          exclusions.add(item)
        if stop:
          return false

method getArtifactHash*(self: Codec, chalk: ChalkObj): string {.base.} =
  raise newException(Exception, ePureVirtual)

proc processRawHash*(rawHash: string,
                     time:    uint64 = unixTimeInMs()): (string, string) =
  ## Return (hash, hash-as-ulid)
  var
    encodedHash = rawHash.toHex().toLowerAscii()
    ulidHiBytes  = rawHash[^10 .. ^9]
    ulidLowBytes = rawHash[^8 .. ^1]
    ulidHiInt    = (cast[ptr uint16](addr ulidHiBytes[0]))[]
    ulidLowInt   = (cast[ptr uint64](addr ulidLowBytes[0]))[]
    ulid         = encodeUlid(time, ulidHiInt, ulidLowInt)

  return (encodedHash, ulid)

method getArtifactInfo*(self: Codec, chalk: ChalkObj): KeyInfo =
  result = newTable[string, Box]()

  var
    hashFilesBox          = pack(@[chalk.fullpath])
    (encodedHash, chalkId) = processRawHash(self.getArtifactHash(chalk))

  result["HASH"]          = pack(encodedHash)
  result["HASH_FILES"]    = hashFilesBox
  result["ARTIFACT_PATH"] = pack(chalk.fullpath)
  result["CHALK_ID"]       = pack(chalkId)
  trace(fmt"chalkd: {chalkId}")

method handleWrite*(self:    Codec,
                    obj:     ChalkObj,
                    ctx:     Stream,
                    pre:     string,
                    encoded: Option[string],
                    post:    string) {.base.} =
  raise newException(Exception, ePureVirtual)


# We need to turn off UnusedImport here, because the nim static
# analyzer thinks the below imports are unused. When we first import,
# they call registerPlugin(), which absolutely will get called.
{.warning[UnusedImport]: off.}

import plugins/system
import plugins/ciGithub
import plugins/conffile
import plugins/codecShebang
import plugins/codecElf
import plugins/codecContainer
import plugins/codecZip
import plugins/custom
import plugins/ownerAuthors
import plugins/ownerGithub
import plugins/sbomCallback
import plugins/vctlGit
import plugins/metsys
