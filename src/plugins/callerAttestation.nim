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
  ArtifactEntry* = object
    sha256*: string
    info*:   JsonNode  # may be nil if caller omitted `info`

  EnvelopeState* = object
    valid*:       bool
    info*:        JsonNode
    hostInfo*:    JsonNode
    buildInfo*:   JsonNode
    artifacts*:   TableRef[string, ArtifactEntry]
    matchedKeys*: HashSet[string]

  ValidationResult* = object
    state*:    EnvelopeState
    errMsg*:   string       # non-empty → envelope rejected
    warnings*: seq[string]  # passes that succeeded but want a warn log

var
  loaded = false
  state: EnvelopeState

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
  try:
    return readFile(path)
  except IOError, OSError:
    error(envFile & "=" & path & ": " & getCurrentExceptionMsg() &
          "; ignoring caller attestation")
    return ""

proc isHex64(s: string): bool =
  if s.len != 64:
    return false
  for c in s:
    if c notin {'0'..'9', 'a'..'f'}:
      return false
  return true

proc parseAndValidate*(raw: string): ValidationResult =
  ## Pure parser/validator over the caller-attestation envelope.  The
  ## procedure has no side effects: it returns errMsg/warnings the
  ## caller is responsible for logging.  Exposed so the unit-test
  ## suite can exercise the validation logic without dragging in the
  ## chalk plugin runtime.
  result.state.valid       = false
  result.state.artifacts   = newTable[string, ArtifactEntry]()
  result.state.matchedKeys = initHashSet[string]()
  result.warnings          = @[]

  if raw.len == 0:
    return

  var node: JsonNode
  try:
    node = parseJson(raw)
  except JsonParsingError:
    result.errMsg = "malformed JSON: " & getCurrentExceptionMsg()
    return

  if node.kind != JObject:
    result.errMsg = "top-level must be a JSON object"
    return

  if not node.hasKey(keyVersion):
    result.errMsg = "missing required `" & keyVersion & "` field"
    return
  let verNode = node[keyVersion]
  if verNode.kind != JInt or verNode.getInt() != protocolVersion:
    result.errMsg = "unsupported `" & keyVersion & "` (expected " &
                    $protocolVersion & ")"
    return

  for k, _ in node.pairs():
    if k == keyVersion or k in recognizedTopLevel:
      continue
    if k.startsWith("X-"):
      continue
    result.warnings.add("unknown top-level key '" & k & "' (ignored)")

  for k in [keyInfo, keyHostInfo, keyBuildInfo]:
    if node.hasKey(k) and node[k].kind != JObject:
      result.errMsg = "'" & k & "' must be a JSON object"
      return

  if node.hasKey(keyInfo):      result.state.info      = node[keyInfo]
  if node.hasKey(keyHostInfo):  result.state.hostInfo  = node[keyHostInfo]
  if node.hasKey(keyBuildInfo): result.state.buildInfo = node[keyBuildInfo]

  if node.hasKey(keyArtifactInfo):
    let artNode = node[keyArtifactInfo]
    if artNode.kind != JObject:
      result.errMsg = "'" & keyArtifactInfo & "' must be a JSON object"
      return
    for path, entry in artNode.pairs():
      if entry.kind != JObject:
        result.errMsg = "entry for '" & path & "' must be an object"
        return
      if not entry.hasKey("sha256") or entry["sha256"].kind != JString:
        result.errMsg = "entry for '" & path &
                        "' is missing required string 'sha256'"
        return
      let sha = entry["sha256"].getStr().toLowerAscii()
      if not sha.isHex64():
        result.errMsg = "entry for '" & path &
                        "' has invalid 'sha256' (expected 64-char " &
                        "lowercase hex)"
        return
      for fk, _ in entry.pairs():
        if fk != "sha256" and fk != "info":
          result.errMsg = "entry for '" & path &
                          "' has unexpected field '" & fk & "'"
          return
      var infoNode: JsonNode = nil
      if entry.hasKey("info"):
        infoNode = entry["info"]
      result.state.artifacts[path] = ArtifactEntry(sha256: sha, info: infoNode)

  result.state.valid = true

proc loadEnvelopeOnce() =
  if loaded:
    return
  loaded = true
  let
    raw = readEnvelopeBytes()
    res = parseAndValidate(raw)
  if res.errMsg.len > 0:
    error("caller attestation: " & res.errMsg & "; envelope discarded")
    return
  for w in res.warnings:
    warn("caller attestation: " & w)
  state = res.state
  if state.valid:
    trace("caller_attestation: envelope loaded (" &
          $state.artifacts.len & " artifact entries)")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc realpath(p: string): string =
  try:
    return expandFilename(p)
  except OSError:
    return ""

proc infoOrEmpty(n: JsonNode): JsonNode =
  ## `info` is optional in the protocol; chalk emits `{}` when the
  ## caller omitted it so the wrapper's shape is uniform.
  if n == nil: newJObject() else: n

proc statusJson(status:      string,
                attestedSha: string,
                observedSha: string,
                info:        JsonNode): JsonNode =
  result = newJObject()
  result["status"] = newJString(status)
  if status != "match":
    if attestedSha.len > 0:
      result["attested_sha256"] = newJString(attestedSha)
    if observedSha.len > 0:
      result["observed_sha256"] = newJString(observedSha)
  result["info"] = infoOrEmpty(info)

proc untrackedEntryJson(entry: ArtifactEntry): JsonNode =
  result = newJObject()
  result["sha256"] = newJString(entry.sha256)
  result["info"]   = infoOrEmpty(entry.info)

# ---------------------------------------------------------------------------
# Callbacks
# ---------------------------------------------------------------------------

proc callerAttestGetCtHostInfo*(self: Plugin): ChalkDict {.cdecl.} =
  result = ChalkDict()
  loadEnvelopeOnce()
  if not state.valid:
    return
  if state.info != nil:
    result.setIfNeeded(keyInfo, state.info.nimJsonToBox())
  if state.hostInfo != nil:
    result.setIfNeeded(keyHostInfo, state.hostInfo.nimJsonToBox())
  if state.buildInfo != nil:
    result.setIfNeeded(keyBuildInfo, state.buildInfo.nimJsonToBox())

proc callerAttestGetCtArtifactInfo*(self: Plugin, obj: ChalkObj):
                                    ChalkDict {.cdecl.} =
  result = ChalkDict()
  loadEnvelopeOnce()
  if not state.valid or state.artifacts.len == 0:
    return
  let resolved = realpath(obj.fsRef)
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
      statusJson("unverified", entry.sha256, "", entry.info).nimJsonToBox())
    return

  let observed = observedOpt.get().toLowerAscii()
  if observed == entry.sha256:
    result.setIfNeeded(
      keyArtifactInfo,
      statusJson("match", "", "", entry.info).nimJsonToBox())
  else:
    warn(obj.fsRef & ": caller-attested hash mismatch (attested " &
         entry.sha256 & ", observed " & observed &
         "); attestation recorded with status \"mismatch\".")
    result.setIfNeeded(
      keyArtifactInfo,
      statusJson("mismatch", entry.sha256, observed, entry.info).nimJsonToBox())

proc callerAttestGetRtHostInfo*(self: Plugin, objs: seq[ChalkObj]):
                                ChalkDict {.cdecl.} =
  result = ChalkDict()
  loadEnvelopeOnce()
  if not state.valid or state.artifacts.len == 0:
    return
  let untracked = newJObject()
  for path, entry in state.artifacts.pairs():
    if path in state.matchedKeys:
      continue
    warn(path & ": caller attested but artifact was not processed by " &
         "chalk; moved to " & keyUntracked & ".")
    untracked[path] = untrackedEntryJson(entry)
  if untracked.len > 0:
    result.setIfNeeded(keyUntracked, untracked.nimJsonToBox())

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

proc loadCallerAttestation*() =
  newPlugin(
    "caller_attestation",
    ctHostCallback = ChalkTimeHostCb(callerAttestGetCtHostInfo),
    ctArtCallback  = ChalkTimeArtifactCb(callerAttestGetCtArtifactInfo),
    rtHostCallback = RunTimeHostCb(callerAttestGetRtHostInfo),
  )
