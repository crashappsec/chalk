## Handle JAR, WAR and other ZIP-based formats.  Works fine w/ JAR
## signing, because it only signs what's in the manifest.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import zippy/ziparchives_v1, streams, nimSHA2, tables, strutils, options, os,
       std/algorithm, std/tempfiles, ../config, ../chalkjson, ../plugins

when (NimMajor, NimMinor) < (1, 7): {.warning[LockLevel]: off.}

const zipChalkFile = ".chalk.json"

type
  CodecZip = ref object of Codec
  ZipCache = ref object of RootObj
    onDisk:        ZipArchive
    embeddedChalk: Box
    tmpDir:        string
    endingHash:    string

method cleanup*(self: CodecZip, obj: ChalkObj) =
  let cache = ZipCache(obj.cache)

  if cache.tmpDir != "":
    removeDir(cache.tmpDir)

var zipDir: string

proc postprocessContext(collectionCtx: CollectionCtx) =
  let
    origD = joinPath(zipDir, "contents") & "/"
    l     = len(origD)

  # Remove the temporary directory from the start of any
  # ARTIFACT_PATH fields and UNCHALKED items
  for mark in collectionCtx.allChalks:
    if "ARTIFACT_PATH" in mark.collectedData:
      let path = unpack[string](mark.collectedData["ARTIFACT_PATH"])
      if path.startsWith(origD):
        mark.collectedData["ARTIFACT_PATH"] = pack(path[l .. ^1])

  var newUnmarked: seq[string] = @[]
  for item in collectionCtx.unmarked:
    if item.startsWith(origD):
      newUnmarked.add(item[l .. ^1])
    else:
      newUnmarked.add(item)
  collectionCtx.unmarked = newUnmarked

method scan*(self:   CodecZip,
             stream: FileStream,
             loc:    string): Option[ChalkObj] =

  var
    ext = loc.splitFile().ext.strip()
    extractCtx: CollectionCtx

  if not ext.startsWith(".") or ext[1..^1] notin chalkConfig.getZipExtensions():
    return none(ChalkObj)

  let
    tmpDir   = createTempDir(tmpFilePrefix, tmpFileSuffix)
    chalk    = newChalk(stream, loc)
    cache    = ZipCache()
    origD    = tmpDir.joinPath("contents")
    hashD    = tmpDir.joinPath("hash")
    subscans = chalkConfig.getChalkContainedItems()

  chalk.cache   = cache
  cache.onDisk  = ZipArchive()
  cache.tmpDir  = tmpDir

  try:
    stream.setPosition(0)
    cache.onDisk.open(stream)
    info(chalk.fullPath & ": temporarily extracting into " & tmpDir)
    zipDir = tmpDir
    cache.onDisk.extractAll(origD)
    cache.onDisk.extractAll(hashD)

    # Even if subscans are off, we do this delete for the purposes of hashing.
    toggleLoggingEnabled()
    discard runChalkSubScan(hashD, "delete")
    toggleLoggingEnabled()

    if zipChalkFile in cache.onDisk.contents:
      removeFile(joinPath(hashD, zipChalkFile))
      let contents = cache.onDisk.contents[zipChalkFile].contents
      if not contents.contains(magicUTF8): return some(chalk)
      let
        s           = newStringStream(contents)
      chalk.extract = s.extractOneChalkJson(chalk.fullpath)

    if subscans:
      extractCtx = runChalkSubScan(origD, "extract")
      if unpack[string](extractCtx.report) != "":
        if chalk.extract == nil:
          warn(chalk.fullPath & ": contains chalked contents, but is not " &
               "itself chalked.")
          chalk.extract = ChalkDict()
        chalk.extract["EMBEDDED_CHALK"] = extractCtx.report

      if getCommandName() != "extract":
        let collectionCtx = runChalkSubScan(origD, getCommandName(),
                                            postProcessContext)

        # Update the internal accounting for the sake of the post-op hash
        for k, v in cache.onDisk.contents:
          let tmpPath = os.joinPath(origD, k)
          if not tmpPath.fileExists():
            continue

          var newv = v
          let
            f = open(tmpPath, fmRead)
            c = f.readAll()
          f.close()
          newv.contents             = c
          cache.onDisk.contents[k]  = newV
        cache.embeddedChalk = collectionCtx.report

    return some(chalk)
  except:
    error(loc & ": " & getCurrentExceptionMsg())
    dumpExOnDebug()
    return some(chalk)

proc hashZip(toHash: ZipArchive): string =
  var sha = initSHA[SHA256]()
  var keys: seq[string]

  for k, v in toHash.contents:
    if v.kind == ekFile:
      keys.add(k)

  keys.sort()

  for item in keys:
    sha.update($(len(item)))
    sha.update(item)
    let v = toHash.contents[item]
    sha.update($(len(v.contents)))
    sha.update(v.contents)

  result = hashFmt($(sha.final))

proc doWrite(self: CodecZip, chalk: ChalkObj, encoded: Option[string],
             virtual: bool) =
  let
    cache     = ZipCache(chalk.cache)
    chalkFile = joinPath(cache.tmpDir, "contents", zipChalkFile)

  var dirToUse: string

  chalk.closeFileStream()
  try:
    if encoded.isSome():
      let f = open(chalkfile, fmWrite)
      f.write(encoded.get())
      f.close()
      dirToUse = joinPath(cache.tmpDir, "contents")
    else:
      dirToUse = joinPath(cache.tmpDir, "hash")

    let newArchive = ZipArchive()
    newArchive.addDir(dirToUse & "/")
    if not virtual:
      newArchive.writeZipArchive(chalk.fullPath)
    cache.endingHash = newArchive.hashZip()

  except:
    error(chalk.fullPath & ": " & getCurrentExceptionMsg())
    dumpExOnDebug()

method handleWrite*(self: CodecZip, chalk: ChalkObj, encoded: Option[string]) =
  self.doWrite(chalk, encoded, virtual = false)

method getUnchalkedHash*(self: CodecZip, chalk: ChalkObj): Option[string] =
  if chalk.cachedHash != "": return some(chalk.cachedHash)
  let
    cache  = ZipCache(chalk.cache)
    toHash = ZipArchive()
  toHash.addDir(joinPath(cache.tmpDir, "hash") & "/")

  chalk.cachedHash = toHash.hashZip()
  result           = some(chalk.cachedHash)

method getEndingHash*(self: CodecZip, chalk: ChalkObj): Option[string] =
  let
    cache  = ZipCache(chalk.cache)

  if cache.endingHash != "":
    return some(cache.endingHash)
  else:
    # --virtual was passed.
    self.doWrite(chalk, none(string), virtual = true)

method getChalkInfo*(self: CodecZip, obj: ChalkObj): ChalkDict =
  let cache = ZipCache(obj.cache)
  result    = ChalkDict()

  if chalkConfig.getChalkContainedItems() and
     unpack[string](cache.embeddedChalk) != "":
    result["EMBEDDED_CHALK"]  = cache.embeddedChalk
    result["EMBEDDED_TMPDIR"] = pack(cache.tmpDir)

  let extension = obj.fullPath.splitFile().ext.toLowerAscii()
  
  result["ARTIFACT_TYPE"] = case extension
                            of ".jar": artTypeJAR
                            of ".war": artTypeWAR
                            of ".ear": artTypeEAR
                            else:      artTypeZip
                                     
method getPostChalkInfo*(self: CodecZip, obj: ChalkObj, ins: bool): ChalkDict =
  result        = ChalkDict()
  let extension = obj.fullPath.splitFile().ext.toLowerAscii()
  
  result["_OP_ARTIFACT_TYPE"] = case extension
                            of ".jar": artTypeJAR
                            of ".war": artTypeWAR
                            of ".ear": artTypeEAR
                            else:      artTypeZip
  
registerPlugin("zip", CodecZip())
