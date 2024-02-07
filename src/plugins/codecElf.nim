##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##
import "."/elf
import ".."/[config, plugin_api, util]

const
  CHALK_MAGIC_JSON_KEY = "MAGIC\""
  CHALK_MAGIC_BABBLE   = "dadfedabbadabbed"

type
  ElfCodecCache    = ref object of RootRef
    fileData:      string
    unchalkedHash: string

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
  var stream: FileStream

  try:
    stream = newFileStream(location)

    if stream == nil:
      return none(ChalkObj)

    var magicBuffer: array[4, char]
    stream.read(magicBuffer)
    if magicBuffer != ELF_MAGIC_BYTES:
      stream.close()
      return none(ChalkObj)
    stream.setPosition(0)
    let fileData = stream.readAll()
    let elf      = newElfFileFromData(fileData)
    if not elf.parse():
      for err in elf.errors:
        error(location & ": " & err)

      stream.close()
      return none(ChalkObj)

    var chalkObject: ChalkObj
    if elf.chalkSectionHeader != nil and not elf.hasBeenUnchalked:
      let sectionOffset   = elf.chalkSectionHeader.offset.value
      var chalkMagicIndex = verifyChalkStart(elf.fileData[sectionOffset .. ^1])
      if chalkMagicIndex != -1:
        chalkMagicIndex += int(sectionOffset)
        stream.setPosition(chalkMagicIndex)
        chalkObject = codec.loadChalkFromFStream(stream, location)

    if chalkObject == nil:
      chalkObject = newChalk(name         = location,
                             fsRef        = location,
                             stream       = stream,
                             codec        = codec,
                             resourceType = {ResourceFile})

    chalkObject.cache = ElfCodecCache(fileData: fileData)
    return some(chalkObject)
  except:
    if stream != nil:
      stream.close()
    return none(ChalkObj)

proc elfGetUnchalkedHash*(codec: Plugin, chalk: ChalkObj):
                            Option[string] {.cdecl.} =
  if chalk.cache of ElfCodecCache:
    let cache = ElfCodecCache(chalk.cache)
    let hashElf = newElfFileFromData(cache.fileData)
    if hashElf.parse() and hashElf.unchalk():
      return some(hashElf.getChalkSectionData().hex())
    return some(cache.fileData.sha256Hex())
  return none(string)

proc elfHandleWrite*(codec: Plugin,
                       chalk: ChalkObj,
                       data: Option[string]) {.cdecl.} =
  try:
    if not (chalk.cache of ElfCodecCache):
      chalk.opFailed = true
      return

    let cache = ElfCodecCache(chalk.cache)
    let elf   = newElfFileFromData(cache.fileData)
    if elf.parse():
      var success: bool
      if data.isSome() and len(data.get()) > 0:
        if elf.chalkSectionHeader == nil:
          success = elf.insertChalkSection(SH_NAME_CHALKMARK, data.get())
        else:
          success = elf.setChalkSection(SH_NAME_CHALKMARK, data.get())
      else:
        success = elf.unchalk()
      if success and chalk.replaceFileContents(elf.fileData):
        return
  except:
    discard
  chalk.opFailed = true

proc elfGetChalkTimeArtifactInfo*(codec: Plugin, chalk: ChalkObj):
                                ChalkDict {.cdecl.} =
  result                      = ChalkDict()
  result["ARTIFACT_TYPE"]     = artTypeElf

proc elfGetRunTimeArtifactInfo*(codec: Plugin, chalk: ChalkObj, ins: bool):
                              ChalkDict {.cdecl.} =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypeElf

proc loadCodecElf*() =
  newCodec("elf",
         nativeObjPlatforms = @["linux"],
         scan               = ScanCb(elfScan),
         handleWrite        = HandleWriteCb(elfHandleWrite),
         getUnchalkedHash   = UnchalkedHashCb(elfGetUnchalkedHash),
         ctArtCallback      = ChalkTimeArtifactCb(elfGetChalkTimeArtifactInfo),
         rtArtCallback      = RunTimeArtifactCb(elfgetRunTimeArtifactInfo))
