## This is a simple codec for dealing with python bytecode files;
##  i.e., currently ones that have the extensions .pyc, .pyo, .pyd
##
## :Author: Rich Smith (rich@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import nimSHA2, ../config, ../plugin_api, ../util

type CodecPythonPyc* = ref object of Codec

method scan*(self:   CodecPythonPyc,
             stream: FileStream,
             loc:    string): Option[ChalkObj] =

    try:
        var chalk: ChalkObj
        var ext = loc.splitFile().ext.strip()

        #Does this artefact have a python source file extension?
        # if so chalk it, else skip
        #TODO validate PYC header / magic ?
        if not ext.startsWith(".") or
           ext[1..^1] notin chalkConfig.getPycExtensions():
            return none(ChalkObj)

        let byte_blob = stream.readAll()

        let ix  = byte_blob.find(magicUTF8)
        if ix == -1:
            #No magic == no existing chalk, new chalk created
            chalk             = newChalk(stream, loc)
            chalk.startOffset = len(byte_blob)

        else:#Existing chalk, just reflect whats found
            stream.setPosition(ix)
            chalk             = stream.loadChalkFromFStream(loc)
        return some(chalk)
    except:
        return none(ChalkObj)

method handleWrite*(self:    CodecPythonPyc,
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
    toWrite &= encoded.get() & post.strip(chars = {' ', '\n'}, trailing = false)
  else:
    toWrite = pre
  chalk.closeFileStream()

  #If NOT a dry-run replace file contents
  if not chalk.replaceFilecontents(toWrite):
    chalk.opFailed = true


method getUnchalkedHash*(self:  CodecPythonPyc,
                         chalk: ChalkObj): Option[string] =
  discard chalk.acquireFileStream()
  chalk.stream.setPosition(0)
  let toHash = $(chalk.stream.readStr(chalk.startOffset))
  return some(hashFmt($(toHash.computeSHA256())))

method getChalkTimeArtifactInfo*(self: CodecPythonPyc, chalk: ChalkObj):
       ChalkDict =
  result                  = ChalkDict()
  result["ARTIFACT_TYPE"] = artTypePyc

method getRunTimeArtifactInfo*(self:  CodecPythonPyc,
                               chalk: ChalkObj,
                               ins:   bool): ChalkDict =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypePyc

registerPlugin("python_pyc", CodecPythonPyc())
