## Handle JAR, WAR and other ZIP-based formats.  Works fine w/ JAR
## signing, because it only signs what's in the manifest.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import zippy/ziparchives_v1, streams, nimSHA2, tables, times, strutils, options,
       os, ../config, ../chalkjson, ../plugins

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

const zipChalkFile = ".chalk.json"

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

proc getZipAsString(chalk: ChalkObj, encoded: Option[string]): string =
  let cache = ZipCache(chalk.cache)
  var stash: Option[ArchiveEntry] = none(ArchiveEntry)
  if encoded.isSome():
    cache.archive.contents[zipChalkFile] =
        ArchiveEntry(kind:         ekFile,
                     contents:     encoded.get(),
                     lastModified: getTime())
  elif cache.archive.contents.contains(zipChalkFile):
    stash = some(cache.archive.contents[zipChalkFile])
    cache.archive.contents.del(zipChalkFile)
  result = $(cache.archive)
  if stash.isSome(): cache.archive.contents[zipChalkFile] = stash.get()

method handleWrite*(self:    CodecZip,
                    chalk:   ChalkObj,
                    encoded: Option[string],
                    virtual: bool): string =
  let contents = chalk.getZipAsString(encoded)
  if not virtual: chalk.replaceFileContents(contents)
  return $(contents.computeSHA256())

method getArtifactHash*(self: CodecZip, chalk: ChalkObj): string =
  return $(chalk.getZipAsString(none(string)).computeSHA256())

# Normalize in case there are zip issues.
method getHashAsOnDisk*(self: CodecZip, chalk: ChalkObj): Option[string] =
  let toHash = $(ZipCache(chalk.cache).archive)
  return some($(toHash.computeSHA256()))

registerPlugin("zip", CodecZip())
