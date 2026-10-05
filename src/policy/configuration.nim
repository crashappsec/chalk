## Copyright (c) 2026, Crash Override, Inc.
## This file is part of Chalk (see https://crashoverride.com/docs/chalk).

## Policy settings shared by all rules. Rule-specific settings are read by
## each rule (see policy/rules/).
import ".."/[config, types]

type
  PolicyConfig* = object
    mode*:    string
    onError*: string

proc policyMode*(): string =
  attrGetOpt[string]("policy.mode").get("off")

proc policyEnabled*(): bool =
  policyMode() in ["audit", "enforce"]

proc policyReportTemplate*(): string =
  getReportTemplate("policy", default = "policy_report")

proc policyControls*(): PolicyConfig =
  result.mode = policyMode()
  result.onError = attrGetOpt[string]("policy.on_error").get("allow")
