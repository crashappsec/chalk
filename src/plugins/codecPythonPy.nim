## This is a simple codec for dealing with python source code files;
##  i.e., currently ones that have the extensions .py, .ipy, .pyw
##
## The presence of shebangs on line1 is accounted for and dealt with
## identically to the shebang codec (i.e chalk goes on line2),
## for non-Shebang files chalk goes on line1
##
## :Author: Rich Smith (rich@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import ../config, ../plugin_api


proc pyScan*(self: Plugin, path: string): Option[ChalkObj] {.cdecl.} =
  var ext = path.splitFile().ext.strip()

  if (not ext.startsWith(".") or
        ext[1 .. ^1] notin chalkConfig.getPyExtensions()):
    return none(ChalkObj)

  let stream = newFileStream(path)
  result     = self.scriptLoadMark(stream, path)

  if result == none(ChalkObj) and stream != nil:
      stream.close()

proc pyGetChalkTimeArtifactInfo*(self: Plugin, chalk: ChalkObj):
                               ChalkDict {.cdecl.} =
  result                  = ChalkDict()
  result["ARTIFACT_TYPE"] = artTypePy

proc pyGetRunTimeArtifactInfo*(self: Plugin, chalk: ChalkObj, ins: bool):
                             ChalkDict {.cdecl.} =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypePy

proc loadCodecPythonPy*() =
  newCodec("python_py",
         scan          = ScanCb(pyScan),
         ctArtCallback = ChalkTimeArtifactCb(pyGetChalkTimeArtifactInfo),
         rtArtCallback = RunTimeArtifactCb(pyGetRunTimeArtifactInfo),
         handleWrite   = HandleWriteCb(scriptHandleWrite))
