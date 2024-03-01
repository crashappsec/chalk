##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Handle JAR, WAR and other ZIP-based formats.  Works fine w/ JAR
## signing, because it only signs what's in the manifest.

import std/algorithm
import pkg/[zippy/ziparchives_v1]
import ".."/[config, chalkjson, util, subscan, plugin_api]

const zipChalkFile = "chalk.json"

type
  ZipCache = ref object of RootRef
    onDisk:        ZipArchive
    embeddedChalk: Box
    tmpDir:        string

var
    zipDirs:  seq[string]
    chalkIds: seq[Box]

template pushZipDir(s: string)   = zipDirs.add(s)
template popZipDir()             = discard zipDirs.pop()
template pushChalkId(s: string)  = chalkIds.add(pack(s))
template popChalkId()            = discard chalkIds.pop()
template getZipDir(): string     = zipDirs[^1]
template getZipChalkId(): Box    = chalkIds[^1]

proc hashZip(toHash: ZipArchive): string =
  var sha = initSHA256()
  var keys: seq[string]

  for k, v in toHash.contents:
    if v.kind == ekFile:
      keys.add(k)

  keys.sort()
  sha.update($len(keys))

  for item in keys:
    sha.update($(len(item)))
    sha.update(item)
    let v = toHash.contents[item]
    sha.update($(len(v.contents)))
    sha.update(v.contents)

  result = sha.finalHex()

proc hashExtractedZip(dir: string): string =
  let toHash = ZipArchive()

  toHash.addDir(dir & "/")

  return toHash.hashZip()

template giveUp() =
  error(loc & ": " & getCurrentExceptionMsg())
  dumpExOnDebug()
  return none(ChalkObj)

template tryOrBail(code: untyped) =
  try:
    code
  except:
    giveUp()

proc zipScan*(self: Plugin, loc: string): Option[ChalkObj] {.cdecl.} =
  var
    ext = loc.splitFile().ext.strip()
    extractCtx: CollectionCtx

  if not ext.startsWith(".") or ext[1..^1] notin chalkConfig.getZipExtensions():
    return none(ChalkObj)

  withFileStream(loc, strict = true):
    tryOrBail:
      # Make sure the file seems to be a valid ZIP file.
      var buf: array[4, char]
      discard stream.peekData(addr(buf), 4)
      if buf[0] != 'P' or buf[1] != 'K':
        return none(ChalkObj)

    let
      tmpDir   = getNewTempDir()
      cache    = ZipCache()
      origD    = tmpDir.joinPath("contents")
      hashD    = tmpDir.joinPath("hash")
      subscans = chalkConfig.getChalkContainedItems()
      chalk    = newChalk(name   = loc,
                          cache  = cache,
                          fsRef  = loc,
                          stream = stream,
                          codec  = self)

    cache.onDisk  = ZipArchive()
    cache.tmpDir  = tmpDir

    cache.onDisk.open(stream)
    info(chalk.fsRef & ": temporarily extracting into " & tmpDir)
    tryOrBail:
        cache.onDisk.extractAll(origD)
        cache.onDisk.extractAll(hashD)

    # Even if subscans are off, we do this delete for the purposes of hashing.
    if not chalkConfig.getChalkDebug():
      toggleLoggingEnabled()
    discard runChalkSubScan(hashD, "delete")
    if not chalkConfig.getChalkDebug():
      toggleLoggingEnabled()

    if zipChalkFile in cache.onDisk.contents:
      tryOrBail:
        removeFile(joinPath(hashD, zipChalkFile))

      let contents = cache.onDisk.contents[zipChalkFile].contents
      if contents.contains(magicUTF8):
        let
          s           = newStringStream(contents)

        try:
          chalk.extract = s.extractOneChalkJson(chalk.fsRef)
          chalk.marked  = true
          s.close()
        except:
          discard
      else:
        chalk.marked  = false

    chalk.cachedPreHash = hashExtractedZip(hashD)

    if subscans:
      extractCtx = runChalkSubScan(origD, "extract")
      if extractCtx.report.kind == MkSeq:
        if len(unpack[seq[Box]](extractCtx.report)) != 0:
          if chalk.extract == nil:
            warn(chalk.fsRef & ": contains chalked contents, but is not " &
                 "itself chalked.")
            chalk.extract = ChalkDict()
          chalk.extract["EMBEDDED_CHALK"] = extractCtx.report
      if getCommandName() != "extract":
        pushZipDir(tmpDir)
        pushChalkId(chalk.cachedPreHash.idFormat())
        let collectionCtx = runChalkSubScan(origD, getCommandName())
        popChalkId()
        popZipDir()

        # Update the internal accounting for the sake of the post-op hash
        for k, v in cache.onDisk.contents:
          let tmpPath = os.joinPath(origD, k)
          if not tmpPath.fileExists():
            continue

          var newv = v
          let c = tryToLoadFile(tmpPath)
          newv.contents             = c
          cache.onDisk.contents[k]  = newV
        cache.embeddedChalk = collectionCtx.report

    return some(chalk)

proc doZipWrite(chalk: ChalkObj, encoded: Option[string], virtual: bool) =
  let
    cache     = ZipCache(chalk.cache)
    chalkFile = joinPath(cache.tmpDir, "contents", zipChalkFile)

  var dirToUse: string

  chalkCloseStream(chalk)
  try:
    if encoded.isSome():
      if not tryToWriteFile(chalkfile, encoded.get()):
        raise newException(OSError, chalkfile & ": could not write file")
      dirToUse = joinPath(cache.tmpDir, "contents")
    else:
      dirToUse = joinPath(cache.tmpDir, "hash")

    let newArchive = ZipArchive()
    newArchive.addDir(dirToUse & "/")
    if not virtual:
      newArchive.writeZipArchive(chalk.fsRef)
    chalk.cachedHash = newArchive.hashZip()
  except:
    error(chalkFile & ": " & getCurrentExceptionMsg())
    dumpExOnDebug()

proc zipHandleWrite*(self: Plugin, chalk: ChalkObj, encoded: Option[string])
                   {.cdecl.} =
  chalk.doZipWrite(encoded, virtual = false)

proc zipGetEndingHash*(self: Plugin, chalk: ChalkObj): Option[string] {.cdecl.} =
  if chalk.cachedHash == "":
    # When true, --virtual was passed, so we skipped where we calculate
    # the hash post-write. Theoretically, the hash should be the same as
    # the unchalked hash, but there could be chalked files in there, so
    # we calculate by running our hashZip() function on the extracted
    # directory where we touched nothing.
    let
      cache = ZipCache(chalk.cache)
      path  = cache.tmpDir.joinPath("contents") & "/"

    chalk.cachedHash = hashExtractedZip(path)

  return some(chalk.cachedHash)

proc zipGetChalkTimeArtifactInfo*(self: Plugin, obj: ChalkObj):
                                ChalkDict {.cdecl.} =
  let cache = ZipCache(obj.cache)
  result    = ChalkDict()

  if chalkConfig.getChalkContainedItems() and cache.embeddedChalk.kind != MkObj:
    result["EMBEDDED_CHALK"]  = cache.embeddedChalk
    result["EMBEDDED_TMPDIR"] = pack(cache.tmpDir)

  let extension = obj.fsRef.splitFile().ext.toLowerAscii()

  result["ARTIFACT_TYPE"] = case extension
                                of ".jar": artTypeJAR
                                of ".war": artTypeWAR
                                of ".ear": artTypeEAR
                                else:      artTypeZip

proc zipGetRunTimeArtifactInfo*(self: Plugin, obj: ChalkObj, ins: bool):
       ChalkDict {.cdecl.} =
  result        = ChalkDict()
  let extension = obj.fsRef.splitFile().ext.toLowerAscii()

  result["_OP_ARTIFACT_TYPE"] = case extension
                            of ".jar": artTypeJAR
                            of ".war": artTypeWAR
                            of ".ear": artTypeEAR
                            else:      artTypeZip

proc zitemGetChalkTimeArtifactInfo*(self: Plugin, obj: ChalkObj):
       ChalkDict {.cdecl.} =
  result = ChalkDict()

  if len(chalkIds) == 0:
    return

  if "PATH_WHEN_CHALKED" in obj.collectedData:
    let
      zipDir      = getZipDir()
      originalDir = joinPath(zipDir, "contents")
      origLen     = len(originalDir)
      path        = unpack[string](obj.collectedData["PATH_WHEN_CHALKED"])

    var name: string
    if path.startsWith(originalDir):
      name = path[origLen .. ^1]
      obj.collectedData.del("PATH_WHEN_CHALKED")
      result["PATH_WITHIN_ZIP"] = pack(name)
    else:
      name = path
    obj.name = "zip:" & name

  result["CONTAINING_ARTIFACT_WHEN_CHALKED"] = getZipChalkId()

proc loadCodecZip*() =
  newCodec("zip",
           scan          = ScanCb(zipScan),
           handleWrite   = HandleWriteCb(zipHandleWrite),
           getEndingHash = EndingHashCb(zipGetEndingHash),
           ctArtCallback = ChalkTimeArtifactCb(zipGetChalkTimeArtifactInfo),
           rtArtCallback = RunTimeArtifactCb(zipGetRuntimeArtifactInfo))

  newPlugin("zippeditem",
            ctArtCallback = ChalkTimeArtifactCb(zitemGetChalkTimeArtifactInfo))
