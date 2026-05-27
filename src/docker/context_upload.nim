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
import pkg/zippy/tarballs as zippyTarballs
import ".."/[
  run_management,
  types,
  utils/files,
  utils/json,
  utils/strings,
]
import "."/[
  base,
  ids,
  manifest,
]

const
  CONTEXT_ARTIFACT_TYPE* = "application/vnd.crashoverride.chalk.build-context.v1"
  CONTEXT_LAYER_TYPE*    = "application/vnd.oci.image.layer.v1.tar+gzip"
  CONTEXT_CONFIG_TYPE*   = "application/vnd.oci.empty.v1+json"
  CONTEXT_CACHE_SUBDIR   = "chalk-build-contexts"
  CONTEXT_CACHE_DIR_FMT  = "yyyy-MM-dd'T'HH-mm-ss"

type
  ContextSnapshotEntry = OrderedTableRef[string, string]
  ContextSnapshots     = OrderedTableRef[
    string,
    OrderedTableRef[
      string,
      OrderedTableRef[string, ContextSnapshotEntry],
    ],
  ]
  ContextResults       = OrderedTableRef[
    string,
    OrderedTableRef[
      string,
      OrderedTableRef[string, string],
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

proc contextToTarGz*(contextPath: string): string =
  ## Archive a context directory to a temp .tar.gz and return its path.
  let
    base    = lastPathPart(contextPath)
    dateDir = contextCacheDir() / now().utc.format(CONTEXT_CACHE_DIR_FMT)
  createDir(dateDir)
  let
    outPath = dateDir / (base & "-" & $int(epochTime()) & ".tar.gz")
    tb      = Tarball()
  tb.addDir(contextPath)
  tb.writeTarball(outPath)
  return outPath

proc newContextManifest(
    image:   DockerImage,
    subject: DockerManifest,
    layer:   DockerManifest,
): DockerManifest =
  ## Build an OCI image manifest wrapping a context tarball layer.
  DockerManifest(
    kind:         DockerManifestType.image,
    name:         image.asOciAttestation(),
    mediaType:    "application/vnd.oci.image.manifest.v1+json",
    artifactType: CONTEXT_ARTIFACT_TYPE,
    subject:      subject,
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
): bool =
  ## Returns true if the tarball is within the allowed size, false if it
  ## exceeds the threshold (in which case the failure is recorded in
  ## _OP_FAILED_KEYS via addFailedKey and the caller should skip the upload).
  if sizeThreshold == 0:
    return true
  let size = getFileSize(tarPath)
  if size > sizeThreshold:
    let msg = (
      "build context '" & contextName & "' (" & contextPath & ") tarball is " &
      $size & " bytes which exceeds upload_context_size_threshold of " &
      $sizeThreshold & " bytes"
    )
    warn("docker: " & msg & "; skipping upload")
    addFailedKey(
      "_REPO_BUILD_CONTEXTS",
      code        = "CONTEXT_TOO_LARGE",
      error       = msg,
      description = (
        "The build context tarball exceeded the configured " &
        "upload_context_size_threshold. Increase the threshold or reduce " &
        "the context size to enable upload."
      ),
    )
    return false
  return true

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
    snapshots = ContextSnapshots()
  for contextName, contextPath in contexts:
    var entry: ContextSnapshotEntry = nil
    case config.strategy
    of "registry":
      # Upload blob now so it is present in the registry at push time.
      trace("docker: uploading build context blob for '" & contextName &
            "' to " & $repoImage & " (registry strategy)")
      let tarPath = contextToTarGz(contextPath)
      try:
        if not checkContextSize(
          tarPath       = tarPath,
          contextName   = contextName,
          contextPath   = contextPath,
          sizeThreshold = config.sizeThreshold,
        ):
          continue
        let layer = DockerManifest(
          kind:       DockerManifestType.layer,
          name:       repoImage,
          mediaType:  CONTEXT_LAYER_TYPE,
          fileStream: newFileStringStream(tarPath),
        )
        layer.put()
        entry = newOrderedTable[string, string]({
          "strategy":    "registry",
          "blob_digest": layer.digest.extractDockerHash(),
          "blob_size":   $layer.size,
        })
        trace("docker: build context blob uploaded: sha256:" & entry["blob_digest"])
      finally:
        removeFile(tarPath)

    of "local":
      # Save tarball for upload at push time.
      let tarPath = contextToTarGz(contextPath)
      if not checkContextSize(tarPath, contextName, contextPath, config.sizeThreshold):
        removeFile(tarPath)
        continue
      entry = newOrderedTable[string, string]({
        "strategy": "local",
        "tar_path": tarPath,
      })
      trace("docker: build context tarball cached at: " & tarPath)

    of "disk":
      # Record the context path; push time will read from disk.
      entry = newOrderedTable[string, string]({
        "strategy":       "disk",
        "context_path":   contextPath,
        "size_threshold": $config.sizeThreshold,
      })
      trace("docker: build context disk strategy: path=" & contextPath)

    else:
      warn("docker: unknown upload_context_strategy: " & config.strategy)

    if entry != nil:
      discard snapshots.hasKeyOrPut(
        registry,
        newOrderedTable[string, OrderedTableRef[string, ContextSnapshotEntry]](),
      )
      discard snapshots[registry].hasKeyOrPut(
        config.repoPath,
        newOrderedTable[string, ContextSnapshotEntry](),
      )
      snapshots[registry][config.repoPath][contextName] = entry

  result.setIfNeeded("DOCKER_BUILD_CONTEXT_SNAPSHOTS", snapshots)

proc completeBuildContextUpload(
    chalk:       ChalkObj,
    image:       DockerImage,
    snapshot:    ContextSnapshotEntry,
    contextName: string,
): string =
  ## Complete a single context upload by creating the attestation manifest.
  ## Returns the attestation manifest digest (without sha256: prefix) on success,
  ## "" on failure.
  let
    strategy = snapshot.getOrDefault("strategy", "")
    platform = if chalk.platform != nil: chalk.platform else: DockerPlatform()
    subject  = image.fetchImageManifest(platform)

  case strategy
  of "registry":
    let
      blobDigest = snapshot.getOrDefault("blob_digest", "")
      blobSize   = parseInt(snapshot.getOrDefault("blob_size", "0"))
    if blobDigest == "":
      warn("docker: context snapshot missing blobDigest for registry strategy")
      return ""
    # Layer is already in the registry; mark as fetched so put() is skipped.
    let
      layer = DockerManifest(
        kind:      DockerManifestType.layer,
        name:      image,
        mediaType: CONTEXT_LAYER_TYPE,
        digest:    "sha256:" & blobDigest,
        size:      blobSize,
        isFetched: true,  # blob already uploaded at build time; skip put()
      )
      ctxManifest = newContextManifest(
        image   = image,
        subject = subject,
        layer   = layer,
      )
    return image.appendToAttestationManifestList(ctxManifest).digest.extractDockerHash()

  of "local":
    let tarPath = snapshot.getOrDefault("tar_path", "")
    if tarPath == "" or not fileExists(tarPath):
      warn("docker: context tarball not found at push time: " & tarPath)
      return ""
    let layer = DockerManifest(
      kind:       DockerManifestType.layer,
      name:       image,
      mediaType:  CONTEXT_LAYER_TYPE,
      fileStream: newFileStringStream(tarPath),
    )
    layer.put()
    let ctxManifest = newContextManifest(
      image   = image,
      subject = subject,
      layer   = layer,
    )
    return image.appendToAttestationManifestList(ctxManifest).digest.extractDockerHash()

  of "disk":
    let contextPath = snapshot.getOrDefault("context_path", "")
    if contextPath == "" or not dirExists(contextPath):
      warn("docker: disk strategy: context dir not found at push time: " & contextPath)
      return ""
    warn("docker: disk strategy: context dir may have changed since build: " &
         contextPath)
    let
      sizeThreshold = parseInt(snapshot.getOrDefault("size_threshold", "0"))
      tarPath       = contextToTarGz(contextPath)
    try:
      if not checkContextSize(
        tarPath       = tarPath,
        contextName   = contextName,
        contextPath   = contextPath,
        sizeThreshold = sizeThreshold,
      ):
        return ""
      let layer = DockerManifest(
        kind:       DockerManifestType.layer,
        name:       image,
        mediaType:  CONTEXT_LAYER_TYPE,
        fileStream: newFileStringStream(tarPath),
      )
      layer.put()
      let ctxManifest = newContextManifest(
        image   = image,
        subject = subject,
        layer   = layer,
      )
      return image.appendToAttestationManifestList(ctxManifest).digest.extractDockerHash()
    finally:
      removeFile(tarPath)

  else:
    warn("docker: unknown strategy in build context snapshot: " & strategy)
    return ""

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

  let snapshots = unpack[ContextSnapshots](source["DOCKER_BUILD_CONTEXT_SNAPSHOTS"])

  var buildContexts = ContextResults()

  for image in chalk.repos.manifests:
    if image.registry notin snapshots:
      continue
    for repoPath, contexts in snapshots[image.registry]:
      if repoPath != image.name:
        continue
      for contextName, snapshot in contexts:
        try:
          let attestDigest = chalk.completeBuildContextUpload(
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
          info("docker: build context '" & contextName & "' uploaded for " &
               image.registry & "/" & repoPath &
               " image digest " & image.digest)
        except:
          error("docker: build context upload failed: " & getCurrentExceptionMsg())
          dumpExOnDebug()

  result.setIfNeeded("_REPO_BUILD_CONTEXTS", buildContexts)
