## This is a simple codec for dealing with unix "shebang" files; i.e., ones
## that start with #!.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, strutils, options, streams, ../config, ../plugins

type CodecShebang* = ref object of Codec

method scan*(self:   CodecShebang,
             stream: FileStream,
             path:   string): Option[ChalkObj] =
  let line1 = stream.readLine()
  if not line1.startsWith("#!"): return none(ChalkObj)

  return stream.scriptLoadMark(path)

method handleWrite*(self: CodecShebang, chalk: ChalkObj, enc: Option[string]) =
  chalk.scriptHandleWrite(enc)

method getChalkInfo*(self: CodecShebang, chalk: ChalkObj): ChalkDict =
  result                      = ChalkDict()
  result["ARTIFACT_TYPE"]     = artTypeShebang

method getPostChalkInfo*(self:  CodecShebang,
                         chalk: ChalkObj,
                         ins:   bool): ChalkDict =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypeShebang

registerPlugin("shebang", CodecShebang())
