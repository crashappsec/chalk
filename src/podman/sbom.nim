##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Collect customer-generated Podman SPDX JSON into `_IMAGE_SBOM`.
##
## One operation-local collector with three source variants: native Buildah
## outputs, a customer-written file handoff, and an existing registry
## attachment. Collection does not launch a scanner, rewrite the document,
## or retry a native build.

import std/[
  os,
  options,
  posix,
  strutils,
]
import ".."/[
  chalkjson,
  collect,
  config,
  reporting,
  run_management,
  types,
  utils/exec,
  utils/files,
  utils/json,
  utils/times,
]
import "../docker"/[
  ids,
  registry,
]
import "./run"
import "./scan"
import "./types" as podman_types

export podman_types.PodmanSbomDocument
export podman_types.PodmanSbomDiagnostic
export podman_types.PodmanSbomOutcome
export podman_types.PodmanSbomHandoff
export podman_types.HostFileSnapshot

const
  maxPodmanSbomBytes*     = 32 * 1024 * 1024
  podmanSbomTimeoutMs*    = 30_000
  podmanSbomHandoffVersion* = 1
  spdxJsonMediaType*      = "application/spdx+json"
  ociIndexMediaType       = "application/vnd.oci.image.index.v1+json"
  ociManifestMediaType    = "application/vnd.oci.image.manifest.v1+json"
  dockerManifestMediaType = "application/vnd.docker.distribution.manifest.v2+json"

proc diagnostic*(kind: podman_types.PodmanSbomDiagnosticKind,
                 message: string): podman_types.PodmanSbomOutcome =
  podman_types.PodmanSbomOutcome(
    kind:        psoDiagnostic,
    diagnostic:  podman_types.PodmanSbomDiagnostic(kind: kind, message: message),
  )

proc documentOutcome(parsed: JsonNode, sourceBytes: string,
                     sourceKind: podman_types.PodmanSbomSourceKind):
                    podman_types.PodmanSbomOutcome =
  podman_types.PodmanSbomOutcome(
    kind: psoDocument,
    document: podman_types.PodmanSbomDocument(
      parsed:       parsed,
      sourceBytes:  sourceBytes,
      sourceSha256: sourceBytes.sha256Hex(),
      sourceKind:   sourceKind,
    ),
  )

proc failedKeyCode*(kind: podman_types.PodmanSbomDiagnosticKind): string =
  case kind
  of pdkMissing:              "SBOM_MISSING"
  of pdkStale:                "SBOM_STALE"
  of pdkMalformed:            "SBOM_MALFORMED"
  of pdkInconsistent:         "SBOM_INCONSISTENT"
  of pdkOversized:            "SBOM_OVERSIZED"
  of pdkTimeout:              "SBOM_TIMEOUT"
  of pdkCancelled:            "SBOM_CANCELLED"
  of pdkStreamDestination:    "SBOM_STREAM"
  of pdkUnsupportedFormat:    "SBOM_UNSUPPORTED_FORMAT"
  of pdkChanging:             "SBOM_CHANGING"
  of pdkHandoffChecksum:      "SBOM_HANDOFF_CHECKSUM"
  of pdkHandoffImage:         "SBOM_HANDOFF_IMAGE"
  of pdkHandoffVersion:       "SBOM_HANDOFF_VERSION"
  of pdkAttachmentAbsent:     "SBOM_ATTACHMENT_ABSENT"
  of pdkAttachmentAmbiguous:  "SBOM_ATTACHMENT_AMBIGUOUS"
  of pdkAttachmentMismatch:   "SBOM_ATTACHMENT_MISMATCH"
  of pdkAuthFailure:          "SBOM_AUTH"
  of pdkOther:                "SBOM_COLLECTION_ERROR"

proc cleanupBudgetMs(deadline: MonoTime): int =
  let left = remainingMs(deadline)
  if left > 0:
    return left
  return 1000

proc isSha256Hex(value: string): bool =
  if len(value) != 64:
    return false
  for c in value:
    if c notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  return true

proc parseSha256Digest*(value: string): string =
  var hex = value.strip()
  if hex.toLowerAscii().startsWith("sha256:"):
    hex = hex[7 .. ^1]
  if not isSha256Hex(hex):
    return ""
  return "sha256:" & hex.toLowerAscii()

proc parsePodmanRegistryReference*(value: string): Option[DockerImage] =
  let lower = value.toLowerAscii()
  let at = lower.rfind("@sha256:")
  if at <= 0:
    return none(DockerImage)
  if not isSha256Hex(value[at + 8 .. ^1]):
    return none(DockerImage)
  let parsed = parseImage(value, defaultTag = "")
  if parsed.repo == "" or not isSha256Hex(parsed.digest):
    return none(DockerImage)
  return some(parsed)

proc sameImageId*(a, b: string): bool =
  let
    left  = extractDockerHash(a)
    right = extractDockerHash(b)
  return left != "" and left == right

proc normalizeDigest*(value: string): string =
  return parseSha256Digest(value)

proc hasNativeSbomDocument*(outputs: podman_types.PodmanSbomNativeOutputs): bool =
  outputs.hostOutput != "" or outputs.imageOutput != ""

proc isStreamDestination*(path: string): bool =
  if path == "" or path == "-":
    return true
  let normalized = path.replace('\\', '/').toLowerAscii()
  if normalized in [
    "/dev/stdout",
    "/dev/stderr",
    "/dev/stdin",
    "/dev/fd/0",
    "/dev/fd/1",
    "/dev/fd/2",
    "con",
    "nul",
  ]:
    return true
  if normalized.startsWith("/dev/fd/") or normalized.startsWith("/proc/self/fd/"):
    return true
  return false

proc resolveAgainst*(path, baseDir: string): string =
  if path == "" or path.isAbsolute():
    return path
  return baseDir / path

proc snapshotHostFile*(path: string): podman_types.HostFileSnapshot =
  result.path = path
  if path == "" or isStreamDestination(path):
    return
  try:
    if not fileExists(path) and not symlinkExists(path):
      return
    result.existed = true
    let info = getFileInfo(path, followSymlink = false)
    result.regular = info.kind == pcFile
    result.size = info.size
    let ts = info.lastWriteTime
    result.mtimeNs = ts.toUnix() * 1_000_000_000 + int64(ts.nanosecond)
    result.fileId = info.id
  except:
    result.existed = true
    result.regular = false

proc hostOutputFresh*(before, after: podman_types.HostFileSnapshot): bool =
  ## True when `after` shows the build wrote the file. An untouched
  ## pre-existing file is not evidence of generation.
  if not after.existed or not after.regular:
    return false
  if not before.existed:
    return true
  if before.fileId == after.fileId and
      before.mtimeNs == after.mtimeNs and
      before.size == after.size:
    return false
  return true

proc snapshotSbomHostOutputs*(outputs: podman_types.PodmanSbomNativeOutputs,
                              workingDir: string):
                             seq[podman_types.HostFileSnapshot] =
  if outputs.hostOutput == "":
    return @[]
  return @[snapshotHostFile(resolveAgainst(outputs.hostOutput, workingDir))]

proc requireSpdxString(node: JsonNode, field: string): bool =
  if node == nil or node.kind != JObject or not node.hasKey(field):
    return false
  if node[field].kind != JString:
    return false
  return node[field].getStr() != ""

proc parsePodmanSpdx*(bytes: string, sourceKind: podman_types.PodmanSbomSourceKind):
                     podman_types.PodmanSbomOutcome =
  if len(bytes) > maxPodmanSbomBytes:
    return diagnostic(pdkOversized, "SBOM document exceeds 32 MiB")
  var parsed: JsonNode
  try:
    parsed = parseJson(bytes)
  except:
    return diagnostic(pdkMalformed, "SBOM is not valid JSON")
  if parsed == nil or parsed.kind != JObject:
    return diagnostic(pdkMalformed, "SBOM is not a JSON object")
  if parsed{"bomFormat"}.getStr() == "CycloneDX":
    return diagnostic(pdkUnsupportedFormat, "CycloneDX is not collected for Podman")
  if not parsed.hasKey("spdxVersion") or parsed["spdxVersion"].kind != JString:
    return diagnostic(pdkUnsupportedFormat,
                      "document is not SPDX JSON 2.2 or 2.3")
  let version = parsed["spdxVersion"].getStr()
  if version notin ["SPDX-2.2", "SPDX-2.3"]:
    return diagnostic(pdkUnsupportedFormat, "unsupported SPDX version")
  for field in ["dataLicense", "SPDXID", "name", "documentNamespace"]:
    if not requireSpdxString(parsed, field):
      return diagnostic(pdkMalformed, "SPDX document is missing required fields")
  if not parsed.hasKey("creationInfo") or parsed["creationInfo"].kind != JObject:
    return diagnostic(pdkMalformed, "SPDX document is missing required fields")
  let created = parsed["creationInfo"]
  if not requireSpdxString(created, "created"):
    return diagnostic(pdkMalformed, "SPDX document is missing required fields")
  if not created.hasKey("creators") or created["creators"].kind != JArray or
      len(created["creators"]) == 0:
    return diagnostic(pdkMalformed, "SPDX document is missing required fields")
  for creator in created["creators"]:
    if creator.kind != JString or creator.getStr() == "":
      return diagnostic(pdkMalformed, "SPDX document is missing required fields")
  for field in ["packages", "files", "relationships", "snippets",
                "hasExtractedLicensingInfos", "documentDescribes"]:
    if parsed.hasKey(field) and parsed[field].kind != JArray:
      return diagnostic(pdkMalformed, "SPDX document is missing required fields")
  return documentOutcome(parsed, bytes, sourceKind)

proc readLimitedFile*(path: string, deadline: MonoTime):
                     podman_types.PodmanSbomOutcome =
  if timedOut(deadline):
    return diagnostic(pdkTimeout, "SBOM collection timed out")
  if isStreamDestination(path):
    return diagnostic(pdkStreamDestination,
                      "SBOM output is a stream and was not consumed")
  var st: Stat
  if lstat(cstring(path), st) != 0:
    return diagnostic(pdkMissing, "SBOM output is not a readable file")
  if not S_ISREG(st.st_mode):
    return diagnostic(pdkStreamDestination,
                      "SBOM output is not a regular file")
  if st.st_size > maxPodmanSbomBytes:
    return diagnostic(pdkOversized, "SBOM document exceeds 32 MiB")
  let fd = posix.open(cstring(path), O_RDONLY or O_NONBLOCK)
  if fd < 0:
    return diagnostic(pdkMissing, "SBOM output is not a readable file")
  try:
    var opened: Stat
    if fstat(fd, opened) != 0 or not S_ISREG(opened.st_mode):
      return diagnostic(pdkStreamDestination,
                        "SBOM output is not a regular file")
    if opened.st_size > maxPodmanSbomBytes:
      return diagnostic(pdkOversized, "SBOM document exceeds 32 MiB")
    var bytes = newString(int(max(0, opened.st_size)))
    var off = 0
    while off < len(bytes):
      if timedOut(deadline):
        return diagnostic(pdkTimeout, "SBOM collection timed out")
      let n = posix.read(fd, addr bytes[off], len(bytes) - off)
      if n < 0:
        if errno == EINTR:
          continue
        if errno == EAGAIN or errno == EWOULDBLOCK:
          return diagnostic(pdkStreamDestination,
                            "SBOM output is not a regular file")
        return diagnostic(pdkMissing, "SBOM output is not a readable file")
      if n == 0:
        break
      off += int(n)
      if off > maxPodmanSbomBytes:
        return diagnostic(pdkOversized, "SBOM document exceeds 32 MiB")
    bytes.setLen(off)
    if timedOut(deadline):
      return diagnostic(pdkTimeout, "SBOM collection timed out")
    return documentOutcome(newJNull(), bytes, pskNative)
  finally:
    discard posix.close(fd)

proc parseHandoff*(raw: string, handoffDir: string):
                  tuple[handoff: podman_types.PodmanSbomHandoff,
                        error: Option[podman_types.PodmanSbomDiagnostic]] =
  var parsed: JsonNode
  try:
    parsed = parseJson(raw)
  except:
    return (podman_types.PodmanSbomHandoff(), some(podman_types.PodmanSbomDiagnostic(
      kind: pdkMalformed, message: "handoff is not valid JSON")))
  if parsed == nil or parsed.kind != JObject:
    return (podman_types.PodmanSbomHandoff(), some(podman_types.PodmanSbomDiagnostic(
      kind: pdkMalformed, message: "handoff is not a JSON object")))
  if parsed{"version"}.getInt() != podmanSbomHandoffVersion:
    return (podman_types.PodmanSbomHandoff(), some(podman_types.PodmanSbomDiagnostic(
      kind: pdkHandoffVersion, message: "handoff version must be 1")))
  let
    path    = parsed{"path"}.getStr()
    sha256  = parsed{"sha256"}.getStr()
    imageId = parsed{"image_id"}.getStr()
  if path == "" or sha256 == "" or imageId == "":
    return (podman_types.PodmanSbomHandoff(), some(podman_types.PodmanSbomDiagnostic(
      kind: pdkMalformed,
      message: "handoff requires path, sha256, and image_id")))
  return (podman_types.PodmanSbomHandoff(
    version: podmanSbomHandoffVersion,
    path:    path,
    sha256:  sha256.toLowerAscii(),
    imageId: imageId,
    dir:     handoffDir,
  ), none(podman_types.PodmanSbomDiagnostic))

proc copyImagePath(exe, image, srcPath, destPath: string,
                   deadline: MonoTime,
                   cancellation: var Option[podman_types.ChildResult]):
                  podman_types.PodmanSbomOutcome =
  if timedOut(deadline):
    return diagnostic(pdkTimeout, "SBOM collection timed out")
  var containerId = ""
  let created = runCaptured(exe, @["create", image],
                            timeoutMs = remainingMs(deadline))
  containerId = created.stdout.strip()
  if created.child.timedOut:
    result = diagnostic(pdkTimeout, "SBOM collection timed out")
  elif isCancellation(created.child):
    cancellation = some(created.child)
    result = diagnostic(pdkCancelled, "SBOM collection was cancelled")
  elif created.child.kind != podman_types.ceExited or created.child.exitCode != 0 or
      containerId == "":
    result = diagnostic(pdkMissing, "could not create a container to read the image SBOM")
    containerId = created.stdout.strip()
  else:
    if timedOut(deadline):
      result = diagnostic(pdkTimeout, "SBOM collection timed out")
    else:
      let copied = runCaptured(exe, @["cp", containerId & ":" & srcPath, destPath],
                               timeoutMs = remainingMs(deadline))
      if copied.child.timedOut:
        result = diagnostic(pdkTimeout, "SBOM collection timed out")
      elif isCancellation(copied.child):
        cancellation = some(copied.child)
        result = diagnostic(pdkCancelled, "SBOM collection was cancelled")
      elif copied.child.kind != podman_types.ceExited or copied.child.exitCode != 0:
        result = diagnostic(pdkMissing, "image SBOM path was not found")
      else:
        result = readLimitedFile(destPath, deadline)
  if containerId != "":
    let removed = runCaptured(exe, @["rm", "--force", containerId],
                              timeoutMs = cleanupBudgetMs(deadline))
    if isCancellation(removed.child) and cancellation.isNone():
      cancellation = some(removed.child)
      if result.kind != psoDiagnostic or result.diagnostic.kind != pdkCancelled:
        result = diagnostic(pdkCancelled, "SBOM collection was cancelled")
    elif removed.child.kind != podman_types.ceExited or removed.child.exitCode != 0:
      trace("podman: could not remove SBOM scratch container")

proc collectNativePodmanSbom*(
  exe: string,
  imageRef: string,
  outputs: podman_types.PodmanSbomNativeOutputs,
  snapshots: seq[podman_types.HostFileSnapshot],
  workingDir: string,
  deadline: MonoTime,
  cancellation: var Option[podman_types.ChildResult],
): podman_types.PodmanSbomOutcome =
  if not hasNativeSbomDocument(outputs):
    return diagnostic(pdkMissing, "no native SBOM output path was declared")
  if timedOut(deadline):
    return diagnostic(pdkTimeout, "SBOM collection timed out")

  var hostBytes = none(string)
  if outputs.hostOutput != "":
    let hostPath = resolveAgainst(outputs.hostOutput, workingDir)
    if isStreamDestination(outputs.hostOutput) or isStreamDestination(hostPath):
      return diagnostic(pdkStreamDestination,
                        "SBOM host output is a stream and was not consumed")
    let after = snapshotHostFile(hostPath)
    var before = podman_types.HostFileSnapshot(path: hostPath)
    for snap in snapshots:
      if snap.path == hostPath:
        before = snap
        break
    if not after.existed:
      return diagnostic(pdkMissing, "native SBOM host output was not created")
    if not after.regular:
      return diagnostic(pdkStreamDestination,
                        "SBOM host output is not a regular file")
    if not hostOutputFresh(before, after):
      return diagnostic(pdkStale,
                        "native SBOM host output was not written by the build")
    let read = readLimitedFile(hostPath, deadline)
    if read.kind == psoDiagnostic:
      return read
    let afterRead = snapshotHostFile(hostPath)
    if afterRead.fileId != after.fileId or afterRead.size != after.size or
        afterRead.mtimeNs != after.mtimeNs:
      return diagnostic(pdkChanging, "native SBOM host output changed while it was read")
    hostBytes = some(read.document.sourceBytes)

  var imageBytes = none(string)
  if outputs.imageOutput != "":
    if outputs.imageOutput.startsWith("-") or isStreamDestination(outputs.imageOutput):
      return diagnostic(pdkStreamDestination,
                        "SBOM image output is a stream and was not consumed")
    let (tmpStream, tmpPath) = getNewTempFile(suffix = "sbom.spdx.json")
    tmpStream.close()
    try:
      let copied = copyImagePath(exe, imageRef, outputs.imageOutput, tmpPath,
                                 deadline, cancellation)
      if cancellation.isSome():
        return copied
      if copied.kind == psoDiagnostic:
        if hostBytes.isNone():
          return copied
        return diagnostic(pdkInconsistent,
                          "native SBOM image output could not be read")
      imageBytes = some(copied.document.sourceBytes)
    finally:
      try:
        removeFile(tmpPath)
      except:
        discard

  if hostBytes.isSome() and imageBytes.isSome():
    if hostBytes.get() != imageBytes.get():
      return diagnostic(pdkInconsistent,
                        "native SBOM host and image outputs differ")
    return parsePodmanSpdx(hostBytes.get(), pskNative)
  if hostBytes.isSome():
    return parsePodmanSpdx(hostBytes.get(), pskNative)
  if imageBytes.isSome():
    return parsePodmanSpdx(imageBytes.get(), pskNative)
  return diagnostic(pdkMissing, "native SBOM output was not collected")

proc collectHandoffPodmanSbom*(handoffPath, localImageId: string,
                               deadline: MonoTime):
                              podman_types.PodmanSbomOutcome =
  if timedOut(deadline):
    return diagnostic(pdkTimeout, "SBOM collection timed out")
  if handoffPath == "":
    return diagnostic(pdkMissing, "no SBOM handoff was provided")
  let absolute = absolutePath(handoffPath)
  let handoffRead = readLimitedFile(absolute, deadline)
  if handoffRead.kind == psoDiagnostic:
    if handoffRead.diagnostic.kind == pdkStreamDestination:
      return diagnostic(pdkStreamDestination,
                        "handoff SBOM path is a stream and was not consumed")
    if handoffRead.diagnostic.kind in {pdkTimeout, pdkOversized}:
      return handoffRead
    return diagnostic(pdkMissing, "could not read SBOM handoff")
  let parsed = parseHandoff(handoffRead.document.sourceBytes, parentDir(absolute))
  if parsed.error.isSome():
    return podman_types.PodmanSbomOutcome(
      kind:       psoDiagnostic,
      diagnostic: parsed.error.get(),
    )
  let handoff = parsed.handoff
  if not sameImageId(handoff.imageId, localImageId):
    return diagnostic(pdkHandoffImage,
                      "handoff image_id does not match the local image")
  let docPath = resolveAgainst(handoff.path, handoff.dir)
  if isStreamDestination(docPath):
    return diagnostic(pdkStreamDestination,
                      "handoff SBOM path is a stream and was not consumed")
  let read = readLimitedFile(docPath, deadline)
  if read.kind == psoDiagnostic:
    return read
  let actual = read.document.sourceBytes.sha256Hex()
  if normalizeDigest("sha256:" & actual) != normalizeDigest(handoff.sha256):
    return diagnostic(pdkHandoffChecksum,
                      "handoff sha256 does not match the document")
  return parsePodmanSpdx(read.document.sourceBytes, pskHandoff)

type
  PodmanSbomAttachmentCandidate* = object
    digest*:         string
    mediaType*:      string
    artifactType*:   string
    subjectDigest*:  string
    layerDigest*:    string
    layerMediaType*: string
    layerSize*:      int

proc candidateMatchesSpdx*(candidate: PodmanSbomAttachmentCandidate,
                           subjectDigest: string): bool =
  if normalizeDigest(candidate.subjectDigest) != normalizeDigest(subjectDigest):
    return false
  if candidate.layerMediaType != spdxJsonMediaType:
    return false
  if candidate.layerDigest == "":
    return false
  return true

proc selectSpdxAttachment*(
  matching: seq[PodmanSbomAttachmentCandidate],
  explicitDigest: string,
): tuple[selected: Option[PodmanSbomAttachmentCandidate],
         error: Option[podman_types.PodmanSbomDiagnostic]] =
  if explicitDigest != "":
    let wanted = normalizeDigest(explicitDigest)
    for item in matching:
      if normalizeDigest(item.digest) == wanted:
        return (some(item), none(podman_types.PodmanSbomDiagnostic))
    return (none(PodmanSbomAttachmentCandidate), some(podman_types.PodmanSbomDiagnostic(
      kind: pdkAttachmentAbsent,
      message: "requested SBOM attachment was not found",
    )))
  if len(matching) == 0:
    return (none(PodmanSbomAttachmentCandidate), some(podman_types.PodmanSbomDiagnostic(
      kind: pdkAttachmentAbsent,
      message: "no application/spdx+json attachment was found",
    )))
  if len(matching) > 1:
    return (none(PodmanSbomAttachmentCandidate), some(podman_types.PodmanSbomDiagnostic(
      kind: pdkAttachmentAmbiguous,
      message: "multiple SPDX attachments exist; pass --sbom-attachment",
    )))
  return (some(matching[0]), none(podman_types.PodmanSbomDiagnostic))

proc spdxLayers(manifest: JsonNode): seq[JsonNode] =
  result = @[]
  if manifest == nil or manifest.kind != JObject:
    return
  for layer in manifest{"layers"}.getElems():
    if layer.kind == JObject and layer{"mediaType"}.getStr() == spdxJsonMediaType:
      result.add(layer)

proc describeCandidate(manifest: JsonNode, digest, mediaType: string):
                       Option[PodmanSbomAttachmentCandidate] =
  let layers = spdxLayers(manifest)
  if len(layers) != 1:
    return none(PodmanSbomAttachmentCandidate)
  let layer = layers[0]
  let layerDigest = normalizeDigest(layer{"digest"}.getStr())
  if layerDigest == "":
    return none(PodmanSbomAttachmentCandidate)
  return some(PodmanSbomAttachmentCandidate(
    digest:         normalizeDigest(digest),
    mediaType:      mediaType,
    artifactType:   manifest{"artifactType"}.getStr(),
    subjectDigest:  normalizeDigest(manifest{"subject"}{"digest"}.getStr()),
    layerDigest:    layerDigest,
    layerMediaType: spdxJsonMediaType,
    layerSize:      layer{"size"}.getInt(),
  ))

proc fetchReferrerIndex(image: DockerImage): JsonNode =
  let referrers = referrersGet(image)
  if referrers != nil and referrers.json != nil:
    return referrers.json
  let tagged = manifestGet(image.asOciAttestation(), ociIndexMediaType)
  if tagged.json == nil or tagged.json.kind != JObject:
    return nil
  let mediaType = tagged.json{"mediaType"}.getStr()
  if mediaType != "" and mediaType != ociIndexMediaType:
    raise newException(RegistryResponseError, "referrer index has the wrong media type")
  return tagged.json

proc registryCollectionFailure(): podman_types.PodmanSbomOutcome =
  let msg = getCurrentExceptionMsg()
  if msg == "request timed out" or msg == "registry request timed out":
    return diagnostic(pdkTimeout, "SBOM collection timed out")
  if msg == "referrer pagination left the registry origin":
    return diagnostic(pdkAttachmentMismatch,
                      "referrer pagination left the registry origin")
  if msg == "referrer pagination repeated a page":
    return diagnostic(pdkAttachmentMismatch, "referrer pagination repeated a page")
  if msg == "referrer pagination is incomplete":
    return diagnostic(pdkAttachmentMismatch, "referrer pagination is incomplete")
  if msg == "referrer index has the wrong media type":
    return diagnostic(pdkAttachmentMismatch, "referrer index has the wrong media type")
  if "401" in msg or "403" in msg or "Unauthorized" in msg:
    return diagnostic(pdkAuthFailure, "registry authentication failed")
  return diagnostic(pdkAttachmentAbsent, "registry request failed")

proc collectAttachmentPodmanSbom*(
  localImageId: string,
  registryReference: string,
  authFile: string,
  attachmentDigest: string,
  deadline: MonoTime,
  publication: var Option[podman_types.PodmanPublication],
): podman_types.PodmanSbomOutcome =
  publication = none(podman_types.PodmanPublication)
  if timedOut(deadline):
    return diagnostic(pdkTimeout, "SBOM collection timed out")
  let parsedRefOpt = parsePodmanRegistryReference(registryReference)
  if parsedRefOpt.isNone():
    return diagnostic(pdkMalformed,
                      "registry reference must be repository@sha256:digest")
  let parsedRef = parsedRefOpt.get()
  let requested = parseSha256Digest(parsedRef.digest)
  if requested == "":
    return diagnostic(pdkMalformed,
                      "registry reference must be repository@sha256:digest")
  if attachmentDigest != "" and parseSha256Digest(attachmentDigest) == "":
    return diagnostic(pdkMalformed, "attachment digest must be a sha256 digest")
  let access = newAuthFileRegistryAccess(authFile)
  access.deadline = some(deadline)
  access.timeoutMs = max(1, remainingMs(deadline))
  try:
    withRegistryAccess(access):
      if timedOut(deadline):
        return diagnostic(pdkTimeout, "SBOM collection timed out")
      let
        accept = ociManifestMediaType & ", " & dockerManifestMediaType
        data   = manifestGet(parsedRef.withDigest(requested), accept)
      if parseSha256Digest(data.digest) != requested:
        return diagnostic(pdkAttachmentMismatch,
                          "fetched manifest digest does not match the registry reference")
      if data.json == nil or data.json.kind != JObject:
        return diagnostic(pdkAttachmentMismatch,
                          "fetched manifest digest does not match the registry reference")
      let manifestMedia = data.json{"mediaType"}.getStr()
      if manifestMedia != "" and manifestMedia notin [
          ociManifestMediaType, dockerManifestMediaType]:
        return diagnostic(pdkAttachmentMismatch,
                          "application manifest has the wrong media type")
      let config = data.json{"config"}
      if config == nil or config.kind != JObject:
        return diagnostic(pdkAttachmentMismatch,
                          "registry manifest config digest does not match the local image")
      let configDigest = parseSha256Digest(config{"digest"}.getStr())
      if configDigest == "" or not sameImageId(configDigest, localImageId):
        return diagnostic(pdkAttachmentMismatch,
                          "registry manifest config digest does not match the local image")
      publication = some(podman_types.PodmanPublication(
        reference:   parsedRef.normalize(),
        imageDigest: requested,
        listDigest:  "",
      ))
      let subjectDigest = requested
      let index = fetchReferrerIndex(parsedRef.withDigest(subjectDigest))
      if index == nil:
        return diagnostic(pdkAttachmentAbsent,
                          "registry has no SPDX referrers for this image")
      let indexMedia = index{"mediaType"}.getStr()
      if indexMedia != "" and indexMedia != ociIndexMediaType:
        return diagnostic(pdkAttachmentMismatch,
                          "referrer index has the wrong media type")
      var matching: seq[PodmanSbomAttachmentCandidate]
      for item in index{"manifests"}.getElems():
        if timedOut(deadline):
          return diagnostic(pdkTimeout, "SBOM collection timed out")
        if item.kind != JObject:
          continue
        let itemDigest = parseSha256Digest(item{"digest"}.getStr())
        let itemMedia  = item{"mediaType"}.getStr()
        if itemDigest == "":
          continue
        if itemMedia != "" and itemMedia != ociManifestMediaType:
          continue
        var fetched: DockerDigestedJson
        try:
          fetched = manifestGet(
            parsedRef.withBare().withDigest(itemDigest),
            if itemMedia != "": itemMedia else: ociManifestMediaType,
          )
        except RegistryTimeoutError:
          return diagnostic(pdkTimeout, "SBOM collection timed out")
        except RegistryResponseError:
          let fail = registryCollectionFailure()
          if fail.diagnostic.kind in {pdkTimeout, pdkAuthFailure}:
            return fail
          continue
        except:
          continue
        if parseSha256Digest(fetched.digest) != itemDigest:
          continue
        let layers = spdxLayers(fetched.json)
        if len(layers) > 1:
          if attachmentDigest != "" and
              parseSha256Digest(attachmentDigest) == itemDigest:
            return diagnostic(pdkAttachmentMismatch,
                              "attachment has more than one application/spdx+json layer")
          continue
        let candidate = describeCandidate(fetched.json, fetched.digest,
                                          fetched.json{"mediaType"}.getStr())
        if candidate.isNone():
          continue
        if candidateMatchesSpdx(candidate.get(), subjectDigest):
          matching.add(candidate.get())
      let selected = selectSpdxAttachment(matching, attachmentDigest)
      if selected.error.isSome():
        return podman_types.PodmanSbomOutcome(
          kind:       psoDiagnostic,
          diagnostic: selected.error.get(),
        )
      let attachment = selected.selected.get()
      if attachment.layerDigest == "" or attachment.layerMediaType != spdxJsonMediaType:
        return diagnostic(pdkAttachmentMismatch,
                          "attachment does not contain an application/spdx+json layer")
      if timedOut(deadline):
        return diagnostic(pdkTimeout, "SBOM collection timed out")
      var blob: string
      try:
        blob = parsedRef.withBare().withDigest(attachment.layerDigest).layerGetString(
          attachment.layerMediaType,
        )
      except RegistryTimeoutError:
        return diagnostic(pdkTimeout, "SBOM collection timed out")
      except RegistryResponseError:
        return registryCollectionFailure()
      except:
        return diagnostic(pdkAttachmentMismatch, "could not download the SBOM blob")
      if len(blob) > maxPodmanSbomBytes:
        return diagnostic(pdkOversized, "SBOM document exceeds 32 MiB")
      if attachment.layerSize > 0 and len(blob) != attachment.layerSize:
        return diagnostic(pdkAttachmentMismatch,
                          "SBOM blob size does not match the layer")
      if parseSha256Digest("sha256:" & blob.sha256Hex()) != attachment.layerDigest:
        return diagnostic(pdkAttachmentMismatch, "SBOM blob digest does not match the layer")
      return parsePodmanSpdx(blob, pskAttachment)
  except RegistryTimeoutError:
    return diagnostic(pdkTimeout, "SBOM collection timed out")
  except RegistryResponseError:
    return registryCollectionFailure()
  except:
    if timedOut(deadline):
      return diagnostic(pdkTimeout, "SBOM collection timed out")
    return diagnostic(pdkOther, "SBOM attachment collection failed")

proc collectAttachmentPodmanSbom*(
  localImageId: string,
  registryReference: string,
  authFile: string,
  attachmentDigest: string,
  deadline: MonoTime,
): podman_types.PodmanSbomOutcome =
  var publication = none(podman_types.PodmanPublication)
  return collectAttachmentPodmanSbom(
    localImageId, registryReference, authFile, attachmentDigest, deadline,
    publication,
  )

proc ensurePodmanCache(chalk: ChalkObj): podman_types.PodmanArtifactCache =
  if chalk.cache == nil:
    chalk.cache = RootRef(podman_types.PodmanArtifactCache())
  return podman_types.PodmanArtifactCache(chalk.cache)

proc applyPodmanSbom*(chalk: ChalkObj, outcome: podman_types.PodmanSbomOutcome) =
  let cache = ensurePodmanCache(chalk)
  case outcome.kind
  of psoDocument:
    cache.sbom = some(outcome.document)
    cache.sbomDiagnostic = none(podman_types.PodmanSbomDiagnostic)
    chalk.setIfNeeded("_IMAGE_SBOM", outcome.document.parsed)
  of psoDiagnostic:
    cache.sbom = none(podman_types.PodmanSbomDocument)
    cache.sbomDiagnostic = some(outcome.diagnostic)
    warn("podman: " & outcome.diagnostic.message)
    addFailedKey(
      "_IMAGE_SBOM",
      code        = failedKeyCode(outcome.diagnostic.kind),
      error       = outcome.diagnostic.message,
      description = "Collecting a customer-generated Podman SPDX document failed",
    )

proc maybeCollectNativeSbom*(
  exe: string,
  spec: podman_types.PodmanBuildSpec,
  chalk: ChalkObj,
  snapshots: seq[podman_types.HostFileSnapshot],
  workingDir: string,
  cancellation: var Option[podman_types.ChildResult],
) =
  if not isSubscribedKey("_IMAGE_SBOM"):
    return
  if not hasNativeSbomDocument(spec.sbom):
    return
  let imageRef =
    if chalk.imageId != "": chalk.imageId
    elif primaryTag(spec) != "": primaryTag(spec)
    else: ""
  if imageRef == "":
    applyPodmanSbom(chalk, diagnostic(pdkMissing, "built image id is unavailable"))
    return
  let deadline = getMonoTime() + initDuration(milliseconds = podmanSbomTimeoutMs)
  let outcome = collectNativePodmanSbom(
    exe, imageRef, spec.sbom, snapshots, workingDir, deadline, cancellation,
  )
  applyPodmanSbom(chalk, outcome)

proc hasExistingPodmanIdentity*(chalk: ChalkObj): bool =
  if chalk == nil or not chalk.isChalked():
    return false
  for key in ["CHALK_ID", "METADATA_ID"]:
    if key notin chalk.extract:
      return false
    if chalk.extract[key].kind != MkStr or
        unpack[string](chalk.extract[key]) == "":
      return false
  return true

proc maybeCollectHandoffSbom*(
  handoffPath: string,
  chalk: ChalkObj,
  localImageId: string,
) =
  if handoffPath == "":
    return
  if not isSubscribedKey("_IMAGE_SBOM"):
    return
  if not hasExistingPodmanIdentity(chalk):
    applyPodmanSbom(chalk, diagnostic(pdkHandoffImage,
      "SBOM handoff requires an existing image build identity"))
    return
  let deadline = getMonoTime() + initDuration(milliseconds = podmanSbomTimeoutMs)
  applyPodmanSbom(chalk, collectHandoffPodmanSbom(handoffPath, localImageId, deadline))

proc collectExtractAttachmentSbom*(
  chalk: ChalkObj,
  localImageId: string,
  registryReference: string,
  authFile: string,
  attachmentDigest: string,
) =
  if not isSubscribedKey("_IMAGE_SBOM"):
    return
  if not hasExistingPodmanIdentity(chalk):
    applyPodmanSbom(chalk, diagnostic(pdkAttachmentMismatch,
      "SBOM extraction requires an existing image build identity"))
    return
  let deadline = getMonoTime() + initDuration(milliseconds = podmanSbomTimeoutMs)
  var publication = none(podman_types.PodmanPublication)
  let outcome = collectAttachmentPodmanSbom(
    localImageId, registryReference, authFile, attachmentDigest, deadline,
    publication,
  )
  if publication.isSome() and chalk.isChalked():
    ensurePodmanCache(chalk).publications.add(publication.get())
  applyPodmanSbom(chalk, outcome)

proc runPodmanExtractSbom*() =
  let
    image              = attrGetOpt[string]("extract.podman_image").get("")
    registryReference  = attrGetOpt[string]("extract.podman_registry_reference").get("")
    authFile           = attrGetOpt[string]("extract.podman_authfile").get("")
    attachmentDigest   = attrGetOpt[string]("extract.podman_sbom_attachment").get("")
  if image == "" or registryReference == "":
    error("chalk extract podman requires --image and --registry-reference")
    quitChalkWithStatus(1)
  if parsePodmanRegistryReference(registryReference).isNone():
    error("chalk extract podman --registry-reference must be repository@sha256:digest")
    quitChalkWithStatus(1)
  if attachmentDigest != "" and parseSha256Digest(attachmentDigest) == "":
    error("chalk extract podman --sbom-attachment must be a sha256 digest")
    quitChalkWithStatus(1)

  setFullCommandName("extract")
  let exe = resolvePodmanExe()
  initCollection()
  var cancellation = none(podman_types.ChildResult)
  let chalkOpt =
    if exe == "": none(ChalkObj)
    else: scanPodmanImage(exe, image, cancellation)
  if cancellation.isSome():
    quitChalkWithStatus(cancellationExit(cancellation.get()))
  if chalkOpt.isNone():
    warn("podman: " & image & " cannot be extracted")
    try:
      doReporting()
    except:
      error("podman extract: " & getCurrentExceptionMsg())
    return

  let chalk = chalkOpt.get()
  chalk.withErrorContext():
    if not chalk.isChalked():
      warn("podman: " & chalk.name &
           " is not chalked. reporting will be limited")
      suspendChalkCollectionFor("attestation")
    collectExtractAttachmentSbom(
      chalk, chalk.imageId, registryReference, authFile, attachmentDigest,
    )
    chalk.addToAllChalks()
    chalk.collectedData["_OP_ARTIFACT_CONTEXT"] = pack("extract")
    collectRunTimeArtifactInfo(chalk)
    collectRunTimeHostInfo()
    try:
      doReporting()
    except:
      error("podman extract: " & getCurrentExceptionMsg())
