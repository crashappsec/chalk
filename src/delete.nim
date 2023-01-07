import strformat
import streams
import os
import options

import config
import plugins
import extract
import resources
import output
import std/tempfiles

proc doDelete*() =
  trace("Identifying artifacts with existing SAMIs")
  
  var codecs           = getCodecsByPriority()
  let pendingDeletions = doExtraction()

  if pendingDeletions.isSome():
    output("delete", logLevelNone, pendingDeletions.get())

  for pluginInfo in codecs:
    let
      codec    = cast[Codec](pluginInfo.plugin)
      extracts = codec.getSamis()
    
    if len(extracts) == 0: continue

    for item in extracts:
      if not item.primary.present:
        continue # It's markable, but not marked.
      item.stream.setPosition(0)
      let
        outputPtrs = getOutputPointers()
        point      = item.primary
        pre        = item.stream.readStr(point.startOffset)

      forceInform(fmt"{item.fullPath}: removing sami")
      if getDryRun(): continue

      if point.endOffset > point.startOffset:
        item.stream.setPosition(point.endOffset)
        
      let
        post = item.stream.readAll()

      var
        f:    File
        path: string
        ctx:  FileStream

      try:
        (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
        ctx       = newFileStream(f)
        codec.handleWrite(ctx, pre, none(string), post)
      except:
        error(eDeleteFailed.fmt())
        removeFile(path)
      finally:
        if ctx != nil:
          ctx.close()
          try:
            moveFile(path, item.fullPath)
          except:
            removeFile(path)
            raise

