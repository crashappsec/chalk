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
SCRIPT_PATH=$(echo ${SCRIPT_DIR})
CMDDIR=$(echo ${SCRIPT_PATH} | sed s/-/_CHALKDA_/g)
CMDDIR=$(echo ${CMDDIR} | sed s/" "/_CHALKSP_/g)
CMDDIR=$(echo ${CMDDIR} | sed s#/#_CHALKSL_#g)
CMDDIR=/tmp/${CMDDIR}

if [[ ! -d ${CMDDIR} ]] ; then
  mkdir ${CMDDIR}
fi

CMDLOC=${CMDDIR}/${BASE_NAME}

if [[ -x ${CMDLOC} ]] ; then
  HASH=$(/usr/bin/shasum --tag -a 256 ${CMDLOC} | cut -f 4 -d ' ')
  if [[ $(grep ${HASH} ${SCRIPT_PATH}/${BASE_NAME}) ]]; then
    exec ${CMDLOC} ${@}
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
    binStream: FileStream
    binFName:  string
    b64:       Option[string]
    contents:  string

template hasMachMagic(s: string): bool =
  s in ["\xca\xfe\xba\xbe", "\xfe\xed\xfa\xce", "\xce\xfa\xed\xfe",
        "\xfe\xed\xfa\xcf", "\xcf\xfa\xed\xfe"]

method scan*(self:   CodecMacOs,
             stream: FileStream,
             path:   string): Option[ChalkObj] =
  var
    header:      string
    fullpath   = path.resolvePath()
    cache      = ExeCache()
    wrapStream: FileStream
    chalk:      ChalkObj

  try:
    header = stream.peekStr(4)
  except:
    return none(ChalkObj)

  if header.hasMachMagic():
    trace("Found MACH binary @ " & fullpath)

    cache.binStream = stream
    cache.binFName  = fullpath

    let ix = fullpath.find("_CHALK")
    if ix != -1:
      fullpath   = fullpath[ix .. ^1]
      fullpath   = fullpath.replace("_CHALKDA_", "-")
      fullpath   = fullpath.replace("_CHALKSL_", "/")
      fullpath   = fullpath.replace("_CHALKSP_", " ")
      trace("Will look for chalk mark in wrapper script: " & fullpath)
      wrapStream = newFileStream(fullpath)

      if wrapStream == nil:
        warn("Previously chalked binary is missing its script. " &
          "Replace the script or rename the executable")
        return none(ChalkObj)
      # Drop down below for the chalk mark.
    else:
      # It's an unmarked Mach-O binary of some kind.
      chalk = newChalk(name         = fullpath,
                       fsRef        = fullpath,
                       stream       = stream,
                       resourceType = {ResourceFile},
                       cache        = cache,
                       codec        = self)

      return some(chalk)
  else:
    wrapStream = stream

  try:
    wrapStream.setPosition(0)
    let start = wrapStream.readStr(len(prefix))
    if start != prefix:
      return none(ChalkObj)
  except:
    return none(ChalkObj)

  # Validation.
  trace("Testing MacOS Chalk wrapper at: "  & fullpath)

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

  # Generally here, I'd want an option to seek to the end and not be
  # forced to validate everything, but can't easily use fseek().

  let lines = wrapStream.readAll().strip().split("\n")
  if len(lines) != 3 + len(postfixLines):
    trace("Wrapper not valid: # lines is wrong.")
    return none(ChalkObj)

  for i, line in postfixLines:
    if lines[i+1] != line:
      trace("Postfix lines don't match")
      return none(ChalkObj)

  let
    s     = lines[^1]
    sstrm = newStringStream(s)

  var dict: ChalkDict

  if s.find(magicUTF8) == -1:
    warn("Wrapper not valid; no chalk magic.")
    dict = ChalkDict(nil)
  else:
    dict = sstrm.extractOneChalkJson(fullpath)
    if sstrm.getPosition() != len(s):
      trace("Wrapper not valid; extra bits after mark")
      return none(ChalkObj)

  # At this point, the marked object is well formed.
  chalk = newChalk(name         = fullpath,
                   fsRef        = fullpath,
                   stream       = wrapStream,
                   resourceType = {ResourceFile},
                   cache        = cache,
                   codec        = self,
                   extract      = dict,
                   marked       = true)

  cache.b64 = some(lines[0])

  return some(chalk)

method getUnchalkedHash*(self: CodecMacOS, chalk: ChalkObj): Option[string] =
  var contents: string

  if chalk.cachedPreHash == "":
    let cache = ExeCache(chalk.cache)

    if cache.b64.isSome():
       contents = decode(cache.b64.get())
    elif cache.binStream != nil:
      try:
        cache.binStream.setPosition(0)
        contents       = cache.binStream.readAll()
        cache.contents = contents
        cache.binStream.close()
      except:
        discard

    if contents == "":
      if cache.binFName != "":
        let f = newFileStream(cache.binFName)
        if f != nil:
          try:
            contents       = f.readAll()
            cache.contents = contents
            f.close()
          except:
            discard
      if contents == "":
        error("MacOS binary contents could not be properly read.")
        return none(string)

    chalk.cachedPreHash = hashFmt($(contents.computeSHA256()))
    if not isChalkingOp():
      # the ending hash will be the hash of the script file as on disk.
      let sOpt = chalk.acquireFileStream()
      if sOpt.isSome():
        let s = sOpt.get()
        s.setPosition(0)
        let contents     = s.readAll()
        chalk.cachedHash = hashFmt($(contents.computeSHA256()))

  if chalk.cachedPreHash == "":
    return none(string)
  else:
    return some(chalk.cachedPreHash)

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
