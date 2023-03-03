## This is currently a bare-bones implementation for container
## injection.  There is not yet functionality for deleting or
## extracting data from containers, and even the insertion will not
## actively place the metadata in containers, it just outputs it and
## expects your tooling to insert it.  This certainly needs to all be
## improved upon quickly!
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, strutils, nimutils, json, glob, ../types, ../config, ../plugins

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

type
  CodecContainer* = ref object of Codec
  ContainerCache  = ref object of RootRef
    info: ChalkDict

method usesFStream*(self: CodecContainer): bool = false

method scanArtifactLocations*(self:       CodecContainer,
                              exclusions: var seq[string],
                              ignoreList: seq[Glob],
                              recurse:    bool) =

  var
    idstr = chalkConfig.getContainerImageId().toLowerAscii()
    name  = chalkConfig.getContainerImageName()
    cache = ContainerCache(info: ChalkDict())

  if idstr == "": return

  if idstr.startsWith("sha256:"): idstr = idstr[7 .. ^1]

  if len(idstr) != 64:
    error("Invalid container image ID given (expected 64 bytes of hex)")
    return

  for ch in idstr:
    if ch notin "0123456789abcdef":
      error("Invalid sh256 for container image ID given")
      return


  self.chalks.add(ChalkObj(fullpath:  idstr,
                           newFields: newTable[string, Box](),
                           extract:   nil,
                           cache:     cache))
  var
    shortBytes = idstr[^20 .. ^17]
    longBytes  = idstr[^16 .. ^1]
    shortInt   = fromHex[uint16](shortBytes)
    longInt    = fromHex[uint64](longBytes)
    ulid       = encodeUlid(unixTimeInMs(), shortInt, longInt)

  cache.info["HASH"]          = pack(idstr)
  cache.info["HASH_FILES"]    = pack(@[name])
  cache.info["ARTIFACT_PATH"] = pack(name)
  cache.info["CHALK_ID"]      = pack(ulid)

  # TODO: if there's a chalk already we should load it.

method keepScanningOnSuccess*(self: CodecContainer): bool = false

method handleWrite*(self: CodecContainer, obj: ChalkObj, enc: Option[string]) =
  echo pretty(parseJson(enc.get()))

method getArtifactInfo*(self: CodecContainer, chalk: ChalkObj): ChalkDict =
  result = ContainerCache(chalk.cache).info

registerPlugin("container", CodecContainer())
