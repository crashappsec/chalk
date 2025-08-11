##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[
  plugin_api,
  run_management,
  types,
  utils/files,
]
import "."/[
  elf,
]

const
  CHALK_MAGIC_JSON_KEY = "MAGIC\""
  CHALK_MAGIC_BABBLE   = "dadfedabbadabbed"

type
  ElfCodecCache    = ref object of RootRef
    elf:           ElfFile

proc skipBlankUntilMarker(data:     string,
                          index:    var int,
                          maxIndex: int,
                          marker:   char): int =
  var byte: char
  while true:
    if index >= maxIndex:
      raise newException(ValueError, "")
    byte = data[index]
    if byte != '\x20' and byte != '\x0a' and byte != '\x09':
      if byte != marker:
        raise newException(ValueError, "")
      return index
    index += 1

proc verifyChalkStart(data: string): int =
  var index    = 0
  var maxIndex = len(data) - 1
  try:
    index = skipBlankUntilMarker(data, index, maxIndex, '{') + 1
    index = skipBlankUntilMarker(data, index, maxIndex, '"') + 1
  except:
    return -1
  var magicLength  = len(CHALK_MAGIC_JSON_KEY)
  var babbleLength = len(CHALK_MAGIC_BABBLE)
  if maxIndex - index <= magicLength + babbleLength:
    return -1
  if data[index ..< index + magicLength] != CHALK_MAGIC_JSON_KEY:
    return -1
  index += magicLength
  try:
    index = skipBlankUntilMarker(data, index, maxIndex, ':') + 1
    index = skipBlankUntilMarker(data, index, maxIndex, '"') + 1
  except:
    return -1
  if (maxIndex - index) + 1 < babbleLength:
    return -1
  if data[index ..< index + babbleLength] != CHALK_MAGIC_BABBLE:
    return -1
  return index

proc elfScan*(codec: Plugin, location: string): Option[ChalkObj] {.cdecl.} =
  withFileStream(location, mode = fmRead, strict = false):
    if stream == nil:
      return none(ChalkObj)
    try:
      var magicBuffer: array[4, char]
      stream.peek(magicBuffer)
      if magicBuffer != ELF_MAGIC_BYTES:
        return none(ChalkObj)
      let elf = newElfFileFromData(newFileStringStream(location))
      if not getInternalScan():
        elf.fileData.load()

      if not elf.parse():
        return none(ChalkObj)

      let cache   = ElfCodecCache(elf: elf)
      var chalkObject: ChalkObj

      if not elf.hasBeenUnchalked:
        let
          (data, start, _) = elf.getChalkSectionData()
          magicOffset      = verifyChalkStart(data)
        if magicOffset != -1:
          stream.setPosition(start + magicOffset)
          chalkObject = codec.loadChalkFromFStream(
            stream,
            location,
            cache = cache,
          )

      if chalkObject == nil:
        chalkObject = newChalk(
          name         = location,
          fsRef        = location,
          codec        = codec,
          resourceType = {ResourceFile},
          cache        = cache,
        )

      return some(chalkObject)
    except:
      return none(ChalkObj)

proc elfGetUnchalkedHash*(codec: Plugin, chalk: ChalkObj):
                          Option[string] {.cdecl.} =
  let elf = ElfCodecCache(chalk.cache).elf
  return some(elf.getUnchalkedHash())

proc elfHandleWrite*(codec: Plugin,
                     chalk: ChalkObj,
                     data: Option[string],
                     ) {.cdecl.} =
  let elf = ElfCodecCache(chalk.cache).elf
  # mutating elf should be loaded, even if for internal scans
  # as its no longer a scan... but a chalking operation
  elf.fileData.load()
  # compute unchalked hash before the file is mutated
  # as otherwise to compute after the fact will need to modify
  # file stream again hence more memory usage
  discard chalk.callGetUnchalkedHash()
  try:
    let success =
      if len(data.get("")) > 0:
        elf.insertOrSetChalkSection(SH_NAME_CHALKMARK, data.get())
      else:
        elf.unchalk()
    if success and chalk.fsRef.replaceFileContents(elf.fileData.readAll()):
      return
  except:
    error("elf: write failed " & getCurrentExceptionMsg())
    dumpExOnDebug()
  chalk.opFailed = true

proc elfGetChalkTimeArtifactInfo*(codec: Plugin, chalk: ChalkObj):
                                ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("ARTIFACT_TYPE", artTypeElf)

proc elfGetRunTimeArtifactInfo*(codec: Plugin, chalk: ChalkObj, ins: bool):
                              ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_OP_ARTIFACT_TYPE", artTypeElf)

proc loadCodecElf*() =
  newCodec("elf",
         nativeObjPlatforms = @["linux"],
         scan               = ScanCb(elfScan),
         handleWrite        = HandleWriteCb(elfHandleWrite),
         getUnchalkedHash   = UnchalkedHashCb(elfGetUnchalkedHash),
         ctArtCallback      = ChalkTimeArtifactCb(elfGetChalkTimeArtifactInfo),
         rtArtCallback      = RunTimeArtifactCb(elfGetRunTimeArtifactInfo))
