## Regression test for the unguarded _ACTION_ID read in getChalkCoreHeaders().
##
## Before the guard fix, calling getChalkCoreHeaders() while hostInfo lacked
## _ACTION_ID raised `KeyError: key not found: _ACTION_ID` during header
## construction, aborting the post/presign sink write before any HTTP request.
## The X-Chalk-Action-Id header must now be omitted when _ACTION_ID is absent
## and emitted when it is present, while X-Chalk-Version is always included.

import "../../src"/[
  config,
  types,
  utils/http,
]

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc main() =
  # _ACTION_ID absent: must not raise, must omit X-Chalk-Action-Id, and must
  # still emit X-Chalk-Version.
  if "_ACTION_ID" in hostInfo:
    hostInfo.del("_ACTION_ID")
  let withoutActionId = getChalkCoreHeaders()
  assertEq(withoutActionId.hasKey("X-Chalk-Action-Id"), false)
  assertEq(withoutActionId.hasKey("X-Chalk-Version"),    true)
  assertEq($withoutActionId["X-Chalk-Version"],          getChalkExeVersion())

  # _ACTION_ID present: must emit X-Chalk-Action-Id carrying the collected id.
  let actionId = "00000000-0000-0000-0000-000000000000"
  hostInfo["_ACTION_ID"] = pack(actionId)
  let withActionId = getChalkCoreHeaders()
  assertEq(withActionId.hasKey("X-Chalk-Action-Id"), true)
  assertEq($withActionId["X-Chalk-Action-Id"],       actionId)
  assertEq($withActionId["X-Chalk-Version"],         getChalkExeVersion())

main()
