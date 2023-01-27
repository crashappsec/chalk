## This is a simple codec for dealing with unix "shebang" files; i.e., ones
## that start with #!.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import strutils, options, streams, nimSHA2, ../config, ../plugins

type CodecShebang* = ref object of Codec

method scan*(self: CodecShebang, sami: SamiObj): bool =
  var line1: string

  if sami.stream == nil:
    return false
  sami.stream.setPosition(0)
  try:
    line1 = sami.stream.readLine()
    if not line1.startsWith("#!"):
      return false
    let
      line2 = sami.stream.readLine()
      ix = line2.find(magicUTF8)
      pos = ix + line1.len() + 1 # +1 for the newline

    let
      present = if ix == -1: false else: true
      pointInfo = SamiPoint(startOffset: pos, present: present)

    sami.primary = pointInfo
    return true
  except:
    return false

method handleWrite*(self: CodecShebang,
                    ctx: Stream,
                    pre: string,
                    encoded: Option[string],
                    post: string) =

  if encoded.isSome():
    ctx.write(pre)
    if not pre.strip().endsWith("\n#"):
      ctx.write("\n# ")
    ctx.write(encoded.get())
  else:
    ctx.write(pre[0 ..< pre.find('\n')])
  ctx.write(post)

method getArtifactHash*(self: CodecShebang, sami: SamiObj): string =
  var shaCtx = initSHA[SHA256]()
  let pt = sami.primary

  sami.stream.setPosition(0)
  if pt.present:
    shaCtx.update(sami.stream.readLine())
    shaCtx.update("\n")
    discard sami.stream.readLine() # Skip line w/ old SAMI object

  shaCtx.update(sami.stream.readAll())

  return $shaCtx.final()

registerPlugin("shebang", CodecShebang())
