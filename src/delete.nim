import strformat
import streams
import os

import config
import plugins
import extract
import resources
import std/tempfiles

proc doDelete*() =
  trace("Identifying artifacts with existing SAMIs")
  doExtraction(onBehalfOfInjection = true) # TODO, make this flag an enum.
  
  var codecs = getCodecsByPriority()

  static:
    echo typeof(codecs)
  for pluginInfo in codecs:
    
    let
      codec = cast[Codec](pluginInfo.plugin)
      extracts = codec.getSamis()
    
    if len(extracts) == 0: continue

    for item in extracts:
      item.stream.setPosition(0)
      let
        outputPtrs = getOutputPointers()
        point = item.primary
        pre = item.stream.readStr(point.startOffset)
      forceInform(fmt"{item.fullPath}: removing sami")
      if getDryRun(): continue

      if point.endOffset > point.startOffset:
        item.stream.setPosition(point.endOffset)
        
      let
        post = item.stream.readAll()

      var
        f: File
        path: string
        ctx: FileStream

      try:
        (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix)
        ctx = newFileStream(f)
        codec.handleWrite(ctx, pre, "", post)
      except:
        error(eCantInsert.fmt())
        removeFile(path)
      finally:
        if ctx != nil:
          ctx.close()
          try:
            moveFile(path, item.fullPath)
          except:
            removeFile(path)
            raise
      
