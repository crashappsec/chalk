## The policy report is a report of its own: it is published under a fresh
## _ACTION_ID (every chalk report has a unique one) while the docker command's
## id is restored afterwards, and the presign sink must see the fresh id while
## the report is in flight (X-Chalk-Action-Id).

import std/[strutils]
import "../../src"/[
  config,
  run_management,
  types,
  utils/http,
]

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc isActionId(s: string): bool =
  s.len == 16 and s.allCharsInSet(HexDigits) and s == s.toLower()

proc main() =
  let policyId = newActionId()
  doAssert policyId.isActionId(), policyId
  doAssert newActionId() != policyId

  # the command's id is restored once the policy report is published
  let commandId = "0123456789abcdef"
  hostInfo["_ACTION_ID"] = pack(commandId)
  var seen = ""
  withActionId(policyId):
    seen = unpack[string](hostInfo["_ACTION_ID"])
    # what the presign sink sends while the policy report is in flight
    let headers = newHttpHeaders().addChalkCoreHeaders(body = "")
    assertEq($headers["X-Chalk-Action-Id"], policyId)
  assertEq(seen, policyId)
  assertEq(unpack[string](hostInfo["_ACTION_ID"]), commandId)

  # restored even when publishing raises, and removed when there was none
  hostInfo.del("_ACTION_ID")
  try:
    withActionId(policyId):
      raise newException(ValueError, "publish failed")
  except ValueError:
    discard
  assertEq("_ACTION_ID" in hostInfo, false)

main()
