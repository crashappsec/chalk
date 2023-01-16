import os, tables, strformat, strutils, algorithm, streams, options
import nimSHA2, con4m, nimutils, config, io/[fromjson, frombinary, json]

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
    return

  let maybe = getPluginConfig(name)
  if maybe.isNone():
    error(fmt"No configuration provided for plugin {name}. Plugin ignored.")
    return

  plugin.configInfo = maybe.get()
  installedPlugins[name] = plugin

  trace(fmt"Installed plugin {name}")

proc loadCommandPlugins*() =
  for (name, command) in getCommandPlugins():
    registerPlugin(name, ExternalPlugin(command: command))

proc getPluginsByPriority*(): seq[PluginInfo] =
  result = @[]

  for name, plugin in installedPlugins:
    if not plugin.configInfo.getEnabled():
      continue
    result.add((plugin.configInfo.getPriority(), name, plugin))

  result.sort()

proc getCodecsByPriority*(): seq[PluginInfo] =
  result = @[]

  for name, plugin in installedPlugins:
    if not plugin.configInfo.getEnabled():
      continue
    if plugin.configInfo.getCodec():
      result.add((plugin.configInfo.getPriority(), name, plugin))

  result.sort()

proc getInfoPluginsByPriority*(): seq[PluginInfo] =
  result = @[]

  for name, plugin in installedPlugins:
    if plugin.configInfo.getCodec() or not plugin.configInfo.getEnabled():
      continue
    result.add((plugin.configInfo.getPriority(), name, plugin))

  result.sort()

method getArtifactInfo*(self: Plugin, sami: SamiObj): KeyInfo {.base.} =
  var msg = ePureVirtual

  for k, v in installedPlugins:
    if v == self:
      msg = "In plugin: " & k & ": " & msg
      break
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

  if Binary in sami.flags:
    sami.stream.setPosition(pt.startOffset + len(magicBin))

    try:
      fields = sami.extractOneSamiBinary(swap)
      pt.samiFields = some(fields)
      pt.endOffset = sami.stream.getPosition()
      pt.valid = true
      return
    except:
      warn(eBadBin.fmt() & " " & getCurrentExceptionMsg())
      pt.endOffset = sami.stream.getPosition()
      pt.valid = false
      return
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
      warn(eBadJson.fmt() & ": " & getCurrentExceptionMsg())
      pt.startOffset = truestart
      pt.endOffset = sami.stream.getPosition()
      pt.valid = false

proc dispatchFileScan(self: Codec, filepath: string, top: string): bool =
  let
    stream = newFileStream(filepath, fmRead)
    sami = SamiObj(fullpath: filepath, toplevel: top, stream: stream)

  if stream == nil:
    warn("Could not open file: " & filepath)
    return
  result = self.scan(sami)

  if result:
    self.samis.add(sami)
    if sami.primary.present:
      self.loadSamiLoc(sami)
  else:
    try:
      stream.close()
    except:
      discard

proc doScan*(self: Codec,
             searchPath: seq[string],
             exclusions: var seq[string],
             recurse: bool) =
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
      trace(fmtTraceScanFileP.fmt())
      if self.dispatchFileScan(path, path):
        exclusions.add(path)
    elif recurse:
      dirWalk(true):
        if item in exclusions:
          continue
        trace(fmtTraceScanFile.fmt())
        if self.dispatchFileScan(item, path):
          exclusions.add(item)
    else:
      dirWalk(false):
        if item in exclusions:
          continue
        trace(fmt"Non-recursive dir walk examining: {item}")
        if self.dispatchFileScan(item, path):
          exclusions.add(item)

# TODO: Probably need to add a hash scheme as an option.  Because
# even w/ shebang, it could make sense to hash the main script only,
# or it might make sense to hash the modules it loads, etc.  My
# original thinking was, the HASH field wouldn't stand in for a full
# integrity check a la a digital signature, it would be more to
# allow one to confirm the SAMI/artifact pairing, which might
# particularly be useful, if we end up with cases where the SAMI is
# *not* carried with the artifact.
method getArtifactHash*(self: Codec, sami: SamiObj): string {.base.} =
  raise newException(Exception, ePureVirtual)

method getArtifactInfo*(self: Codec, sami: SamiObj): KeyInfo =
  result = newTable[string, Box]()

  let
    hashFilesBox = pack(@[sami.fullpath])
    encodedHash = self.getArtifactHash(sami).toHex().toLowerAscii()


  result["HASH"] = pack(encodedHash)
  result["HASH_FILES"] = hashFilesBox
  result["ARTIFACT_PATH"] = pack(sami.fullpath)

method handleWrite*(self: Codec,
                    ctx: Stream,
                    pre: string,
                    encoded: Option[string],
                    post: string) {.base.} =
  raise newException(Exception, ePureVirtual)


method getArtifactInfo*(self: ExternalPlugin, sami: SamiObj): KeyInfo =
  result = newTable[string, Box]()

  try:
    let
      str = self.command & " " & sami.fullpath
      sbox = pack(str)
      rbox = builtinCmd(@[sbox]).get()
      jobj = parseJson(newStringStream(unpack[string](rbox)))
      tbl = jobj.kvpairs

    for key, val in tbl:
      let bval = val.jsonNodeToBox()

      result[key] = bval
  except:
    return

# We need to turn off UnusedImport here, because the nim static
# analyzer thinks the below imports are unused. When we first import,
# they call registerPlugin(), which absolutely will get called.
{.warning[UnusedImport]: off.}

import plugins/system
import plugins/ciGithub
import plugins/conffile
import plugins/codecShebang
import plugins/codecElf
import plugins/ownerAuthors
import plugins/ownerGithub
import plugins/vctlGit
import plugins/sbomCallback
