## This is a simple codec for dealing with unix "shebang" files; i.e., ones
## that start with #!.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, strutils, options, streams, nimSHA2, ../config, ../plugins

type CodecShebang* = ref object of Codec

method scan*(self:   CodecShebang,
             stream: FileStream,
             loc:    string): Option[ChalkObj] =
  try:
    var chalk: ChalkObj
    let line1 = stream.readLine()
    if not line1.startsWith("#!"): return none(ChalkObj)
    let
      line2   = stream.readLine()
      ix      = line2.find(magicUTF8)
      pos     = ix + line1.len() + 1 # +1 for the newline
    if ix == -1:
      chalk             = newChalk(stream, loc)
      chalk.startOffset = len(line1)
    else:
      stream.setPosition(pos)
      chalk              = stream.loadChalkFromFStream(loc)
    return some(chalk)
  except:
    dumpExOnDebug()
    return none(ChalkObj)

method handleWrite*(self: CodecShebang, chalk: ChalkObj, enc: Option[string]) =
  chalk.stream.setPosition(0)
  let pre  = chalk.stream.readStr(chalk.startOffset)
  if chalk.endOffset > chalk.startOffset:
    chalk.stream.setPosition(chalk.endOffset)
  let post = chalk.stream.readAll()
  var toWrite: string

  if enc.isSome():
    toWrite = pre
    if not pre.strip().endsWith("\n#"): toWrite &= "\n# "
    toWrite &= enc.get()
    chalk.endOffset = len(toWrite)
    toWrite &= post
  else:
    chalk.endOffset = pre.find('\n')
    toWrite = pre[0 ..< chalk.endOffset] & post
  chalk.closeFileStream()
  chalk.replaceFileContents(toWrite)

method getUnchalkedHash*(self: CodecShebang, chalk: ChalkObj): Option[string] =
  var toHash = ""
  let s = chalk.acquireFileStream()
  if s.isNone(): return none(string)

  chalk.stream.setPosition(0)
  if chalk.isMarked():
    toHash = chalk.stream.readLine() & "\n"
    chalk.stream.setPosition(chalk.endOffset + 1)
  toHash &= chalk.stream.readAll()
  return some(hashFmt($(toHash.computeSHA256())))

method getChalkInfo*(self: CodecShebang, chalk: ChalkObj): ChalkDict =
  result                      = ChalkDict()
  result["ARTIFACT_TYPE"]     = artTypeShebang

method getPostChalkInfo*(self:  CodecShebang,
                         chalk: ChalkObj,
                         ins:   bool): ChalkDict =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypeShebang

registerPlugin("shebang", CodecShebang())
