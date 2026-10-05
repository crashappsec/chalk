## Copyright (c) 2026, Crash Override, Inc.
## This file is part of Chalk (see https://crashoverride.com/docs/chalk).

## Policy settings shared by all rules. Rule-specific settings are read by
## each rule (see policy/rules/) via the `policy*Setting` accessors, which
## read `policy.config_json` when it is set and the con4m section otherwise.
import std/[json]
import ".."/[config, types]

type
  PolicyConfig* = object
    id*:      string
    mode*:    string
    onError*: string
    ## set when `policy.config_json` cannot be used; evaluation then only
    ## reports this error and never blocks
    configError*: string

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

proc parsePolicyJson*(text: string): JsonNode =
  ## Parses and validates `policy.config_json`. Raises `ValueError` with a
  ## user-facing reason when it cannot be used.
  try:
    result = parseJson(text)
  except CatchableError:
    raise newException(ValueError, "policy.config_json is not valid JSON: " &
                                   getCurrentExceptionMsg())
  if result.kind != JObject:
    raise newException(ValueError, "policy.config_json must be a JSON object")
  result.validateFields(policyJsonFields, "policy.")
  if result.hasKey("golden_images"):
    let golden = result["golden_images"]
    golden.validateFields(goldenImagesJsonFields, "policy.golden_images.")
    for entry in golden{"allowed"}.getElems():
      if entry.kind != JArray or len(entry) != 2 or
         entry[0].kind != JString or entry[1].kind != JString:
        raise newException(ValueError,
                           "policy.golden_images.allowed entries must be [kind, value] string pairs")

var
  policyJsonLoaded = false
  policyJson:      JsonNode = nil
  policyJsonError  = ""

proc setPolicyJson*(text: string) =
  ## Uses `text` as `policy.config_json`; an empty string disables it.
  ## chalk reads the attribute lazily, this is exposed for unit tests.
  policyJsonLoaded = true
  policyJson       = nil
  policyJsonError  = ""
  if text == "":
    return
  try:
    policyJson = parsePolicyJson(text)
  except ValueError:
    policyJsonError = getCurrentExceptionMsg()

proc ensurePolicyJson() =
  if not policyJsonLoaded:
    setPolicyJson(attrGetOpt[string]("policy.config_json").get(""))

proc policyJsonInUse(): bool =
  ensurePolicyJson()
  policyJson != nil or policyJsonError != ""

proc jsonSetting(path: openArray[string]): JsonNode =
  result = policyJson
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

proc policyMode*(): string =
  ensurePolicyJson()
  if policyJsonError != "":
    # evaluate only to report the broken configuration
    return "audit"
  policyStringSetting(["mode"], "off")

proc policyEnabled*(): bool =
  policyMode() in ["audit", "enforce"]

proc policyReportTemplate*(): string =
  getReportTemplate("policy", default = "policy_report")

proc policyControls*(): PolicyConfig =
  result.mode = policyMode()
  if policyJsonError != "":
    result.onError     = "allow"
    result.configError = policyJsonError
    return
  result.id      = policyStringSetting(["id"], "")
  result.onError = policyStringSetting(["on_error"], "allow")
