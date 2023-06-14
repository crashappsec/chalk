# This is a simple codec for dealing with python source code files;
#  i.e., currently ones that have the extensions .py, .ipy, .pyw
#
# The presence of shebangs on line1 is accounted for and dealt with
# identically to the shebang codec (i.e chalk goes on line2),
# for non-Shebang files chalk goes on line1
#
# :Author: Rich Smith (rich@crashoverride.com)
# :Copyright: 2022, 2023, Crash Override, Inc.

import tables, strutils, options, streams, ../config, ../plugins, os

type CodecPythonPy* = ref object of Codec

method scan*(self:   CodecPythonPy,
             stream: FileStream,
             path:   string): Option[ChalkObj] =
  var ext = path.splitFile().ext.strip()

  if (not ext.startsWith(".") or
        ext[1 .. ^1] notin chalkConfig.getPyExtensions()):
    return none(ChalkObj)

  return stream.scriptLoadMark(path)

method handleWrite*(self:    CodecPythonPy,
                    chalk:   ChalkObj,
                    encoded: Option[string]) =

  chalk.scriptHandleWrite(encoded)

method getChalkInfo*(self: CodecPythonPy, chalk: ChalkObj): ChalkDict =
  result                  = ChalkDict()
  result["ARTIFACT_TYPE"] = artTypePy

method getPostChalkInfo*(self:  CodecPythonPy,
                         chalk: ChalkObj,
                         ins:   bool): ChalkDict =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypePy

registerPlugin("python_py", CodecPythonPy())
