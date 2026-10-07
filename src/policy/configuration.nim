## Copyright (c) 2026, Crash Override, Inc.
## This file is part of Chalk (see https://crashoverride.com/docs/chalk).

## Policy settings shared by all rules. Rule-specific settings are read by
## each rule (see policy/rules/) via the `policy*Setting` accessors, which
## read the selected `policy.config_json` policy when it is set and the
## con4m section otherwise.
import std/[json, tables]
import ".."/[config, types]

type
  PolicyConfig* = object
    id*:      string
    mode*:    string
    onError*: string
    ## set when the policy cannot be used; evaluation then only
    ## reports this error and never blocks
    configError*: string
    ## the policy's object in `policy.config_json`, nil for con4m
    json*: JsonNode

  PolicyJsonField = object
    name:    string
    kind:    JsonNodeKind
    choices: seq[string]

const
  policyJsonFields = [
    PolicyJsonField(name: "id",            kind: JString),
    PolicyJsonField(name: "mode",          kind: JString, choices: @["off", "audit", "enforce"]),
    PolicyJsonField(name: "on_error",      kind: JString, choices: @["allow", "block"]),
    PolicyJsonField(name: "golden_images", kind: JObject),
  ]
  goldenImagesJsonFields = [
    PolicyJsonField(name: "enabled",         kind: JBool),
    PolicyJsonField(name: "check_copy_from", kind: JBool),
    PolicyJsonField(name: "allowed",         kind: JArray),
    PolicyJsonField(name: "message",         kind: JString),
  ]

proc jsonKindName(kind: JsonNodeKind): string =
  case kind
  of JString:          "string"
  of JBool:            "boolean"
  of JObject:          "object"
  of JArray:           "array"
  of JInt, JFloat:     "number"
  of JNull:            "null"

proc validateFields(node: JsonNode, fields: openArray[PolicyJsonField], path: string) =
  for key, value in node.pairs():
    var found = false
    for field in fields:
      if field.name != key:
        continue
      found = true
      let fullPath = path & key
      if value.kind != field.kind:
        raise newException(ValueError, fullPath & " must be a " & jsonKindName(field.kind) &
                                       ", got " & jsonKindName(value.kind))
      if len(field.choices) > 0 and value.getStr() notin field.choices:
        raise newException(ValueError, fullPath & " must be one of " & $field.choices)
    if not found:
      raise newException(ValueError, "unknown field " & path & key)

proc validatePolicy(node: JsonNode, path: string) =
  ## `path` is the field prefix used in errors, e.g. `policy.`
  if node.kind != JObject:
    raise newException(ValueError, path[0 .. ^2] & " must be a JSON object, got " &
                                   jsonKindName(node.kind))
  node.validateFields(policyJsonFields, path)
  if node.hasKey("golden_images"):
    let golden = node["golden_images"]
    golden.validateFields(goldenImagesJsonFields, path & "golden_images.")
    for entry in golden{"allowed"}.getElems():
      if entry.kind != JArray or len(entry) != 2 or
         entry[0].kind != JString or entry[1].kind != JString:
        raise newException(ValueError,
                           path & "golden_images.allowed entries must be [kind, value] string pairs")

proc invalidPolicy(id, reason: string): PolicyConfig =
  # a configuration that cannot be read cannot be trusted to block either
  PolicyConfig(id: id, mode: "audit", onError: "allow", configError: reason)

proc toPolicyConfig(node: JsonNode): PolicyConfig =
  PolicyConfig(
    id:      node{"id"}.getStr(),
    mode:    node{"mode"}.getStr("off"),
    onError: node{"on_error"}.getStr("allow"),
    json:    node,
  )

proc isPolicyList(doc: JsonNode): bool =
  doc.kind == JObject and doc.hasKey("policies")

proc parsePolicyJson*(text: string): seq[PolicyConfig] =
  ## Parses and validates `policy.config_json`: one policy object, or
  ## `{"policies": [<policy object>, ...]}`. Raises `ValueError` with a
  ## user-facing reason when the document as a whole cannot be used. An
  ## unusable `policies` entry is returned with `configError` set instead, so
  ## that one broken policy does not disable the others.
  var doc: JsonNode
  try:
    doc = parseJson(text)
  except CatchableError:
    raise newException(ValueError, "policy.config_json is not valid JSON: " &
                                   getCurrentExceptionMsg())
  if doc.kind != JObject:
    raise newException(ValueError, "policy.config_json must be a JSON object")
  if not doc.isPolicyList():
    doc.validatePolicy("policy.")
    return @[doc.toPolicyConfig()]
  if len(doc) != 1:
    raise newException(ValueError, "policy.policies cannot be combined with other fields")
  let entries = doc["policies"]
  if entries.kind != JArray:
    raise newException(ValueError, "policy.policies must be an array, got " &
                                   jsonKindName(entries.kind))
  var counts = initCountTable[string]()
  for entry in entries:
    if entry.kind == JObject and entry{"id"} != nil and entry{"id"}.kind == JString:
      counts.inc(entry{"id"}.getStr())
  for i, entry in entries.getElems():
    let
      path = "policy.policies[" & $i & "]."
      id   = if entry.kind == JObject: entry{"id"}.getStr() else: ""
    try:
      entry.validatePolicy(path)
    except ValueError:
      result.add(invalidPolicy(id, getCurrentExceptionMsg()))
      continue
    # results and findings are attributed to policies by id, so with several
    # policies an id that is missing or shared would make them ambiguous
    if len(entries) > 1 and id == "":
      result.add(invalidPolicy(id, path & "id must be set when there are several policies"))
    elif counts[id] > 1:
      result.add(invalidPolicy(id, path & "id " & escapeJson(id) & " is not unique"))
    else:
      result.add(entry.toPolicyConfig())

var
  policyJsonLoaded = false
  policyJsonSet    = false
  policyJsonList   = false
  policyJsonError  = ""
  policyJsonConfigs: seq[PolicyConfig]
  # policy whose settings the rules read, see selectPolicy
  selectedPolicyJson: JsonNode = nil

proc setPolicyJson*(text: string) =
  ## Uses `text` as `policy.config_json`; an empty string disables it.
  ## chalk reads the attribute lazily, this is exposed for unit tests.
  policyJsonLoaded   = true
  policyJsonSet      = text != ""
  policyJsonList     = false
  policyJsonError    = ""
  policyJsonConfigs  = @[]
  selectedPolicyJson = nil
  if text == "":
    return
  try:
    policyJsonConfigs = parsePolicyJson(text)
    policyJsonList    = parseJson(text).isPolicyList()
  except ValueError:
    policyJsonError = getCurrentExceptionMsg()

proc ensurePolicyJson() =
  if not policyJsonLoaded:
    setPolicyJson(attrGetOpt[string]("policy.config_json").get(""))

proc policyJsonInUse(): bool =
  ensurePolicyJson()
  policyJsonSet

proc policyJsonIsList*(): bool =
  ## `policy.config_json` uses the `{"policies": [...]}` form
  ensurePolicyJson()
  policyJsonList

proc selectPolicy*(policy: PolicyConfig) =
  ## Rules read their settings from `policy` until another one is selected.
  selectedPolicyJson = policy.json

proc jsonSetting(path: openArray[string]): JsonNode =
  result = selectedPolicyJson
  for part in path:
    if result == nil:
      return nil
    result = result{part}

proc attrPath(path: openArray[string]): string =
  result = "policy"
  for part in path:
    result &= "." & part

proc policyStringSetting*(path: openArray[string], default: string): string =
  if policyJsonInUse():
    let node = jsonSetting(path)
    return if node == nil: default else: node.getStr()
  attrGetOpt[string](attrPath(path)).get(default)

proc policyBoolSetting*(path: openArray[string], default: bool): bool =
  if policyJsonInUse():
    let node = jsonSetting(path)
    return if node == nil: default else: node.getBool()
  attrGetOpt[bool](attrPath(path)).get(default)

proc policyPairsSetting*(path: openArray[string]): seq[(string, string)] =
  if policyJsonInUse():
    let node = jsonSetting(path)
    if node == nil:
      return
    for entry in node.getElems():
      result.add((entry[0].getStr(), entry[1].getStr()))
    return
  for entry in attrGetOpt[seq[Box]](attrPath(path)).get(@[]):
    let parts = unpack[seq[Box]](entry)
    if len(parts) != 2:
      raise newException(ValueError, attrPath(path) & " entries must be (kind, value) tuples")
    result.add((unpack[string](parts[0]), unpack[string](parts[1])))

proc policyConfigs*(): seq[PolicyConfig] =
  ## Every configured policy, including those in mode `off`. A
  ## `policy.config_json` that cannot be read at all is a single policy that
  ## only reports why.
  ensurePolicyJson()
  if policyJsonError != "":
    return @[invalidPolicy("", policyJsonError)]
  if policyJsonSet:
    return policyJsonConfigs
  return @[PolicyConfig(
    id:      attrGetOpt[string]("policy.id").get(""),
    mode:    attrGetOpt[string]("policy.mode").get("off"),
    onError: attrGetOpt[string]("policy.on_error").get("allow"),
  )]

proc isEvaluated*(policy: PolicyConfig): bool =
  policy.mode in ["audit", "enforce"]

proc policyEnabled*(): bool =
  for policy in policyConfigs():
    if policy.isEvaluated():
      return true
  return false

proc policyReportTemplate*(): string =
  getReportTemplate("policy", default = "policy_report")
