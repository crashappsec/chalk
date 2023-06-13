# This is a simple codec for dealing with python source code files;
#  i.e., currently ones that have the extensions .py, .ipy, .pyw
#
# The presence of shebangs on line1 is accounted for and dealt with
# identically to the shebang codec (i.e chalk goes on line2),
# for non-Shebang files chalk goes on line1
#
# :Author: Rich Smith (rich@crashoverride.com)
# :Copyright: 2022, 2023, Crash Override, Inc.

import tables, strutils, options, streams, nimSHA2, ../config, ../plugins, os

type CodecPythonPy* = ref object of Codec

method scan*(self:   CodecPythonPy,
             stream: FileStream,
             loc:    string): Option[ChalkObj] =
    try:
        var chalk: ChalkObj
        var ext = loc.splitFile().ext.strip()

        #Does this artifact have a python source file extension?  If
        #so chalk it, else skip
        if (not ext.startsWith(".") or
            ext[1..^1] notin chalkConfig.getPyExtensions()):
            return none(ChalkObj)

        let line1 = stream.readLine()
        # If the first line starts with a #!
        # let the shebang plugin handle it.
        if line1.startsWith("#!"):
          return none(ChalkObj)
        else:
            # No shebang found so insert chalk data as new first line
            # behind a '#'
            let ix  = line1.find(magicUTF8)
            if ix == -1:
                #No magic == no existing chalk, new chalk created
                chalk             = newChalk(stream, loc)
                chalk.startOffset = 0
            else:#Existing chalk, just reflect whats found
                stream.setPosition(ix)
                chalk             = stream.loadChalkFromFStream(loc)
            return some(chalk)
    except:
        return none(ChalkObj)

method handleWrite*(self:    CodecPythonPy,
                    chalk:   ChalkObj,
                    encoded: Option[string]) =
  discard chalk.acquireFileStream()
  #Reset to start of file
  chalk.stream.setPosition(0)
  #Read up to previously set offset indicating where magic began
  let pre  = chalk.stream.readStr(chalk.startOffset)
  #Move past
  if chalk.endOffset > chalk.startOffset:
    chalk.stream.setPosition(chalk.endOffset)
  #Read entire rest of file
  let post = chalk.stream.readAll()

  var toWrite: string

  #Build up a 'toWrite' string that will replace entire file
  if encoded.isSome():
    toWrite = pre

    #Determine how we first need to slot in the chalk data
    #depends on if a shebang is present or not,
    #as well as whether existing chalk present already
    if len(pre.strip()) == 0:
        #1st chalk, no shebang
        toWrite &= "# "
    elif pre.startsWith("#!") and not pre.strip().endsWith("\n#"):
        #1st chalk, shebang detected on line1
        toWrite &= "\n# "
    #If neither condition above is true just update the chalk already present
    toWrite &= encoded.get() & "\n" & post.strip(chars = {' ', '\n'}, trailing = false)
  else:
    #TODO clean up like above
    var endPos = pre.find('\n')
    if endPos == -1:
      endPos = len(pre)
    toWrite = pre[0 ..< endPos] & "\n" & post
  chalk.closeFileStream()

  chalk.replaceFileContents(toWrite)

  chalk.cachedHash = hashFmt($(toWrite.computeSHA256()))

method getUnchalkedHash*(self: CodecPythonPy, chalk: ChalkObj): Option[string] =
  var toHash = ""
  let s = chalk.acquireFileStream()
  if s.isNone(): return none(string)

  chalk.stream.setPosition(0)
  if chalk.isMarked():
    toHash = chalk.stream.readLine() & "\n"
    chalk.stream.setPosition(chalk.endOffset + 1)
  toHash &= chalk.stream.readAll()
  return some(hashFmt($(toHash.computeSHA256())))

method getChalkInfo*(self: CodecPythonPy, chalk: ChalkObj): ChalkDict =
  result                  = ChalkDict()
  result["ARTIFACT_TYPE"] = artTypePy

method getPostChalkInfo*(self:  CodecPythonPy,
                         chalk: ChalkObj,
                         ins:   bool): ChalkDict =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypePy

registerPlugin("python_py", CodecPythonPy())
