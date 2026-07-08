## Regression test for grouped-004: the guaranteed chalk core headers must win.
##
## base_sinks.c4m documents that Chalk "always includes" X-Chalk-Version and
## X-Chalk-Action-Id on every POST. Before the fix, postSinkOut/presignSinkOut
## merged headers as getChalkCoreHeaders().update(params.headers), so a
## user-configured header of the same name silently overrode the core value.
## withChalkCoreHeaders() now applies the core headers last so they take
## precedence, upholding the documented guarantee.

import "../../src"/[
  config,
  types,
  utils/http,
]

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc main() =
  let actionId = "11111111-1111-1111-1111-111111111111"
  hostInfo["_ACTION_ID"] = pack(actionId)

  # User config supplies colliding core-header names plus an unrelated header.
  let userHeaders = newHttpHeaders(@[
    ("X-Chalk-Version",   "user-bogus-version"),
    ("X-Chalk-Action-Id", "user-bogus-action"),
    ("X-Test-Header",     "keep-me"),
  ])
  let merged = userHeaders.withChalkCoreHeaders()

  # Core headers win over the colliding user values.
  assertEq($merged["X-Chalk-Version"],   getChalkExeVersion())
  assertEq($merged["X-Chalk-Action-Id"], actionId)
  # Non-colliding user headers are preserved.
  assertEq($merged["X-Test-Header"], "keep-me")

  # When _ACTION_ID is absent, X-Chalk-Version still wins over a colliding user
  # value and no X-Chalk-Action-Id is emitted (chalk does not supply one).
  hostInfo.del("_ACTION_ID")
  let withoutActionId = newHttpHeaders(@[
    ("X-Chalk-Version", "user-bogus-version"),
  ]).withChalkCoreHeaders()
  assertEq($withoutActionId["X-Chalk-Version"], getChalkExeVersion())
  assertEq(withoutActionId.hasKey("X-Chalk-Action-Id"), false)

main()
