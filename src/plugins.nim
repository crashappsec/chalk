import types
import utils
import config
import resources
import io/fromjson
import io/frombinary
import io/json

import con4m
import nimsha2

import algorithm
import tables
import streams
import strformat
import strutils
import options
import os

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
  
  inform(fmt"Installed plugin {name}")

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
  for k, v in installedPlugins:
    if v == self:
      echo "In plugin: ", k
      break
  raise newException(Exception, ePureVirtual)

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

  result = self.scan(sami)

  if result:
    self.samis.add(sami)
    if sami.primary.present:
      self.loadSamiLoc(sami)
    
proc addExclusion*(self: Codec, fullpath: string) =
  self.exclusions.add(fullpath)
      
proc doScan*(self: Codec,
             searchPath: seq[string],
             exclusions: seq[string],
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
  self.searchPath = searchPath
  self.exclusions = exclusions

  for path in self.searchPath:
    var info: FileInfo
    try:
      info = getFileInfo(path)
    except:
      error(ePathNotFound.fmt())
      continue

    trace(fmtTraceLoadArg.fmt())
    if info.kind == pcFile:
      if self.dispatchFileScan(path, path):
        self.addExclusion(path)
    elif recurse:
      dirWalk(false, walkDirRec):
        trace(fmtTraceScanFile.fmt())
        if self.dispatchFileScan(item, path):
          self.addExclusion(item)
    else:
      dirWalk(true, walkDir):
        if self.dispatchFileScan(item, path):
          self.addExclusion(item)
  

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
    (head, tail) = sami.fullpath.splitPath()
    hashFilesBox = boxList[Box](@[box(sami.fullpath)])
    encodedHash  = self.getArtifactHash(sami).toHex().toLowerAscii()
  

  result["HASH"]       = box(encodedHash)
  result["HASH_FILES"] = hashFilesBox
  result["SRC_PATH"]   = box(head)
  result["FILE_NAME"]  = box(tail)
  
method handleWrite*(self: Codec,
                    ctx: Stream,
                    pre: string,
                    encoded: string,
                    post: string) {.base.} =
  raise newException(Exception, ePureVirtual)
  

method getArtifactInfo*(self: ExternalPlugin, sami: SamiObj): KeyInfo =
  result = newTable[string, Box]()
  
  try:
    let
      str  = self.command & " " & sami.fullpath
      sbox = box(str)
      rbox = builtinCmd(@[sbox]).get()
      jobj = parseJson(newStringStream(unbox[string](rbox)))
      tbl  = jobj.kvpairs

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
import plugins/conffile
import plugins/codecShebang
import plugins/codecElf
import plugins/ownerAuthors
import plugins/ownerGithub
import plugins/vctlGit
