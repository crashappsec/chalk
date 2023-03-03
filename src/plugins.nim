## This is the focal point for most of the metadata gathering. While
## it's called from several commands, once the context comes to a
## single artifact, a lot of the work runs through here.
##
## This file itself provides base types for Plugin and Codec (a type
## of Plugin), and functions that manage dispatching to them, etc.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import os, tables, strformat, strutils, algorithm, options, glob, streams, posix
import con4m, nimutils, types, config, io/[fromjson, json], std/tempfiles

when (NimMajor, NimMinor) < (1, 7):  {.warning[LockLevel]: off.}

const  ePureVirtual = "Method is not defined; it must be overridden"

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

proc getPluginByName*(name: string): Plugin = return installedPlugins[name]

proc getPluginsByPriority*(): seq[Plugin] =
  var preResult: seq[(int, Plugin)] = @[]

  for name, plugin in installedPlugins:
    # This may need to be refreshed; the config can be updated
    # after the self-chalk loads.
    plugin.configInfo = getPluginConfig(name).get()
    if not plugin.configInfo.getEnabled(): continue
    preResult.add((plugin.configInfo.getPriority(), plugin))

  preResult.sort()

  result = @[]

  for (_, plugin) in preResult: result.add(plugin)

proc getCodecsByPriority*(): seq[Codec] =
  var preResult: seq[(int, Codec)] = @[]

  for name, plugin in installedPlugins:
    # This may need to be refreshed; the config can be updated
    # after the self-chalk loads.
    plugin.configInfo = getPluginConfig(name).get()
    if not plugin.configInfo.getEnabled(): continue
    if plugin.configInfo.getCodec():
      preResult.add((plugin.configInfo.getPriority(), Codec(plugin)))

  preResult.sort()

  result = @[]

  for (_, plugin) in preResult: result.add(plugin)

var numCachedFds = 0

proc acquireFileStream*(chalk: ChalkObj): Option[FileStream] =
  if chalk.stream == nil:
    let handle = newFileStream(chalk.fullpath, fmReadWriteExisting)
    if handle == nil:
      error(fmt"{chalk.fullpath}: could not open file.")
      return none(FileStream)

    trace(fmt"{chalk.fullpath}: File stream opened")
    chalk.stream  = handle
    numCachedFds += 1
    return some(handle)
  else:
    result = some(chalk.stream)

proc closeFileStream*(chalk: ChalkObj) =
    try:
      if chalk.stream != nil:
        chalk.stream.close()
        chalk.stream = nil
        trace(fmt"{chalk.fullpath}: File stream closed")
    except:
      warn(chalk.fullpath & ": Error when attempting to close file.")
    finally:
      chalk.stream = nil
      numCachedFds -= 1

proc yieldFileStream*(chalk: ChalkObj) =
  if numCachedFds == chalkConfig.getCacheFdLimit(): chalk.closeFileStream()

proc newChalk*(stream: FileStream, loc: string): ChalkObj =
  return ChalkObj(fullpath:  loc,
                  newFields: newTable[string, Box](),
                  stream:    stream,
                  extract:   nil)

proc loadChalkFromFStream*(stream: FileStream, loc: string): ChalkObj =
  result = newChalk(stream, loc)

  # If plugins position the file pointer, this will load chalk
  # and save the state necessary to find it on any write operation.
  var magicstart = stream.getPosition()

  trace(fmt"{result.fullpath}: chalk mark magic @{magicstart}")

  if not stream.findJsonStart():
    error(loc & ": Invalid JSON: found magic but no JSON start")
    return

  try:
    result.startOffset = result.stream.getPosition()
    result.extract     = result.stream.extractOneChalkJson(result.fullpath)
    result.endOffset   = result.stream.getPosition()
  except:
    error(loc & ": Invalid JSON: " & getCurrentExceptionMsg())

method usesFStream*(self: Codec): bool {.base.} = true

method getArtifactInfo*(self: Plugin, chalk: ChalkObj): ChalkDict {.base.} =
  var msg = "In plugin: " & self.name & ": " & ePureVirtual
  raise newException(Exception, msg)

method scan*(self:   Codec,
             stream: FileStream,
             loc:    string): Option[ChalkObj] {.base.} =
  # Used to handle one artifact.
  var msg = "In plugin: " & self.name & ": " & ePureVirtual
  raise newException(Exception, msg)

method keepScanningOnSuccess*(self: Codec): bool {.base.} = true

proc scanLocation(self:       Codec,
                  loc:        string,
                  exclusions: var seq[string]) =
  var stream = newFileStream(loc, fmRead)
  if stream == nil:
    error(loc & ": could not open file.")
    return
  else:
    trace(loc & ": File stream opened")
  let chalkOpt = self.scan(stream, loc)
  if chalkOpt.isNone():
    stream.close()
    return
  exclusions.add(loc)
  var chalk = chalkOpt.get()
  self.chalks.add(chalk)
  if numCachedFds < chalkConfig.getCacheFdLimit():
    numCachedFds = numCachedFds + 1
    chalk.stream = stream
  else:
    stream.close()
    trace(loc & ": File stream closed")

proc mustIgnore*(path: string, globs: seq[glob.Glob]): bool {.inline.} =
  for item in globs:
    if path.matches(item): return true
  return false

method scanArtifactLocations*(self:      Codec,
                             exclusions: var seq[string],
                             ignoreList: seq[glob.Glob],
                             recurse:    bool) {.base.} =
  # If you want a simpler interface, this will call scan()
  # with a file stream, and you pass back a Chalk object if chalk is
  # there.  Otherwise, you can overload this if you want to skip
  # the file system walk; just make sure to add any chalk objects
  # extracted.

  for path in self.searchPath:
    trace(fmt"Codec {self.name}: beginning scan of {path}")
    var info: FileInfo
    try:
      info = getFileInfo(path)
    except:
      error(fmt"{path}: No such file or directory")
      continue

    if info.kind == pcFile:
      if path in exclusions:          continue
      if path.mustIgnore(ignoreList): continue
      trace("{path}: scanning file")
      self.scanLocation(path, exclusions)
    elif recurse:
      dirWalk(true):
        if item in exclusions:               continue
        if item.mustIgnore(ignoreList):      continue
        if getFileInfo(item).kind != pcFile: continue
        trace(item & ": scanning file")
        self.scanLocation(item, exclusions)
    else:
      dirWalk(false):
        if item in exclusions:               continue
        if item.mustIgnore(ignoreList):      continue
        if getFileInfo(item).kind != pcFile: continue
        trace(fmt"Non-recursive dir walk examining: {item}")
        self.scanLocation(item, exclusions)

proc extractAll*(self:       Codec,
                 searchPath: seq[string],
                 exclusions: var seq[string],
                 ignoreList: seq[glob.Glob],
                 recurse:    bool): bool =
  result = true # Keep trying other codecs if nothing is found

  if len(searchPath) != 0: self.searchPath = searchPath
  else:                    self.searchPath = @[resolvePath("")]

  self.scanArtifactLocations(exclusions, ignoreList, recurse)
  if len(self.chalks) != 0:  return self.keepScanningOnSuccess()

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

method getArtifactInfo*(self: Codec, chalk: ChalkObj): ChalkDict =
  result = ChalkDict()

  var
    hashFilesBox           = pack(@[chalk.fullpath])
    (encodedHash, chalkId) = processRawHash(self.getArtifactHash(chalk))

  result["HASH"]           = pack(encodedHash)
  result["HASH_FILES"]     = hashFilesBox
  result["ARTIFACT_PATH"]  = pack(chalk.fullpath)
  result["CHALK_ID"]       = pack(chalkId)

method getNativeObjPlatforms*(s: Codec): seq[string] {.base.} = @[]

proc replaceFileContents*(chalk: ChalkObj, contents: string) =
  var
    (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
    ctx       = newFileStream(f)

  try:
    ctx.write(contents)
  finally:
    if ctx != nil:
      try:
        ctx.close()
        moveFile(path, chalk.fullpath)
      except:
        removeFile(path)
        error(fmt"{chalk.fullPath}: Could not write (no permission)")

method handleWrite*(s: Codec, chalk: ChalkObj, enc: Option[string]) {.base.} =
  var pre, post: string
  chalk.stream.setPosition(0)
  pre = chalk.stream.readStr(chalk.startOffset)
  if chalk.endOffset > chalk.startOffset:
    chalk.stream.setPosition(chalk.endOffset)
    post = chalk.stream.readAll()
  chalk.closeFileStream()
  chalk.replaceFileContents(pre & enc.getOrElse("") & post)

# We need to turn off UnusedImport here, because the nim static
# analyzer thinks the below imports are unused. When we first import,
# they call registerPlugin(), which absolutely will get called.
{.warning[UnusedImport]: off.}

import plugins/codecShebang
import plugins/codecElf
import plugins/codecContainer
import plugins/codecZip
import plugins/system
import plugins/ciGithub
import plugins/conffile
import plugins/custom
import plugins/ownerAuthors
import plugins/ownerGithub
import plugins/sbomCallback
import plugins/vctlGit
import plugins/metsys
