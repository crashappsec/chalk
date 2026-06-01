##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Upload Docker build contexts as OCI attestations to a registry.
## See docs/design-docker-registry.md for the full design.

import std/[
  json,
  os,
  times,
]
import ".."/[
  chalkjson,
  run_management,
  types,
  utils/files,
  utils/json,
]
import "."/[
  base,
  ids,
  manifest,
  tar,
]

const
  CONTEXT_ARTIFACT_TYPE*   = "application/vnd.crashoverride.chalk.build-context.v1"
  CONTEXT_LAYER_TYPE*      = "application/vnd.oci.image.layer.v1.tar+gzip"
  CONTEXT_CONFIG_TYPE*     = "application/vnd.oci.empty.v1+json"
  CONTEXT_CACHE_SUBDIR     = "chalk-build-contexts"
  CONTEXT_CACHE_DIR_FMT    = "yyyy-MM-dd'T'HH-mm-ss"
  ANNOTATION_CREATED       = "org.opencontainers.image.created"
  ANNOTATION_CONTEXT_NAME* = "dev.crashoverride.chalk.build-context.name"

type
  ContextTooLargeError = object of CatchableError
  ContextSnapshotEntry = JsonNode  ## JObject with strategy-specific fields
  ContextResults       = OrderedTableRef[
    string,
    OrderedTableRef[
      string,
      OrderedTableRef[string, string],
    ],
  ]
  SizeResults          = OrderedTableRef[
    string,
    OrderedTableRef[
      string,
      OrderedTableRef[string, int],
    ],
  ]

proc contextCacheDir*(): string =
  return getTempDir() / CONTEXT_CACHE_SUBDIR

proc cleanBuildContextCache*() =
  ## Remove datetime-stamped subdirectories older than build_context_cache_max_age.
  let dir = contextCacheDir()
  if not dirExists(dir):
    return
  # Duration is stored as microseconds in con4m
  let maxAgeUsec = int(attrGet[Con4mDuration]("docker.build_context_cache_max_age"))
  if maxAgeUsec == 0:
    return
  let cutoff = getTime() - initDuration(microseconds = maxAgeUsec)
  for kind, path in walkDir(dir):
    if kind != pcDir:
      continue
    try:
      let dt = parse(lastPathPart(path), CONTEXT_CACHE_DIR_FMT, utc())
      if dt.toTime() < cutoff:
        removeDir(path)
        trace("docker: cleaned old build context cache: " & path)
    except:
      trace("docker: error cleaning context cache dir " & path & ": " &
            getCurrentExceptionMsg())
      dumpExOnDebug()

proc readDockerignorePatterns(contextPath: string): seq[string] =
  let path = contextPath / ".dockerignore"
  if not fileExists(path):
    return @[]
  result = @[]
  for line in tryToLoadFile(path).splitLines():
    let p = line.strip()
    if p.len == 0 or p.startsWith('#'):
      continue
    if p.startsWith('!'):
      # Preserve '!' for negation; strip any leading '/' from the pattern part.
      result.add('!' & p[1 .. ^1].removePrefix('/'))
    else:
      result.add(p.removePrefix('/'))

proc contextToTarGz*(
    contextPath:       string,
    excludePatterns:   seq[string],
    honorDockerignore: bool  = false,
    maxFileSize:       int64 = 0,
): string =
  ## Archive a context directory to a temp .tar.gz and return its path.
  ## Files and directories matching any pattern in excludePatterns are omitted.
  ## When honorDockerignore is true, patterns from .dockerignore are also applied.
  ## Individual files larger than maxFileSize bytes are skipped (0 = no limit).
  let
    base    = lastPathPart(contextPath)
    dateDir = contextCacheDir() / now().utc.format(CONTEXT_CACHE_DIR_FMT)
  createDir(dateDir)
  var patterns: seq[string]
  if honorDockerignore:
    patterns.add(readDockerignorePatterns(contextPath))
  patterns.add(excludePatterns)
  let outPath = dateDir / (base & "-" & $int(epochTime()) & ".tar.gz")
  writeTarGz(
    outPath     = outPath,
    contextPath = contextPath,
    patterns    = patterns,
    maxFileSize = maxFileSize,
  )
  return outPath

proc newContextManifest(
    image:       DockerImage,
    subject:     DockerManifest,
    layer:       DockerManifest,
    contextName: string,
): DockerManifest =
  ## Build an OCI image manifest wrapping a context tarball layer.
  DockerManifest(
    kind:         DockerManifestType.image,
    name:         image.asOciAttestation(),
    mediaType:    "application/vnd.oci.image.manifest.v1+json",
    artifactType: CONTEXT_ARTIFACT_TYPE,
    subject:      subject,
    annotations:  %*({
      ANNOTATION_CREATED:      now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'"),
      ANNOTATION_CONTEXT_NAME: contextName,
    }),
    config: DockerManifest(
      kind:      DockerManifestType.config,
      name:      image,
      mediaType: CONTEXT_CONFIG_TYPE,
      json:      newJObject(),
    ),
    layers: @[layer],
  )

proc checkContextSize(
    tarPath:       string,
    contextName:   string,
    contextPath:   string,
    sizeThreshold: int,
): string =
  ## Returns "" if the tarball is within the allowed size.
  ## Returns a human-readable error message if the size exceeds the threshold.
  ## The caller is responsible for recording the failure in _OP_FAILED_KEYS.
  if sizeThreshold == 0:
    return ""
  let size = getFileSize(tarPath)
  if size > sizeThreshold:
    let msg = (
      "build context '" & contextName & "' (" & contextPath & ") tarball is " &
      $size & " bytes which exceeds upload_context_size_threshold of " &
      $sizeThreshold & " bytes"
    )
    warn("docker: " & msg & "; skipping upload")
    return msg
  return ""

proc uploadBuildContextsAtBuildTime*(
    ctx:    DockerInvocation,
    config: DockerContextUploadConfig,
): ChalkDict =
  ## Called at `chalk docker build` time **before** the chalk mark is embedded
  ## in the image.  Performs the upload work that can be done without knowing
  ## the final image digest, and returns snapshot state to be embedded in the
  ## chalk mark so push time can complete the attestation manifest.
  result = ChalkDict()

  let contexts = ctx.getLocalDockerContexts()
  if len(contexts) == 0:
    trace("docker: build context upload skipped: no local directory contexts found")
    return

  let
    repoImage = parseImage(config.registryUri & "/" & config.repoPath)
    registry  = repoImage.registry
  var
    snapshots             = newJObject()
    tooLargeContexts:     seq[string]
    uploadFailedContexts: seq[string]
  for contextName, contextPath in contexts:
    var entry: ContextSnapshotEntry = nil
    try:
      case config.strategy
      of "registry":
        # Upload blob now so it is present in the registry at push time.
        trace("docker: uploading build context blob for '" & contextName &
              "' to " & $repoImage & " (registry strategy)")
        let tarPath = contextToTarGz(
          contextPath       = contextPath,
          excludePatterns   = config.excludePatterns,
          honorDockerignore = config.honorDockerignore,
          maxFileSize       = int64(config.maxFileSize),
        )
        try:
          let sizeErr = checkContextSize(
            tarPath       = tarPath,
            contextName   = contextName,
            contextPath   = contextPath,
            sizeThreshold = config.sizeThreshold,
          )
          if sizeErr != "":
            tooLargeContexts.add(contextName)
            continue
          let layer = DockerManifest(
            kind:       DockerManifestType.layer,
            name:       repoImage,
            mediaType:  CONTEXT_LAYER_TYPE,
            fileStream: newFileStringStream(tarPath),
          )
          layer.put()
          entry = %*{
            "strategy":    "registry",
            "blob_digest": layer.digest.extractDockerHash(),
            "blob_size":   layer.size,
          }
          trace("docker: build context blob uploaded: sha256:" & entry["blob_digest"].getStr())
        finally:
          removeFile(tarPath)

      of "local":
        # Save tarball for upload at push time.
        let
          tarPath = contextToTarGz(
            contextPath       = contextPath,
            excludePatterns   = config.excludePatterns,
            honorDockerignore = config.honorDockerignore,
            maxFileSize       = int64(config.maxFileSize),
          )
          sizeErr = checkContextSize(
            tarPath       = tarPath,
            contextName   = contextName,
            contextPath   = contextPath,
            sizeThreshold = config.sizeThreshold,
          )
        if sizeErr != "":
          removeFile(tarPath)
          tooLargeContexts.add(contextName)
          continue
        entry = %*{
          "strategy": "local",
          "tar_path": tarPath,
        }
        trace("docker: build context tarball cached at: " & tarPath)

      of "disk":
        # Record the context path; push time will read from disk.
        entry = %*{
          "strategy":           "disk",
          "context_path":       contextPath,
          "size_threshold":     config.sizeThreshold,
          "exclude_patterns":   config.excludePatterns,
          "honor_dockerignore": config.honorDockerignore,
          "max_file_size":      config.maxFileSize,
        }
        trace("docker: build context disk strategy: path=" & contextPath)

      else:
        warn("docker: unknown upload_context_strategy: " & config.strategy)

    except:
      let errMsg = getCurrentExceptionMsg()
      error("docker: build context '" & contextName & "' upload failed: " & errMsg)
      dumpExOnDebug()
      uploadFailedContexts.add(contextName & ": " & errMsg)

    if entry != nil:
      if registry notin snapshots:
        snapshots[registry] = newJObject()
      if config.repoPath notin snapshots[registry]:
        snapshots[registry][config.repoPath] = newJObject()
      snapshots[registry][config.repoPath][contextName] = entry

  if tooLargeContexts.len > 0:
    addFailedKey(
      "_REPO_BUILD_CONTEXTS",
      code        = "CONTEXT_TOO_LARGE",
      error       = "build contexts exceeded size_threshold: " & tooLargeContexts.join(", "),
      description = (
        "One or more build context tarballs exceeded the configured " &
        "upload_context_size_threshold. Increase the threshold or reduce " &
        "the context size to enable upload."
      ),
    )
  if uploadFailedContexts.len > 0:
    addFailedKey(
      "_REPO_BUILD_CONTEXTS",
      code        = "CONTEXT_UPLOAD_FAILED",
      error       = "build context blob upload failed: " & uploadFailedContexts.join("; "),
      description = (
        "One or more build context blobs could not be uploaded. Check " &
        "registry credentials and network access."
      ),
    )
  result.setIfNeeded("DOCKER_BUILD_CONTEXT_SNAPSHOTS", snapshots.nimJsonToBox())

proc completeBuildContextUpload(
    chalk:       ChalkObj,
    image:       DockerImage,
    snapshot:    ContextSnapshotEntry,
    contextName: string,
): (string, int) =
  ## Complete a single context upload by creating the attestation manifest.
  ## Returns (digest, tarSize) where digest is the context manifest digest
  ## (without sha256: prefix) and tarSize is the tarball size in bytes.
  ## Returns ("", 0) on failure.
  let
    strategy = snapshot{"strategy"}.getStr("")
    platform = if chalk.platform != nil: chalk.platform else: DockerPlatform()
    subject  = image.fetchImageManifest(platform)

  case strategy
  of "registry":
    let
      blobDigest = snapshot{"blob_digest"}.getStr("")
      blobSize   = snapshot{"blob_size"}.getInt(0)
    if blobDigest == "":
      warn("docker: context snapshot missing blobDigest for registry strategy")
      return ("", 0)
    # Layer is already in the registry; mark as fetched so put() is skipped.
    let
      layer       = DockerManifest(
        kind:      DockerManifestType.layer,
        name:      image,
        mediaType: CONTEXT_LAYER_TYPE,
        digest:    "sha256:" & blobDigest,
        size:      blobSize,
        isFetched: true,  # blob already uploaded at build time; skip put()
      )
      ctxManifest = newContextManifest(
        image       = image,
        subject     = subject,
        layer       = layer,
        contextName = contextName,
      )
    discard image.appendToAttestationManifestList(ctxManifest)
    return (ctxManifest.digest.extractDockerHash(), blobSize)

  of "local":
    let tarPath = snapshot{"tar_path"}.getStr("")
    if tarPath == "" or not fileExists(tarPath):
      warn("docker: context tarball not found at push time: " & tarPath)
      return ("", 0)
    let
      tarSize = int(getFileSize(tarPath))
      layer   = DockerManifest(
        kind:       DockerManifestType.layer,
        name:       image,
        mediaType:  CONTEXT_LAYER_TYPE,
        fileStream: newFileStringStream(tarPath),
      )
    layer.put()
    let ctxManifest = newContextManifest(
      image       = image,
      subject     = subject,
      layer       = layer,
      contextName = contextName,
    )
    discard image.appendToAttestationManifestList(ctxManifest)
    return (ctxManifest.digest.extractDockerHash(), tarSize)

  of "disk":
    let contextPath = snapshot{"context_path"}.getStr("")
    if contextPath == "" or not dirExists(contextPath):
      warn("docker: disk strategy: context dir not found at push time: " & contextPath)
      return ("", 0)
    warn("docker: disk strategy: context dir may have changed since build: " &
         contextPath)
    let
      sizeThreshold      = snapshot{"size_threshold"}.getInt(0)
      excludePatterns    = snapshot{"exclude_patterns"}.getStrElems()
      honorDockerignore  = snapshot{"honor_dockerignore"}.getBool(false)
      maxFileSize        = int64(snapshot{"max_file_size"}.getInt(0))
      tarPath            = contextToTarGz(
        contextPath       = contextPath,
        excludePatterns   = excludePatterns,
        honorDockerignore = honorDockerignore,
        maxFileSize       = maxFileSize,
      )
    try:
      let sizeErr = checkContextSize(
        tarPath       = tarPath,
        contextName   = contextName,
        contextPath   = contextPath,
        sizeThreshold = sizeThreshold,
      )
      if sizeErr != "":
        raise newException(ContextTooLargeError, sizeErr)
      let
        tarSize = int(getFileSize(tarPath))
        layer   = DockerManifest(
          kind:       DockerManifestType.layer,
          name:       image,
          mediaType:  CONTEXT_LAYER_TYPE,
          fileStream: newFileStringStream(tarPath),
        )
      layer.put()
      let ctxManifest = newContextManifest(
        image       = image,
        subject     = subject,
        layer       = layer,
        contextName = contextName,
      )
      discard image.appendToAttestationManifestList(ctxManifest)
      return (ctxManifest.digest.extractDockerHash(), tarSize)
    finally:
      removeFile(tarPath)

  else:
    warn("docker: unknown strategy in build context snapshot: " & strategy)
    return ("", 0)

proc completeBuildContextUploads*(
    chalk:  ChalkObj,
    source: ChalkDict,
): ChalkDict =
  ## Complete all pending build context uploads.
  ## `source` is either chalk.collectedData (at build time after the image is
  ## pushed) or chalk.extract (at push time after a separate docker push).
  result = ChalkDict()
  if "DOCKER_BUILD_CONTEXT_SNAPSHOTS" notin source:
    return

  let snapshots = parseJson(source["DOCKER_BUILD_CONTEXT_SNAPSHOTS"].boxToJson())

  var
    buildContexts         = ContextResults()
    sizeResults           = SizeResults()
    tooLargeContexts:     seq[string]
    uploadFailedContexts: seq[string]

  for image in chalk.repos.manifests:
    if image.registry notin snapshots:
      continue
    for repoPath, contexts in snapshots[image.registry].pairs:
      if repoPath != image.name:
        continue
      for contextName, snapshot in contexts.pairs:
        try:
          let (attestDigest, tarSize) = chalk.completeBuildContextUpload(
            image       = image,
            snapshot    = snapshot,
            contextName = contextName,
          )
          if attestDigest == "":
            continue
          discard buildContexts.hasKeyOrPut(
            image.registry,
            newOrderedTable[string, OrderedTableRef[string, string]](),
          )
          discard buildContexts[image.registry].hasKeyOrPut(
            repoPath,
            newOrderedTable[string, string](),
          )
          buildContexts[image.registry][repoPath][contextName] = attestDigest
          discard sizeResults.hasKeyOrPut(
            image.registry,
            newOrderedTable[string, OrderedTableRef[string, int]](),
          )
          discard sizeResults[image.registry].hasKeyOrPut(
            repoPath,
            newOrderedTable[string, int](),
          )
          sizeResults[image.registry][repoPath][contextName] = tarSize
          info("docker: build context '" & contextName & "' uploaded for " &
               image.registry & "/" & repoPath &
               " image digest " & image.digest)
        except ContextTooLargeError:
          error("docker: " & getCurrentExceptionMsg())
          dumpExOnDebug()
          tooLargeContexts.add(contextName)
        except:
          let
            exMsg  = getCurrentExceptionMsg()
            errMsg = (
              "build context '" & contextName & "' upload failed for " &
              image.registry & "/" & repoPath & ": " & exMsg
            )
          error("docker: " & errMsg)
          dumpExOnDebug()
          uploadFailedContexts.add(contextName & ": " & exMsg)

  if tooLargeContexts.len > 0:
    addFailedKey(
      "_REPO_BUILD_CONTEXTS",
      code        = "CONTEXT_TOO_LARGE",
      error       = "build contexts exceeded size_threshold: " & tooLargeContexts.join(", "),
      description = (
        "One or more build context tarballs exceeded the configured " &
        "upload_context_size_threshold. Increase the threshold or reduce " &
        "the context size to enable upload."
      ),
    )
  if uploadFailedContexts.len > 0:
    addFailedKey(
      "_REPO_BUILD_CONTEXTS",
      code        = "CONTEXT_UPLOAD_FAILED",
      error       = "build context upload failed: " & uploadFailedContexts.join("; "),
      description = (
        "One or more build contexts could not be uploaded. Check registry " &
        "credentials and network access."
      ),
    )
  result.setIfNeeded("_REPO_BUILD_CONTEXTS", buildContexts)
  result.setIfNeeded("_REPO_BUILD_CONTEXT_TAR_SIZES", sizeResults)
