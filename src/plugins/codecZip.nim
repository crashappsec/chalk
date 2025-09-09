##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Handle JAR, WAR and other ZIP-based formats.  Works fine w/ JAR
## signing, because it only signs what's in the manifest.

import std/[
  algorithm,
]
import pkg/[
  zippy/ziparchives,
]
import ".."/[
  chalkjson,
  config,
  plugin_api,
  run_management,
  subscan,
  types,
  utils/exe,
  utils/files,
]

const zipChalkFile = "chalk.json"
const chalkBinary = "chalk"

type
  ZipCache = ref object of RootRef
    size:          int
    tmpDir:        string
    origD:         string
    hashD:         string
    embeddedChalk: Option[Box]

proc artifactType(obj: ChalkObj): string =
  let extension = obj.fsRef.splitFile().ext.toLowerAscii()
  result =
    case extension
    of ".jar": artTypeJAR
    of ".war": artTypeWAR
    of ".ear": artTypeEAR
    else:      artTypeZip

proc hashZipPath(path: string): string =
  var
    sha   = initSha256()
    paths = newSeq[string]()

  for i in path.getAllFileNames(fileLinks = Yield):
    paths.add(i.name)

  paths.sort()
  sha.update($len(paths))

  for i in paths:
    let
      name   = i.removePrefix(path)
      stream = newFileStringStream(i)
    sha.update($(len(name)))
    sha.update(name)
    sha.update($(len(stream)))
    for c in stream.chunks(0..^1, 4096):
      sha.update(c)

  result = sha.finalHex()

template tryOrBail(code: untyped) =
  try:
    code
  except:
    error(loc & ": " & getCurrentExceptionMsg())
    dumpExOnDebug()
    return none(ChalkObj)

proc unchalkHashD(chalk: ChalkObj) =
  # Even if subscans are off, we do this delete for the purposes of hashing
  # as in order to compute conistent unchalked hash we need to:
  # * remove chalkmark/binary from zip itself
  # * delete chalkmark recursively from all files within the zip
  let
    cache           = ZipCache(chalk.cache)
    chalkMarkPath   = joinPath(cache.hashD, zipChalkFile)
    chalkBinaryPath = joinPath(cache.hashD, chalkBinary)
  discard runChalkSubScan(@[cache.hashD], "delete")
  if fileExists(chalkMarkPath):
    removeFile(chalkMarkPath)
  if fileExists(chalkBinaryPath):
    removeFile(chalkBinaryPath)
  chalk.cachedUnchalkedHash = cache.hashD.hashZipPath()

proc extractChalkMark(chalk: ChalkObj) =
  let
    cache         = ZipCache(chalk.cache)
    chalkMarkPath = joinPath(cache.origD, zipChalkFile)
  withFileStream(chalkMarkPath, mode = fmRead, strict = false):
    if stream == nil:
      chalk.marked = false
      return
    try:
      chalk.extract = stream.extractOneChalkJson(chalk.fsRef)
      chalk.marked  = true
    except:
      chalk.marked  = false

proc subscan(chalk: ChalkObj) =
  let cache = ZipCache(chalk.cache)
  if isSubscribedKey("EMBEDDED_CHALK"):
    let extractCtx = runChalkSubScan(@[cache.origD], "extract")
    if extractCtx.report.kind == MkSeq:
      if len(unpack[seq[Box]](extractCtx.report)) != 0:
        if chalk.extract == nil:
          warn(chalk.fsRef & ": contains chalked contents, but is not " &
               "itself chalked.")
          chalk.extract = ChalkDict()
        chalk.extract.setIfNeeded("EMBEDDED_CHALK", extractCtx.report)
  if getCommandName() != "extract":
    let collectionCtx = runChalkSubScan(@[cache.origD], getCommandName(), baseChalk = chalk)
    cache.embeddedChalk = some(collectionCtx.report)

proc zipScan(self: Plugin, loc: string): Option[ChalkObj] {.cdecl.} =
  var ext = loc.splitFile().ext.strip()

  if not ext.startsWith(".") or ext[1..^1] notin attrGet[seq[string]]("zip_extensions"):
    return none(ChalkObj)

  withFileStream(loc, mode = fmRead, strict = false):
    if stream == nil:
      return none(ChalkObj)

    tryOrBail:
      # Make sure the file seems to be a valid ZIP file.
      var buf: array[4, char]
      discard stream.peekData(addr(buf), 4)
      if buf[0] != 'P' or buf[1] != 'K':
        return none(ChalkObj)

  let
    subscans = attrGet[bool]("chalk_contained_items")
    debug    = attrGet[bool]("chalk_debug")
    tmpDir   = getNewTempDir()
    origD    = tmpDir.joinPath("contents")
    hashD    = tmpDir.joinPath("hash")
    cache    = ZipCache(
      size:   getFileInfo(loc).size,
      tmpDir: tmpDir,
      origD:  origD,
      hashD:  hashD,
    )
    chalk    = newChalk(
      name   = loc,
      cache  = cache,
      fsRef  = loc,
      codec  = self,
    )

  info(chalk.fsRef & ": temporarily extracting into " & tmpDir)
  tryOrBail:
    extractAll(chalk.fsRef, origD)
    extractAll(chalk.fsRef, hashD)
    chalk.extractChalkMark()
    chalk.unchalkHashD()

  if subscans:
    chalk.subscan()

  return some(chalk)

proc insertChalkBinaryIntoZip(chalk: ChalkObj) =
  ## Injects the chalk binary into a zip archive
  ## Raises an exception on failure

  let
    myAppPath          = getMyAppPath()
    chalkBinaryContent = tryToLoadFile(myAppPath)
    cache              = ZipCache(chalk.cache)
    contentDir         = cache.origD
    contentTargetPath  = joinPath(contentDir, "chalk")

  # Check the directory exists
  if not dirExists(contentDir):
      raise newException(IOError, chalk.name & ": zip content directory does not exist")

  # Write the chalk binary to content directory
  if tryToWriteFile(contentTargetPath, chalkBinaryContent):
    contentTargetPath.makeExecutable()
    trace(chalk.name & ": added chalk binary to content zip dir")
  else:
    raise newException(ValueError, "failed to add chalk binary to zip directory")


proc doZipWrite(chalk: ChalkObj, encoded: Option[string], virtual: bool) =
  let
    cache     = ZipCache(chalk.cache)
    chalkFile = joinPath(cache.origD, zipChalkFile)

  var dirToUse: string

  # need to close FD to be able to overwite the file
  closeFileStream(chalk.fsRef)
  try:
    if encoded.isSome():
      if not tryToWriteFile(chalkFile, encoded.get()):
        raise newException(OSError, chalkFile & ": could not write file")
      dirToUse = cache.origD
    else:
      dirToUse = cache.hashD

    # Create new archive by reading the directory
    if not virtual:
      createZipArchive(dirToUse & "/", chalk.fsRef)
    # Re-read to calculate hash
    chalk.cachedEndingHash = cache.origD.hashZipPath()
  except:
    error(chalkFile & ": " & getCurrentExceptionMsg())
    dumpExOnDebug()

proc zipHandleWrite(self: Plugin, chalk: ChalkObj, encoded: Option[string])
                   {.cdecl.} =
  let injectBinary = attrGet[bool]("zip.inject_binary")

  if injectBinary :
    let
      cache        = ZipCache(chalk.cache)
      threshold    = attrGet[int]("zip.inject_zip_size_threshold")
      combinedSize = cache.size + getChalkExeSize()
    if threshold > 0 and combinedSize > threshold:
      warn(chalk.name & ": skipping inserting binary into zip as combined size " &
           $combinedSize & " (bytes) >= " & $threshold & " (bytes)")
    else:
      let
        filename = chalk.fsRef.splitFile().name & chalk.fsRef.splitFile().ext
        allowedExtensions = attrGet[seq[string]]("zip.inject_binary_allowed_extensions")

      var shouldInject = false
      for ext in allowedExtensions:
        if filename.toLowerAscii().endsWith("." & ext.toLowerAscii()):
          shouldInject = true
          break

      if shouldInject:
        try:
          info(chalk.name & ": Inserting binary into zip archive")
          insertChalkBinaryIntoZip(chalk)
        except:
          error(chalk.name & ": failed to insert chalk binary due to: " & getCurrentExceptionMsg())
      else:
        trace(chalk.name & ": skipping binary injection - no matching extension found")

  chalk.doZipWrite(encoded, virtual = false)

proc zipGetEndingHash(self: Plugin, chalk: ChalkObj): Option[string] {.cdecl.} =
  if chalk.cachedEndingHash == "":
    # When true, --virtual was passed, so we skipped where we calculate
    # the hash post-write. Theoretically, the hash should be the same as
    # the unchalked hash, but there could be chalked files in there, so
    # we calculate by running our hashZip() function on the extracted
    # directory where we touched nothing.
    let cache = ZipCache(chalk.cache)
    chalk.cachedEndingHash = cache.origD.hashZipPath()

  return some(chalk.cachedEndingHash)

proc zipGetChalkTimeArtifactInfo(self: Plugin, obj: ChalkObj):
                                ChalkDict {.cdecl.} =
  let cache = ZipCache(obj.cache)
  result = ChalkDict()
  result.setIfNeeded("EMBEDDED_CHALK",  cache.embeddedChalk)
  result.setIfNeeded("EMBEDDED_TMPDIR", cache.tmpDir)
  result.setIfNeeded("ARTIFACT_TYPE",   obj.artifactType())

proc zipGetRunTimeArtifactInfo(self: Plugin,
                               obj: ChalkObj,
                               ins: bool,
                               ): ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_OP_ARTIFACT_TYPE", obj.artifactType())

proc zitemGetChalkTimeArtifactInfo(self: Plugin,
                                   obj: ChalkObj,
                                   ): ChalkDict {.cdecl.} =
  result = ChalkDict()
  if obj.baseChalk == nil or obj.baseChalk.myCodec.name != "zip":
    return
  result.setIfNeeded("CONTAINING_ARTIFACT_WHEN_CHALKED", obj.baseChalk.callGetChalkId())
  let cache = ZipCache(obj.baseChalk.cache)
  if obj.fsRef.startsWith(cache.origD):
    var name = obj.fsRef
    name.removePrefix(cache.origD)
    result.setIfNeeded("PATH_WITHIN_ZIP", name)
    obj.name = "zip:" & name

proc loadCodecZip*() =
  newCodec("zip",
           scan          = ScanCb(zipScan),
           handleWrite   = HandleWriteCb(zipHandleWrite),
           getEndingHash = EndingHashCb(zipGetEndingHash),
           ctArtCallback = ChalkTimeArtifactCb(zipGetChalkTimeArtifactInfo),
           rtArtCallback = RunTimeArtifactCb(zipGetRunTimeArtifactInfo))

  newPlugin("zippeditem",
            ctArtCallback = ChalkTimeArtifactCb(zitemGetChalkTimeArtifactInfo))
