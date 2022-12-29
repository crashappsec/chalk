import types
import config
import osproc
import streams
import tables
import std/uri
import nimutils
import nimaws/s3client

var outputCallbacks: Table[string, SamiOutputHandler]

proc registerOutputHandler*(name: string, fn: SamiOutputHandler) =
  outputCallbacks[name] = fn

proc handleOutput*(content: string, context: SamiOutputContext) =
  let
    handleInfo = getOutputConfig()
    handles = case context
      of OutCtxInject:
        getInjectionOutputHandlers()
      of OutCtxInjectPrev:
        getInjectionPrevSamiOutputHandlers()
      of OutCtxExtract:
        getExtractionOutputHandlers()
  for handle in handles:
    if not (handle in handleInfo):
      # There's not a config blob, so we can't possibly
      # have the plugin loaded.
      continue

    let thisInfo = handleInfo[handle]

    if handle in outputCallbacks:
      # This is the standard path. If it's false, then we will check
      # below for a command in the handler.
      let fn = outputCallbacks[handle]

      # For now, we're not handling failure.  Need to think about how
      # we want to handle it.
      if not fn(content, thisInfo):
        when not defined(release):
          stderr.writeLine(fmt"Output handler {handle} failed.")
      continue
    elif thisInfo.getOutputCommand().isSome():
      let cmd = thisInfo.getOutputCommand().get()
      try:
        let
          process = startProcess(cmd[0],
                                 args = cmd[1 .. ^1],
                                 options = {poUsePath})
          (istream, ostream) = (process.outputStream, process.inputStream)
        ostream.write(content)
        ostream.flush()
        istream.close()
        discard process.waitForExit()
      except:
        when not defined(release):
          stderr.writeLine("Output handler {handle} failed.")
          raise

proc stdoutHandler*(content: string, h: SamiOutputSection): bool =
  echo content
  return true

proc localFileHandler*(content: string, h: SamiOutputSection): bool =
  var f: FileStream

  if not h.getOutputFilename().isSome():
    return false
  try:
    f = newFileStream(h.getOutputFileName().get(), fmWrite)
    f.write(content)
  except:
    return false
  finally:
    if f != nil:
      f.close()

proc awsFileHandler*(content: string, h: SamiOutputSection): bool =
  if h.getOutputSecret().isNone():
    stderr.writeLine("AWS secret not configured.")
    raise
  if h.getOutputUserId().isNone():
    stderr.writeLine("AWS iam user not configured.")
    raise
  if h.getOutputDstUri().isNone():
    stderr.writeLine("AWS bucket URI not configured.")
  if not h.getOutputRegion().isSome():
    stderr.writeLine("AWS region not configured.")

  let
    secret = h.getOutputSecret().get()
    userid = h.getOutputUserId().get()
    dstUri = parseURI(h.getOutputDstUri().get())
    bucket = dstUri.hostname
    path   = dstUri.path & "." & $(unixTimeInMS())
    region = h.getOutputRegion().get()

  var
    client = newS3Client((userid, secret))
    

  if dstUri.scheme != "s3":
    let msg = "AWS URI must be of type s3"
    stderr.writeLine(msg)
    raise newException(ValueError, msg)
    
  discard client.putObject(bucket, path, content)
  retrun true

registerOutputHandler("stdout", stdoutHandler)
registerOutputHandler("local_file", localFileHandler)
registerOutputHandler("s3", awsFileHandler)

