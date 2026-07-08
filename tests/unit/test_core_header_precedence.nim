## Regression test: guaranteed chalk core headers must win over user config.
##
## base_sinks.c4m documents that Chalk "always includes" the five core headers
## on every POST/presign request and that they take precedence over any
## same-named header supplied via the `headers` field.
## addChalkCoreHeaders() applies core headers last so they override the
## user-configured values, upholding the documented guarantee.

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

  let body = "test-body"

  # User config supplies colliding core-header names plus an unrelated header.
  let userHeaders = newHttpHeaders(@[
    ("X-Chalk-Version",       "user-bogus-version"),
    ("X-Chalk-Operation",     "user-bogus-operation"),
    ("X-Chalk-Action-Id",     "user-bogus-action"),
    ("X-Content-Length",      "user-bogus-length"),
    ("X-Chalk-Digest-Sha256", "user-bogus-digest"),
    ("X-Test-Header",         "keep-me"),
  ])
  let merged = userHeaders.addChalkCoreHeaders(body = body)

  # Core headers win over the colliding user values.
  assertEq($merged["X-Chalk-Version"],       getChalkExeVersion())
  assertEq($merged["X-Chalk-Operation"],     getBaseCommandName())
  assertEq($merged["X-Chalk-Action-Id"],     actionId)
  assertEq($merged["X-Content-Length"],      $len(body))
  assertEq(merged.hasKey("X-Chalk-Digest-Sha256"), true)
  doAssert $merged["X-Chalk-Digest-Sha256"] != "user-bogus-digest"
  # Non-colliding user headers are preserved.
  assertEq($merged["X-Test-Header"], "keep-me")

  # When _ACTION_ID is absent, the other four core headers still win and
  # no X-Chalk-Action-Id is emitted (chalk does not supply one).
  hostInfo.del("_ACTION_ID")
  let withoutActionId = newHttpHeaders(@[
    ("X-Chalk-Version", "user-bogus-version"),
  ]).addChalkCoreHeaders(body = body)
  assertEq($withoutActionId["X-Chalk-Version"], getChalkExeVersion())
  assertEq(withoutActionId.hasKey("X-Chalk-Action-Id"), false)

main()
