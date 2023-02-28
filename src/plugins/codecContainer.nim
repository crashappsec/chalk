## This is currently a bare-bones implementation for container
## injection.  There is not yet functionality for deleting or
## extracting data from containers, and even the insertion will not
## actively place the metadata in containers, it just outputs it and
## expects your tooling to insert it.  This certainly needs to all be
## improved upon quickly!
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.


import os, tables, strutils, streams, nimutils, json
import ../types, ../config, ../plugins

when (NimMajor, NimMinor) < (1, 7):
  {.warning[LockLevel]: off.}

type CodecContainer* = ref object of Codec

method scan*(self: CodecContainer, obj: ChalkObj): bool =
  # Never interfere with self-chalk.  Leave that to the real codecs.
  if obj.fullpath == resolvePath(getAppFileName()):
    return false

  var idstr = chalkConfig.getContainerImageId()

  if idstr == "":
    return false

  if idstr.startsWith("sha256:"):
    idstr = idstr[7 .. ^1]

  idstr = idstr.toLowerAscii()
  if len(idstr) != 64:
    once:
      error("Invalid container image ID given (expected 64 bytes of hex)")
    return false

  for ch in idstr:
    if ch notin "0123456789abcdef":
      error("Invalid sh256 for container image ID given")
      return false

    # Create a liar chalk location.
  # Should probably have a bit in the obj.flags field to control.
  obj.primary = ChalkPoint(startOffset: 0, present: true)
  obj.exclude = @[]

  var path = obj.fullPath
  dirWalk(true, obj.exclude.add(item))

  once:
    obj.flags.incl(SkipAutoWrite)
    obj.flags.incl(StopScan)
    return true
  return false

method doVirtualLoad*(self: CodecContainer, obj: ChalkObj) =
  discard

method handleWrite*(self:    CodecContainer,
                    obj:     ChalkObj,
                    ctx:     Stream,
                    pre:     string,
                    encoded: Option[string],
                    post:    string) =
  # This gets called because we set the 'SkipAutoWrite' flag above.
  echo pretty(parseJson(encoded.get()))

method getArtifactInfo*(self: CodecContainer, obj: ChalkObj): KeyInfo =
  var
    idstr = chalkConfig.getContainerImageId()
    name  = chalkConfig.getContainerImageName()

  if idstr.startsWith("sha256:"):
    idstr = idstr[7 .. ^1]

  var
    shortBytes = idstr[^20 .. ^17]
    longBytes  = idstr[^16 .. ^1]
    shortInt   = fromHex[uint16](shortBytes)
    longInt    = fromHex[uint64](longBytes)
    ulid       = encodeUlid(unixTimeInMs(), shortInt, longInt)


  result                  = newTable[string, Box]()
  result["HASH"]          = pack(idstr)
  result["HASH_FILES"]    = pack(@[name])
  result["ARTIFACT_PATH"] = pack(name)
  result["CHALK_ID"]       = pack(ulid)

registerPlugin("container", CodecContainer())
