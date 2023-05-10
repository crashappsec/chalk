## This is currently a bare-bones implementation for container
## injection.  There is not yet functionality for deleting or
## extracting data from containers, and even the insertion will not
## actively place the metadata in containers, it just outputs it and
## expects your tooling to insert it.  This certainly needs to all be
## improved upon quickly!
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, strutils, json, glob, options, ../config, ../plugins

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

type
  CodecContainer* = ref object of Codec
  ContainerCache  = ref object of RootRef
    info: ChalkDict

method usesFStream*(self: CodecContainer): bool = false

method getUnchalkedHash*(self: CodecContainer, obj: ChalkObj): Option[string] =
  return none(string)

method getEndingHash*(self: CodecContainer, chalk: ChalkObj): Option[string] =
  return some(chalk.cachedHash)

let byteMap = { '0': 0, '1': 1, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6,
                '7': 7, '8': 8, '9': 9, 'a': 10, 'b': 11, 'c': 12, 'd': 13,
                'e': 14, 'f': 15 }.toTable()

method scanArtifactLocations*(self:       CodecContainer,
                              exclusions: var seq[string],
                              ignoreList: seq[Glob],
                              recurse:    bool): seq[ChalkObj] =

  result = @[]

  var
    idstr = chalkConfig.getContainerImageId().toLowerAscii()
    name  = chalkConfig.getContainerImageName()
    cache = ContainerCache(info: ChalkDict())
    b: byte

  if idstr == "": return
  if idstr.startsWith("sha256:"): idstr = idstr[7 .. ^1]

  if len(idstr) != 64:
    error("Invalid container image ID given (expected 64 bytes of hex)")
    return

  var hash = ""

  for i, ch in idstr:
    if ch notin bytemap:
      error("Invalid sh256 for container image ID given")
      return
    if i mod 2 == 0:
      b = byte(bytemap[ch] shl 4)
    else:
      hash.add(char(b or byte(bytemap[ch])))

  let obj        = newChalk(nil, name)
  obj.cache      = cache
  obj.cachedHash = hash

  # Go ahead and add this now!
  obj.collectedData["HASH_FILES"] = pack(@[name])
  result.add(obj)

method keepScanningOnSuccess*(self: CodecContainer): bool = false

method handleWrite*(self:    CodecContainer,
                    obj:     ChalkObj,
                    enc:     Option[string],
                    virtual: bool) =
  echo pretty(parseJson(enc.get()))

method getChalkInfo*(self: CodecContainer, chalk: ChalkObj): ChalkDict =
  result = ContainerCache(chalk.cache).info

method getPostChalkInfo*(self:  CodecContainer,
                         chalk: ChalkObj,
                         ins:   bool): ChalkDict =
  ChalkDict()  # Don't know how to pull the post-chalk value.

registerPlugin("container", CodecContainer())
