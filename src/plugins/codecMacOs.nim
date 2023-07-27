## Super cheezy plugin for OS X. I can't believe this even worked.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

# We use slightly different magic for our heredoc. It's uppercase and longer.

import base64, nimSHA2, ../config, ../chalkjson, ../util

var prefix = """
#!/bin/bash

BASE_NAME=$(basename -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )
SCRIPT_PATH=$(echo ${SCRIPT_DIR}/${BASE_NAME})
CMDLOC=/tmp/$(echo ${SCRIPT_PATH} | tr -- "-/ " _)

if [[ -x ${CMDLOC} ]] ; then
  HASH=$(/usr/bin/shasum --tag -a 256 ${CMDLOC} | cut -f 4 -d ' ')
  if [[ $(grep ${HASH} ${SCRIPT_PATH}) ]]; then
    exec ${CMDLOC} --macosx-metadata-location-info=${SCRIPT_PATH} ${@}
  fi
fi
(base64 -d)  < /bin/cat << CHALK_DADFEDABBADABBEDBAD_END > ${CMDLOC}
"""

var postfixLines = [
  "CHALK_DADFEDABBADABBEDBAD_END",
  "chmod +x ${CMDLOC}",
  "exec ${CMDLOC} ${@}"
]

type
  CodecMacOs* = ref object of Codec
  ExeCache    = ref object of RootRef
    contents: string
    b64:      Option[string]

template hasMachMagic(s: string): bool =
  if s.len() < 4:
    false
  else:
    s[0 ..< 4] in ["\xca\xfe\xba\xbe", "\xfe\xed\xfa\xce", "\xce\xfa\xed\xfe",
                   "\xfe\xed\xfa\xcf", "\xcf\xfa\xed\xfe"]

method scan*(self:   CodecMacOs,
             stream: FileStream,
             path:   string): Option[ChalkObj] =

  var
    contents = stream.readAll()
    fullpath = path.resolvePath()
    cache    = ExeCache()
    chalk:     ChalkObj

  if contents.hasMachMagic():
    # It's an unmarked Mach-O binary of some kind.
    chalk          = newChalk(stream, fullpath)
    chalk.cache    = cache
    chalk.extract  = ChalkDict()
    cache.contents = contents
    # Drop down below to cache the unchalked hash.

  elif contents.startswith(prefix):
    let lines = contents[len(prefix) .. ^1].strip().split('\n')
    # It's *probably* marked, but it might have been tampered with,
    # in which case we're going to let it get treated like a Unix
    # script.  So let's validate everything we expect to see.
    #
    # Since we've got out the prefix before splitting: line[0] should
    # be a base64 blob that decodes to our binary.  We should then see
    # exactly the lines in postfixLines.  Finally, there should be a
    # one-line SHA256 hash, then a one-line chalk mark.  Note that we
    # don't stick these in a comment; there's an 'exec' above it, so
    # bash will never get to it.
    if len(lines) != 3 + len(postfixLines):
      return none(ChalkObj)

    for i, line in postfixLines:
      if lines[i+1] != line:
        return none(ChalkObj)

    let
      s     = lines[^1]
      sstrm = newStringStream(s)

    if s.find(magicUTF8) == -1:
      return none(ChalkObj)
    let dict = sstrm.extractOneChalkJson(fullpath)
    if sstrm.getPosition() != len(s):
      return none(ChalkObj)

    # At this point, the marked object is well formed.
    chalk = newChalk(stream, fullpath)
    chalk.extract = dict
    chalk.marked  = true
    chalk.cache   = cache
    cache.b64     = some(lines[0])

    # Now we need to un-b64, because we need to compute the unchalked
    # hash below.
    cache.contents = decode(lines[0])
    # Let's finally make sure that this seems to be a valid binary:
    if not cache.contents.hasMachMagic():
      return none(ChalkObj)
  else:
    return none(ChalkObj)

  chalk.cachedPreHash = hashFmt($(cache.contents.computeSHA256()))

  if not isChalkingOp():
    # the ending hash will be the hash of the original file read.
    chalk.cachedHash = hashFmt($(contents.computeSHA256()))

  return some(chalk)

method handleWrite*(self: CodecMacOs, chalk: ChalkObj, enc: Option[string]) =
  var toWrite = ""
  let cache   = ExeCache(chalk.cache)

  if enc.isNone():
    # If we're being asked to delete a chalk mark, the thing is
    # definitely in script form, and our job is simply to replace the
    # file that's there with the base64-decoded version.
    toWrite = cache.contents
  else:
    toWrite = prefix

    if cache.b64.isSome():
      toWrite &= cache.b64.get()
    else:
      toWrite &= encode(cache.contents)
    toWrite &= "\n"
    for line in postFixLines:
      toWrite &= line & "\n"

    toWrite &= chalk.cachedPreHash & "\n"
    toWrite &= enc.get() & "\n"

  if not chalk.replaceFilecontents(toWrite):
    chalk.opFailed = true

method getChalkTimeArtifactInfo*(self: CodecMacOs, chalk: ChalkObj): ChalkDict =
  result                  = ChalkDict()
  result["ARTIFACT_TYPE"] = artTypeMachO

method getRunTimeArtifactInfo*(self:  CodecMacOs,
                               chalk: ChalkObj,
                               ins:   bool): ChalkDict =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypeMachO

method getNativeObjPlatforms*(s: CodecMacOs): seq[string] =  @["macosx"]

registerPlugin("macos", CodecMacOs())
