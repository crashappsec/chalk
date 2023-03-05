## This is a simple codec for dealing with unix "shebang" files; i.e., ones
## that start with #!.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import strutils, options, streams, nimSHA2, ../types, ../config, ../plugins

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

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
    return none(ChalkObj)

method handleWrite*(self:    CodecShebang,
                    chalk:   ChalkObj,
                    encoded: Option[string],
                    virtual: bool): string =
  chalk.stream.setPosition(0)
  let pre  = chalk.stream.readStr(chalk.startOffset)
  if chalk.endOffset > chalk.startOffset:
    chalk.stream.setPosition(chalk.endOffset)
  let post = chalk.stream.readAll()
  var toWrite: string

  if encoded.isSome():
    toWrite = pre
    if not pre.strip().endsWith("\n#"): toWrite &= "\n# "
    toWrite &= encoded.get() & post
  else:
    toWrite = pre[0 ..< pre.find('\n')] & post
  chalk.closeFileStream()
  if not virtual: chalk.replaceFileContents(toWrite)
  return $(toWrite.computeSHA256())

method getArtifactHash*(self: CodecShebang, chalk: ChalkObj): string =
  var toHash = ""
  chalk.stream.setPosition(0)
  if chalk.isMarked():
    toHash = chalk.stream.readLine() & "\n"
    discard chalk.stream.readLine() # Skip line w/ old chalk object
  toHash &= chalk.stream.readAll()

  return $(toHash.computeSHA256())

registerPlugin("shebang", CodecShebang())
