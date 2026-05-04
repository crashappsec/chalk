##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Caller-attestation plugin: ingests a JSON envelope from the
## process that spawned chalk (via `CHALK_CALLER_ATTESTATION`
## env-var, or `CHALK_CALLER_ATTESTATION_FILE` fallback), validates
## its top-level shape, and emits the agreed `CALLER_ATTESTED_*`
## keys into marks and reports.
##
## Inner `info` payloads are passed through opaquely; chalk
## validates only the envelope's outer structure.  Per-artifact
## entries are status-wrapped so a caller race or tampering shows
## up as `mismatch` rather than silently overwriting.
##
## See `docs/design-caller-attestation.md` for the wire-format
## contract.

import std/[
  json,
  options,
  os,
  sets,
  strutils,
  tables,
]

import ".."/[
  chalkjson,
  plugin_api,
  run_management,
  types,
]

const
  envEnvelope     = "CHALK_CALLER_ATTESTATION"
  envFile         = "CHALK_CALLER_ATTESTATION_FILE"
  protocolVersion = 1

  keyVersion      = "version"
  keyInfo         = "CALLER_ATTESTED_INFO"
  keyHostInfo     = "CALLER_ATTESTED_HOST_INFO"
  keyBuildInfo    = "CALLER_ATTESTED_BUILD_INFO"
  keyArtifactInfo = "CALLER_ATTESTED_ARTIFACT_INFO"
  keyUntracked    = "CALLER_ATTESTED_UNTRACKED_ARTIFACT_INFO"

  recognizedTopLevel = [keyInfo, keyHostInfo, keyBuildInfo, keyArtifactInfo]

type
  ArtifactEntry = ref object
    sha256*: string
    info*:   JsonNode  # may be nil if caller omitted `info`

  EnvelopeState = ref object of RootRef
    info*:        JsonNode
    hostInfo*:    JsonNode
    buildInfo*:   JsonNode
    artifacts*:   TableRef[string, ArtifactEntry]
    matchedKeys*: HashSet[string]

# ---------------------------------------------------------------------------
# Envelope read / validate
# ---------------------------------------------------------------------------

proc readEnvelopeBytes(): string =
  let envContent = getEnv(envEnvelope)
  if envContent.len > 0:
    return envContent
  let path = getEnv(envFile)
  if path.len == 0:
    return ""
  if not fileExists(path):
    error(envFile & "=" & path &
          ": file not found; ignoring caller attestation")
    return ""
  result = tryToLoadFile(path)
  if result == "":
    error(envFile & "=" & path & ": does not contain chalk attestation")

proc isHex64(s: string): bool =
  if s.len != 64:
    return false
  for c in s:
    if c notin {'0'..'9', 'a'..'f'}:
      return false
  return true

proc parseAndValidate(raw: string): EnvelopeState =
  ## Pure parser/validator over the caller-attestation envelope.  The
  ## procedure has no side effects: it returns errMsg/warnings the
  ## caller is responsible for logging.  Exposed so the unit-test
  ## suite can exercise the validation logic without dragging in the
  ## chalk plugin runtime.
  new result
  result.artifacts   = newTable[string, ArtifactEntry]()
  result.matchedKeys = initHashSet[string]()

  if raw.len == 0:
    return

  let
    node     = parseJson(raw).assertIs(JObject, "top-level must be a JSON object")
    version  = node.assertHasKey(keyVersion)[keyVersion].assertIs(JInt).getInt()

  if version != protocolVersion:
    raise newException(
      ValueError,
      "unsupported `" & keyVersion & "` (expected " & $protocolVersion & ")"
    )

  for k, _ in node.pairs():
    if k == keyVersion or k in recognizedTopLevel:
      continue
    if k.startsWith("X-"):
      continue
    warn("unknown top-level key '" & k & "' (ignored)")

  for k in [keyInfo, keyHostInfo, keyBuildInfo]:
    if node.hasKey(k):
      node[k].assertIs(JObject, "'" & k & "' must be a JSON object")

  result.info      = node{keyInfo}.assertIs(JObject,      keyInfo,      allowNil = true)
  result.hostInfo  = node{keyHostInfo}.assertIs(JObject,  keyHostInfo,  allowNil = true)
  result.buildInfo = node{keyBuildInfo}.assertIs(JObject, keyBuildInfo, allowNil = true)

  if node.hasKey(keyArtifactInfo):
    let artNode = node[keyArtifactInfo].assertIs(JObject, keyArtifactInfo)
    for path, entry in artNode.pairs():
      entry.assertIs(JObject, "entry for '" & path & "' must be an object")
      entry.assertHasKey("sha256", "entry for '" & path & "' is missing required 'sha256'").assertIs(JString)
      let sha = entry["sha256"].getStr().toLowerAscii()
      if not sha.isHex64():
        raise newException(
          ValueError,
          "entry for '" & path &
          "' has invalid 'sha256' (expected 64-char " &
          "lowercase hex)"
        )
      for fk, _ in entry.pairs():
        if fk != "sha256" and fk != "info":
          raise newException(
            ValueError,
            "entry for '" & path &
            "' has unexpected field '" & fk & "'"
          )
      let infoNode = entry{"info"}
      result.artifacts[path] = ArtifactEntry(sha256: sha, info: infoNode)

proc loadEnvelope(self: Plugin): EnvelopeState =
  if self.internalState != nil:
    return EnvelopeState(self.internalState)
  try:
    let raw = readEnvelopeBytes()
    result = parseAndValidate(raw)
    self.internalState = RootRef(result)
    trace("caller_attestation: envelope loaded (" &
          $result.artifacts.len & " artifact entries)")
  except:
    error("caller attestation: " & getCurrentExceptionMsg() & "; envelope discarded")
    return nil

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc infoOrEmpty(n: JsonNode): JsonNode =
  ## `info` is optional in the protocol; chalk emits `{}` when the
  ## caller omitted it so the wrapper's shape is uniform.
  if n == nil: newJObject() else: n

proc statusJson(status:      string,
                info:        JsonNode,
                attestedSha: string = "",
                observedSha: string = "",
                ): JsonNode =
  result = %*({
    "status": status,
    "info":   infoOrEmpty(info),
  })
  if status != "match":
    if attestedSha.len > 0:
      result["attested_sha256"] = newJString(attestedSha)
    if observedSha.len > 0:
      result["observed_sha256"] = newJString(observedSha)

proc untrackedEntryJson(entry: ArtifactEntry): JsonNode =
  return %*({
    "sha256": entry.sha256,
    "info":   infoOrEmpty(entry.info),
  })

# ---------------------------------------------------------------------------
# Callbacks
# ---------------------------------------------------------------------------

proc callerAttestGetCtHostInfo(self: Plugin): ChalkDict {.cdecl.} =
  result = ChalkDict()
  let state = self.loadEnvelope()
  if state == nil:
    return
  if state.info != nil:
    result.setIfNeeded(keyInfo,      state.info.nimJsonToBox())
  if state.hostInfo != nil:
    result.setIfNeeded(keyHostInfo,  state.hostInfo.nimJsonToBox())
  if state.buildInfo != nil:
    result.setIfNeeded(keyBuildInfo, state.buildInfo.nimJsonToBox())

proc callerAttestGetCtArtifactInfo(self: Plugin, obj: ChalkObj):
                                    ChalkDict {.cdecl.} =
  result = ChalkDict()
  let state = self.loadEnvelope()
  if state == nil or state.artifacts.len == 0:
    return
  let resolved = obj.fsRef.resolvePath()
  if resolved.len == 0 or resolved notin state.artifacts:
    return
  state.matchedKeys.incl(resolved)
  let entry = state.artifacts[resolved]

  let observedOpt = callGetUnchalkedHash(obj)
  if observedOpt.isNone():
    warn(obj.fsRef & ": caller attested but no unchalked hash is " &
         "available; attestation recorded with status \"unverified\".")
    result.setIfNeeded(
      keyArtifactInfo,
      statusJson(
        status      = "unverified",
        attestedSha = entry.sha256,
        info        = entry.info,
      ).nimJsonToBox()
    )
    return

  let observed = observedOpt.get().toLowerAscii()
  if observed == entry.sha256:
    result.setIfNeeded(
      keyArtifactInfo,
      statusJson(
        status = "match",
        info   = entry.info,
      ).nimJsonToBox()
    )
  else:
    warn(obj.fsRef & ": caller-attested hash mismatch (attested " &
         entry.sha256 & ", observed " & observed &
         "); attestation recorded with status \"mismatch\".")
    result.setIfNeeded(
      keyArtifactInfo,
      statusJson(
        status      = "mismatch",
        attestedSha = entry.sha256,
        observedSha = observed,
        info        = entry.info,
      ).nimJsonToBox()
    )

proc callerAttestGetRtHostInfo(self: Plugin, objs: seq[ChalkObj]):
                                ChalkDict {.cdecl.} =
  result = ChalkDict()
  let state = self.loadEnvelope()
  if state == nil or state.artifacts.len == 0:
    return
  let untracked = newJObject()
  for path, entry in state.artifacts.pairs():
    if path in state.matchedKeys:
      continue
    warn(path & ": caller attested but artifact was not processed by " &
         "chalk; moved to " & keyUntracked & ".")
    untracked[path] = untrackedEntryJson(entry)
  result.setIfNeeded(keyUntracked, untracked.nimJsonToBox())

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

proc clearCallback(self: Plugin) {.cdecl.} =
  self.internalState = RootRef(nil)

proc loadCallerAttestation*() =
  newPlugin(
    "caller_attestation",
    ctHostCallback = ChalkTimeHostCb(callerAttestGetCtHostInfo),
    ctArtCallback  = ChalkTimeArtifactCb(callerAttestGetCtArtifactInfo),
    rtHostCallback = RunTimeHostCb(callerAttestGetRtHostInfo),
    clearCallback  = PluginClearCb(clearCallback),
  )
