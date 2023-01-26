import os, tables, strformat, strutils, algorithm, streams, options, glob
import con4m, nimutils, config, io/[fromjson, json]

const
  fmtTraceScanFile  = "{item}: scanning file"
  fmtTraceScanFileP = "{path}: scanning file"
  fmtTraceFIP       = "{sami.fullpath}: Found @{$pt.startOffset}"
  eBadBin           = "{sami.fullpath}: Found binary SAMI magic, " &
                      "but SAMI didn't parse"
  eBadJson          = "{sami.fullpath}: Invalid input JSON in file"
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
    # after the self-sami loads.
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
    # after the self-sami loads.
    plugin.configInfo = getPluginConfig(name).get()
    if not plugin.configInfo.getEnabled():
      continue
    if plugin.configInfo.getCodec():
      preResult.add((plugin.configInfo.getPriority(), Codec(plugin)))

  preResult.sort()

  result = @[]

  for (_, plugin) in preResult:
    result.add(plugin)

method getArtifactInfo*(self: Plugin, sami: SamiObj): KeyInfo {.base.} =
  var msg = "In plugin: " & self.name & ": " & ePureVirtual
  raise newException(Exception, msg)

method doVirtualLoad*(self: Codec, sami: SamiObj): void {.base.} =
  # Used to load a location when there's no file system object.
  var msg = "In plugin: " & self.name & ": " & ePureVirtual
  raise newException(Exception, msg)

proc getSamis*(self: Codec): seq[SamiObj] {.inline.} =
  return self.samis

method scan*(self: Codec, sami: SamiObj): bool {.base.} =
  ## Return true if the codec is going to handle this file.  This
  ## function should add position information and presence
  ## information into the sami.primary: SamiPoint object.
  ##
  ## If the Codec handles embedded SAMIs, register them with
  ## addEmbeddedSamiLoc()

  discard

proc loadSamiLoc(self: Codec, sami: SamiObj, pt: SamiPoint = sami.primary) =
  var fields: SamiDict

  let swap = when system.cpuEndian == bigEndian:
               if not BigEndian in sami.flags: true else: false
             else:
               if BigEndian in sami.flags: true else: false

  trace(fmtTraceFIP.fmt())

  if SkipWrite in sami.flags:
    self.doVirtualLoad(sami)
  else:
    sami.stream.setPosition(pt.startOffset)
    if not sami.stream.findJsonStart():
      pt.endOffset = pt.startOffset
      pt.valid = false
      return

    var truestart = sami.stream.getPosition()
    try:
      fields = sami.extractOneSamiJson()
      pt.samiFields = some(fields)
      pt.startOffset = truestart
      pt.endOffset = sami.stream.getPosition()
      pt.valid = true
    except:
      error(eBadJson.fmt() & ": " & getCurrentExceptionMsg())
      pt.startOffset = truestart
      pt.endOffset = sami.stream.getPosition()
      pt.valid = false

var numCachedFds: int = 0

proc acquireFileStream*(sami: SamiObj): Option[FileStream] =
  if sami.stream == nil:
    let handle = newFileStream(sami.fullpath, fmRead)
    if handle == nil:
      error(fmt"{sami.fullpath}: could not open file.")
      return none(FileStream)

    trace(fmt"{sami.fullpath}: File stream opened")
    sami.stream = handle

    if numCachedFds < getCacheFdLimit():
      numCachedFds = numCachedFds + 1

    return some(handle)
  else:
    result = some(sami.stream)

proc closeFileStream*(sami: SamiObj) =
    try:
      if sami.stream != nil:
        sami.stream.close()
        trace(fmt"{sami.fullpath}: File stream closed")
    except:
      warn(sami.fullpath & ": Error when attempting to close file.")
    finally:
      sami.stream = nil
      numCachedFds -= 1

proc yieldFileStream*(sami: SamiObj) =
  if numCachedFds == getCacheFdLimit():
    sami.closeFileStream()

proc dispatchFileScan(self:       Codec,
                      filepath:   string,
                      top:        string,
                      exclusions: var seq[string]): bool =
  let
    sami      = SamiObj(fullpath: filepath, toplevel: top, stream: nil)
    `stream?` = sami.acquireFileStream()

  if `stream?`.isNone():
    return false

  result = self.scan(sami)

  # If a file scan registers interest, returning the file will
  # automatically lead to the scan loop exclusing that file.  However,
  # we want to let codecs exclude multiple files if it makes sense,
  # without polluting the method signature with rarely used variables.
  # So we'll check sami.exclude here, for extra exclusions.

  if result:
    if len(sami.exclude) != 0:
      for item in sami.exclude:
        exclusions.add(item)
    self.samis.add(sami)
    if sami.primary.present:
      self.loadSamiLoc(sami)
    sami.yieldFileStream()
    return true # Found a codec to handle.
  else:
    sami.closeFileStream()
    return false # This codec isn't handling.

proc mustIgnore*(path: string, globs: seq[Glob]): bool {.inline.} =
  for item in globs:
    if path.matches(item):
      return true
  return false

proc doScan*(self:       Codec,
             searchPath: seq[string],
             exclusions: var seq[string],
             ignoreList: seq[Glob],
             recurse:    bool) =
  ## Generate a list of all insertion/extraction points this codec
  ## belives it is responsible for, placing the resulting SamiPoint
  ## objects into the `samis` field, whether or not there is a SAMI
  ## there to extract.
  ##
  ## Whenever we identify files where we're the proper codec,
  ## we are expected to add them to the exclusion list, so that
  ## there's no redundant work done (we don't want to double-mark
  ## things).
  ##
  ## Note that, if we're scanning for extraction, in most contexts
  ## we'd expect EITHER a single SAMI or a set of embedded SAMIs,
  ## but not both.  However, there could be exceptions to that rule,
  ## for instance, in client-side JavaScript.  Therefore, it's up to
  ## the concrete codec implementation to check for this condition
  ## and warn / error as appropriate.
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
      if self.dispatchFileScan(path, path, exclusions):
        exclusions.add(path)
    elif recurse:
      dirWalk(true):
        if item in exclusions:
          continue
        if item.mustIgnore(ignoreList):
          continue
        if getFileInfo(item).kind != pcFile:
          continue
        trace(fmtTraceScanFile.fmt())
        if self.dispatchFileScan(item, path, exclusions):
          exclusions.add(item)
    else:
      dirWalk(false):
        if item in exclusions:
          continue
        if item.mustIgnore(ignoreList):
          continue
        if getFileInfo(item).kind != pcFile:
          continue
        trace(fmt"Non-recursive dir walk examining: {item}")
        if self.dispatchFileScan(item, path, exclusions):
          exclusions.add(item)

method getArtifactHash*(self: Codec, sami: SamiObj): string {.base.} =
  raise newException(Exception, ePureVirtual)

method getArtifactInfo*(self: Codec, sami: SamiObj): KeyInfo =
  result = newTable[string, Box]()

  var
    hashFilesBox = pack(@[sami.fullpath])
    rawHash      = self.getArtifactHash(sami)
    encodedHash  = rawHash.toHex().toLowerAscii()
    ulidHiBytes  = rawHash[^10 .. ^9]
    ulidLowBytes = rawHash[^8 .. ^1]
    ulidHiInt    = (cast[ptr uint16](addr ulidHiBytes[0]))[]
    ulidLowInt   = (cast[ptr uint64](addr ulidLowBytes[0]))[]
    now          = unixTimeInMs()
    samiId       = encodeUlid(now, ulidHiInt, ulidLowInt)

  result["HASH"]          = pack(encodedHash)
  result["HASH_FILES"]    = hashFilesBox
  result["ARTIFACT_PATH"] = pack(sami.fullpath)
  result["SAMI_ID"]       = pack(samiId)
  trace(fmt"samid: {samiId}")

method handleWrite*(self: Codec,
                    ctx: Stream,
                    pre: string,
                    encoded: Option[string],
                    post: string) {.base.} =
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
import plugins/codecGitRepo
import plugins/custom
import plugins/ownerAuthors
import plugins/ownerGithub
import plugins/sbomCallback
import plugins/vctlGit
import plugins/metsys
