## This is a simple codec for dealing with unix "shebang" files; i.e., ones
## that start with #!.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import ../config, ../plugin_api

proc sheScan*(self: Plugin, path: string): Option[ChalkObj] {.cdecl.} =
  let stream = newFileStream(path)

  if stream == nil:
    return none(ChalkObj)

  try:
    let line1 = stream.readLine()
    if not line1.startsWith("#!"):
      stream.close()
      return none(ChalkObj)
  except:
    warn(path & ": Could not find a newline.")
    stream.close()
    return none(ChalkObj)

  return self.scriptLoadMark(stream, path)

proc sheGetChalkTimeArtifactInfo*(self: Plugin, chalk: ChalkObj):
                                ChalkDict {.cdecl.} =
  result                      = ChalkDict()
  result["ARTIFACT_TYPE"]     = artTypeShebang

proc sheGetRunTimeArtifactInfo*(self:  Plugin, chalk: ChalkObj, ins: bool):
                              ChalkDict {.cdecl.} =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypeShebang

proc loadCodecShebang*() =
  newCodec("shebang",
         scan          = ScanCb(sheScan),
         ctArtCallback = ChalkTimeArtifactCb(sheGetChalkTimeArtifactInfo),
         rtArtCallback = RunTimeArtifactCb(sheGetRunTimeArtifactInfo),
         handleWrite   = HandleWriteCb(scriptHandleWrite))
