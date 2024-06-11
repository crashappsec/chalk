##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This is a simple codec for dealing with python bytecode files;
##  i.e., currently ones that have the extensions .pyc, .pyo, .pyd

import ".."/[config, plugin_api, util]

proc pycScan*(self: Plugin, loc: string): Option[ChalkObj] {.cdecl.} =
  var chalk: ChalkObj
  let ext = loc.splitFile().ext.strip()

  #Does this artifact have a python source file extension?
  # if so chalk it, else skip
  #TODO validate PYC header / magic ?

  if not ext.startsWith(".") or ext[1..^1] notin get[seq[string]](getChalkScope(), "pyc_extensions"):
    return none(ChalkObj)

  withFileStream(loc, mode = fmRead, strict = false):
    if stream == nil:
      return none(ChalkObj)

    let
      byte_blob = stream.readAll()
      ix        = byte_blob.find(magicUTF8)

    if ix == -1:
      #No magic == no existing chalk, new chalk created
      let chalk         = newChalk(name   = loc,
                                   fsRef  = loc,
                                   codec  =  self)
      chalk.startOffset = len(byte_blob)

    else: # Existing chalk, just reflect whats found
      stream.setPosition(ix)
      chalk = self.loadChalkFromFStream(stream, loc)

    return some(chalk)

proc pycHandleWrite*(self: Plugin, chalk: ChalkObj, encoded: Option[string])
                     {.cdecl.} =
  var
    pre:     string
    post:    string
    toWrite: string

  withFileStream(chalk.fsRef, mode = fmRead, strict = true):
    #Read up to previously set offset indicating where magic began
    pre  = stream.readStr(chalk.startOffset)
    #Move past
    if chalk.endOffset > chalk.startOffset:
      stream.setPosition(chalk.endOffset)
    #Read entire rest of file
      post = stream.readAll()

  #Build up a 'toWrite' string that will replace entire file
  if encoded.isSome():
    toWrite = pre
    toWrite &= encoded.get() & post.strip(chars = {' ', '\n'}, trailing = false)
  else:
    toWrite = pre

  if not chalk.replaceFileContents(toWrite):
    chalk.opFailed = true


proc pycGetUnchalkedHash*(self: Plugin, chalk: ChalkObj):
                        Option[string] {.cdecl.} =
  withFileStream(chalk.fsRef, mode = fmRead, strict = true):
    let toHash = $(stream.readStr(chalk.startOffset))
    return some(toHash.sha256Hex())

proc pycGetChalkTimeArtifactInfo*(self: Plugin, chalk: ChalkObj):
                                ChalkDict {.cdecl.} =
  result                  = ChalkDict()
  result["ARTIFACT_TYPE"] = artTypePyc

proc pycGetRunTimeArtifactInfo*(self:  Plugin, chalk: ChalkObj, ins: bool):
                              ChalkDict {.cdecl.} =
  result                      = ChalkDict()
  result["_OP_ARTIFACT_TYPE"] = artTypePyc

proc loadCodecPythonPyc*() =
  newCodec("python_pyc",
         scan              = ScanCb(pycScan),
         handleWrite       = HandleWriteCb(pycHandleWrite),
         getUnchalkedHash  = UnchalkedHashCb(pycGetUnchalkedHash),
         ctArtCallback     = ChalkTimeArtifactCb(pycGetChalkTimeArtifactInfo),
         rtArtCallback     = RunTimeArtifactCb(pycGetRunTimeArtifactInfo))
