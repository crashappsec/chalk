##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
  strutils,
]
import ".."/[
  types,
  utils/files,
  utils/json,
  utils/sets,
]
import "../docker"/[
  dockerfile,
]
import "./binding"
import "./notice"
import "./types" as podman_types

type
  PodmanContainerfileSelectionKind* = enum
    pcsSelected, pcsRefused

  PodmanContainerfileSelection* = object
    case kind*: PodmanContainerfileSelectionKind
    of pcsSelected:
      path*: string
    of pcsRefused:
      reason*: PodmanSkipReason

  PodmanInputResultKind* = enum
    pirResolved, pirRefused

  PodmanInputResult* = object
    case kind*: PodmanInputResultKind
    of pirResolved:
      spec*: podman_types.PodmanBuildSpec
    of pirRefused:
      reason*: PodmanSkipReason

proc refusedInput(kind: PodmanSkipReasonKind): PodmanInputResult =
  return PodmanInputResult(
    kind:   pirRefused,
    reason: PodmanSkipReason(kind: kind),
  )

proc refusedContainerfile(issue: ContainerfileIssue): PodmanInputResult =
  return PodmanInputResult(
    kind: pirRefused,
    reason: PodmanSkipReason(
      kind:  psrContainerfileIssue,
      issue: issue,
    ),
  )

proc selectedContainerfile(path: string): PodmanContainerfileSelection =
  return PodmanContainerfileSelection(kind: pcsSelected, path: path)

proc refusedContainerfileSelection(kind: PodmanSkipReasonKind):
                                   PodmanContainerfileSelection =
  return PodmanContainerfileSelection(
    kind:   pcsRefused,
    reason: PodmanSkipReason(kind: kind),
  )

proc namedContextReplacesBase*(contextNames, chainRefs: seq[string],
                               selectedAlias: string): bool =
  for name in contextNames:
    if name == "scratch":
      continue
    for reference in chainRefs:
      if reference == "scratch":
        continue
      if name == reference:
        return true
    if selectedAlias != "" and name == selectedAlias:
      return true
  return false

proc isLinuxAmd64Elf(path: string): bool =
  var f: File
  if not f.open(path):
    return false
  try:
    var hdr: array[20, char]
    if f.readBuffer(addr hdr[0], 20) != 20:
      return false
    if hdr[0] != '\x7f' or hdr[1] != 'E' or hdr[2] != 'L' or hdr[3] != 'F':
      return false
    if hdr[4] != '\x02':
      return false
    if hdr[18] != '\x3e' or hdr[19] != '\x00':
      return false
    return true
  finally:
    f.close()

proc canonicalChild(filePath, contextPath: string): bool =
  if filePath == contextPath:
    return false
  let prefix =
    if contextPath.endsWith($DirSep): contextPath
    else: contextPath & $DirSep
  return filePath.startsWith(prefix)

proc underCanonicalContext(filePath, contextPath: string): bool =
  let
    contextCanon = normalizedPath(expandFilename(contextPath))
    fileCanon    = normalizedPath(expandFilename(filePath))
  return canonicalChild(fileCanon, contextCanon)

proc hasContainerfileIgnore(path: string): bool =
  for suffix in [".containerignore", ".dockerignore"]:
    let sidecar = path & suffix
    if fileExists(sidecar) or dirExists(sidecar):
      return true
  return false

const podmanDefaultContainerfiles = ["Containerfile", "Dockerfile"]

proc validatedContainerfile(contextArg, candidate, sidecarProbe: string):
                           PodmanContainerfileSelection =
  ## Shared tail of containerfile selection. The candidate must be a real file
  ## inside the context and must not be excluded by a Containerfile-specific
  ## ignore sidecar, under either the name as written or its canonical path.
  if dirExists(candidate) or not fileExists(candidate):
    return refusedContainerfileSelection(psrContainerfileUnavailable)
  if sidecarProbe != "" and hasContainerfileIgnore(sidecarProbe):
    return refusedContainerfileSelection(psrContainerfileIgnoreUnsupported)
  if hasContainerfileIgnore(candidate):
    return refusedContainerfileSelection(psrContainerfileIgnoreUnsupported)
  if not underCanonicalContext(candidate, contextArg):
    return refusedContainerfileSelection(psrContainerfileOutsideContext)
  let canonical = normalizedPath(expandFilename(candidate))
  if hasContainerfileIgnore(canonical):
    return refusedContainerfileSelection(psrContainerfileIgnoreUnsupported)
  return selectedContainerfile(canonical)

proc selectPodmanContainerfile*(contextArg, containerfileArg: string):
                               PodmanContainerfileSelection =
  try:
    if containerfileArg == "":
      # No --file was given. Podman probes Containerfile then Dockerfile in the
      # context root, so resolve the same names in the same order, and strictly
      # against the context: unlike an explicit --file, an implied name is never
      # interpreted relative to the current directory.
      for name in podmanDefaultContainerfiles:
        let candidate = contextArg / name
        if dirExists(candidate) or not fileExists(candidate):
          # Not a file podman would pick either; try the next name.
          continue
        # Existence alone decides which file podman builds, so this is the one.
        # If it fails validation we pass the build through untouched -- falling
        # through to the next name would instrument a file podman would not
        # have built.
        return validatedContainerfile(contextArg, candidate, candidate)
      return refusedContainerfileSelection(psrContainerfileUnavailable)
    let
      candidate =
        if containerfileArg.isAbsolute() or fileExists(containerfileArg) or
            dirExists(containerfileArg):
          containerfileArg
        else:
          contextArg / containerfileArg
      sidecarProbe =
        if containerfileArg.isAbsolute():
          ""
        else:
          contextArg / containerfileArg
    return validatedContainerfile(contextArg, candidate, sidecarProbe)
  except:
    return refusedContainerfileSelection(psrContextUnavailable)

proc resolvePodmanInputs*(spec: podman_types.PodmanBuildSpec,
                          chalkPath = getMyAppPath()):
                         PodmanInputResult =
  var contextExists = false
  try:
    contextExists = dirExists(spec.contextArg)
  except:
    discard
  if not contextExists:
    return refusedInput(psrContextUnavailable)

  let selection = selectPodmanContainerfile(spec.contextArg,
                                             spec.containerfileArg)
  if selection.kind == pcsRefused:
    return PodmanInputResult(kind: pirRefused, reason: selection.reason)
  let containerfile = selection.path

  try:
    if not isLinuxAmd64Elf(chalkPath):
      return refusedInput(psrBinaryIncompatible)
  except:
    return refusedInput(psrBinaryIncompatible)

  var text: string
  try:
    text = readFile(containerfile)
  except:
    return refusedInput(psrContainerfileUnreadable)

  var config: FinalExecConfig
  try:
    let parsed = getFinalExecConfig(text, spec.target)
    if parsed.config.isNone() or len(parsed.errors) > 0:
      let issue = parsed.issue.get(ContainerfileIssue(kind: cfikSyntax))
      return refusedContainerfile(issue)
    config = parsed.config.get()
  except:
    return refusedContainerfile(ContainerfileIssue(kind: cfikSyntax))

  if namedContextReplacesBase(spec.contextNames, config.chainRefs,
                              config.stageAlias):
    return PodmanInputResult(
      kind: pirRefused,
      reason: PodmanSkipReason(
        kind: psrInvalidFlag,
        flag: safeFlagName("--build-context"),
      ),
    )

  var resolvedContext: string
  try:
    resolvedContext = normalizedPath(expandFilename(spec.contextArg))
  except:
    return refusedInput(psrContextUnavailable)

  var filled = spec
  filled.resolvedContext       = resolvedContext
  filled.resolvedContainerfile = containerfile
  filled.containerfileText     = text
  filled.startup               = config
  return PodmanInputResult(kind: pirResolved, spec: filled)

proc formatPodmanChalkExec(entrypoint: JsonNode): string =
  var arr = newJArray()
  arr.add(%"/chalk")
  arr.add(%"exec")
  arr.add(%"--heartbeat")
  if entrypoint != nil and entrypoint.kind == JArray and len(entrypoint) > 0:
    arr.add(%"--exec-command-name")
    arr.add(entrypoint[0])
    arr.add(%"--")
    if len(entrypoint) > 1:
      for item in entrypoint[1 .. ^1]:
        arr.add(item)
  else:
    arr.add(%"--")
  return $arr

proc unusedContextName*(reserved: HashSet[string],
                        draw: proc (): uint64 = nil): string =
  var lowered = initHashSet[string]()
  for name in reserved:
    lowered.incl(name.toLowerAscii())
  var i = 0
  while i < 32:
    let n = if draw != nil: draw() else: secureRand[uint64]()
    result = "chalk_" & n.toHex().toLowerAscii()
    if result notin lowered:
      return
    inc i
  raise newException(ValueError, "named context collision")

proc chalkInstructionBlock(spec: podman_types.PodmanBuildSpec,
                           contextName: string): string =
  let plan = spec.startupPlan.get()
  # A usable /bin/sh and unoccupied reserved paths are part of the supported
  # instrumentation envelope. Failure here makes the caller retry unchanged.
  #
  # This test needs no network, but podman sets up a network namespace for
  # every RUN, and in restricted CI containers that setup is what fails --
  # pasta exits 127 and the injected build dies before the test ever runs.
  # Opting out per-instruction cannot affect RUN steps in the customer's own
  # Containerfile, unlike a build-wide --network=none. Gated on the buildah
  # version because an older parser would reject the flag outright.
  let guardFlags = if spec.guardNoNetwork: "--network=none " else: ""
  # Reserved paths must be free, OR already hold a chalk mark of ours -- which
  # is what a chalked base image looks like, and re-chalking a derived image is
  # legitimate. Discriminating on content rather than existence keeps the
  # protection that matters (a customer application living at /chalk, which is
  # what this guard was added for) while no longer refusing to build on top of
  # our own output. Symlinks are refused either way; the common fresh-image
  # case short-circuits before grep is ever needed.
  result =
    "RUN " & guardFlags & "[\"/bin/sh\", \"-c\", \"test -x / && " &
    "test ! -L /chalk && test ! -L /chalk.json && " &
    "{ { test ! -e /chalk && test ! -e /chalk.json; } || " &
    "grep -q " & magicUTF8 & " /chalk.json; }\"]\n"
  result.add("COPY --from=" & contextName & " --chmod=0755 chalk /chalk\n")
  result.add("COPY --from=" & contextName & " --chmod=0444 chalk.json /chalk.json\n")
  # An entrypoint that is already `/chalk exec ...` came from a chalked base
  # image; re-wrapping it would make chalk exec chalk. The binary and mark
  # above are still refreshed, which is what re-chalking a derived image means.
  if not plan.alreadyWrapped:
    result.add("ENTRYPOINT " & formatPodmanChalkExec(plan.entrypoint) & "\n")
    # Setting ENTRYPOINT discards a CMD inherited from the base image, so it is
    # restated. Not restated when the selected stage declared its own CMD, which
    # is already present above -- matching docker/entrypoint.nim.
    if plan.emitCmd:
      result.add("CMD " & $plan.cmd & "\n")

proc derivedContainerfile(spec: podman_types.PodmanBuildSpec,
                          contextName: string): Option[string] =
  if spec.startupPlan.isNone():
    return none(string)
  let binding = spec.startupPlan.get().binding
  if not binding.validBinding():
    return none(string)

  let blockText = chalkInstructionBlock(spec, contextName)
  var derived: string
  if spec.startup.injectAt.isNone():
    derived = spec.containerfileText
    if len(derived) == 0 or derived[^1] != '\n':
      derived.add('\n')
    derived.add(blockText)
  else:
    let offset = spec.startup.injectAt.get()
    if offset < 0 or offset > len(spec.containerfileText):
      return none(string)
    let suffix =
      if offset < len(spec.containerfileText):
        spec.containerfileText[offset .. ^1]
      else:
        ""
    derived = spec.containerfileText[0 ..< offset] & blockText & suffix

  case binding.kind
  of bbScratch:
    if spec.startup.rootImage != "scratch":
      return none(string)
  of bbConfigId, bbRegistryDigest:
    if spec.startup.rootImage == "scratch" or
        spec.startup.rootImageSpan.isNone():
      return none(string)
    let span = spec.startup.rootImageSpan.get()
    if span.start < 0 or span.stop <= span.start or
        span.stop > len(spec.containerfileText) or
        spec.containerfileText[span.start ..< span.stop] !=
          spec.startup.rootImage or
        (spec.startup.injectAt.isSome() and
         span.stop > spec.startup.injectAt.get()):
      return none(string)
    let suffix =
      if span.stop < len(derived): derived[span.stop .. ^1]
      else: ""
    derived = derived[0 ..< span.start] & binding.operand() & suffix
  of bbUnbound:
    return none(string)
  return some(derived)

proc externalPodmanTempBase(contextPath: string): Option[string] =
  let contextCanon = normalizedPath(expandFilename(contextPath))
  when defined(posix):
    let candidates = ["/tmp", "/var/tmp"]
  else:
    let candidates = [getTempDir()]
  for candidate in candidates:
    if not dirExists(candidate):
      continue
    let baseCanon = normalizedPath(expandFilename(candidate))
    if baseCanon == contextCanon or canonicalChild(baseCanon, contextCanon):
      continue
    return some(baseCanon)
  return none(string)

proc preparePodmanBuild*(spec: podman_types.PodmanBuildSpec):
                        Option[podman_types.PodmanWorkspace] =
  try:
    if spec.startupPlan.isNone():
      return none(podman_types.PodmanWorkspace)
    let base = externalPodmanTempBase(spec.resolvedContext)
    if base.isNone():
      return none(podman_types.PodmanWorkspace)
    var reserved = spec.startup.stageAliases
    for name in spec.contextNames:
      reserved.incl(name)
    let
      contextName = unusedContextName(reserved)
      textOpt     = derivedContainerfile(spec, contextName)
    if textOpt.isNone():
      return none(podman_types.PodmanWorkspace)
    let
      root        = createTempDir("chalk-podman-", "", base.get())
      assets      = root / "assets"
      derived     = root / "Containerfile.chalk"
      ownsIidFile = spec.customerIidFile == ""
      iidFile     =
        if ownsIidFile: root / "image.iid"
        else: spec.customerIidFile
      chalkBin    = assets / "chalk"
      text        = textOpt.get()
    discard chmodFilePermissions(root, "0700")
    if underCanonicalContext(root, spec.resolvedContext):
      removeDir(root)
      return none(podman_types.PodmanWorkspace)
    registerTmpDir(root)
    createDir(assets)
    copyFile(getMyAppPath(), chalkBin)
    discard chmodFilePermissions(chalkBin, "0755")
    writeFile(derived, text)
    return some(podman_types.PodmanWorkspace(
      root:                 root,
      assetContext:         assets,
      derivedContainerfile: derived,
      iidFile:              iidFile,
      contextName:          contextName,
      derivedText:          text,
    ))
  except:
    return none(podman_types.PodmanWorkspace)

proc makeInjectedArgs*(spec: podman_types.PodmanBuildSpec;
                       ws: podman_types.PodmanWorkspace): seq[string] =
  result = spec.originalArgs
  var extras: seq[string]
  if spec.fileValueIndex >= 0:
    if spec.fileEqualsPrefix != "":
      result[spec.fileValueIndex] = spec.fileEqualsPrefix & ws.derivedContainerfile
    else:
      result[spec.fileValueIndex] = ws.derivedContainerfile
  else:
    # The original command relied on podman's own containerfile lookup, so
    # there is no argument to rewrite -- fileValueIndex is -1. Name the derived
    # containerfile explicitly instead.
    extras.add(@["--file", ws.derivedContainerfile])
  extras.add(@[
    "--build-context",
    ws.contextName & "=" & ws.assetContext,
  ])
  if spec.customerIidFile == "":
    extras.add(@["--iidfile", ws.iidFile])
  if spec.dashDashIndex >= 0:
    result = result[0 ..< spec.dashDashIndex] & extras &
             result[spec.dashDashIndex .. ^1]
  else:
    result = result & extras
