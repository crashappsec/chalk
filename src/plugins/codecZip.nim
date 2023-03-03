import zippy/ziparchives_v1, streams, nimSha2, tables, times, strutils, options
import os, ../config, ../types, ../io/fromjson, ../plugins

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

const
  zipChalkFile = ".chalk.json"
  eBadFmt      = "{chalk.fullpath}: Invalid input JSON in file: "

type
  CodecZip = ref object of Codec
  ZipCache = ref object of RootObj
    archive: ZipArchive
    chalk:   string

method scan*(self:   CodecZip,
             stream: FileStream,
             loc:    string): Option[ChalkObj] =

  var ext = loc.splitFile().ext.strip()

  if not ext.startsWith(".") or ext[1..^1] notin chalkConfig.getZipExtensions():
    return none(ChalkObj)

  let
    chalk  = newChalk(stream, loc)
    cache  = ZipCache()

  chalk.cache   = cache
  cache.archive = ZipArchive()

  try:
    open(cache.archive, stream)
    if zipChalkFile in cache.archive.contents:
      let entry = cache.archive.contents[zipChalkFile]
      if not entry.contents.contains(magicUTF8): return some(chalk)

      let s         = newStringStream(entry.contents)
      chalk.extract = s.extractOneChalkJson(chalk.fullpath)
    return some(chalk)
  except:
    error(loc & ": Invalid input JSON in file: " & getCurrentExceptionMsg())
    return some(chalk)

method handleWrite*(self: CodecZip, chalk: ChalkObj, encoded: Option[string]) =
  # This really should reuse the file descriptor, but it currently means
  # forking zippy, which doesn't thrill me.
  let cache = ZipCache(chalk.cache)

  if encoded.isSome():
    cache.archive.contents[zipChalkFile] =
        ArchiveEntry(kind:         ekFile,
                     contents:     encoded.get(),
                     lastModified: getTime())
  elif cache.archive.contents.contains(zipChalkFile):
    cache.archive.contents.del(zipChalkFile)
  cache.archive.writeZipArchive(chalk.fullpath)

method getArtifactHash*(self: CodecZip, chalk: ChalkObj): string =
  # This is NOT the hash of the zip-file pre-chalk. That would be
  # a lot more work than we want.
  var keys: seq[string] = @[]
  var shaCtx            = initSHA[SHA256]()

  let cache = ZipCache(chalk.cache)
  for k, v in cache.archive.contents:
    if k == zipChalkFile: continue
    shaCtx.update(k)
    shaCtx.update(v.contents)

  return $shaCtx.final()

registerPlugin("zip", CodecZip())
