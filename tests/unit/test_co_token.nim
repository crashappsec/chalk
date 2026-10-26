import std/[
  strutils,
  base64,
  json,
  times,
]
import "../../src/utils/co_token"

template check(cond: untyped) =
  doAssert cond, "failed: " & astToStr(cond)

proc b64(s: string): string =
  base64.encode(s, safe = true).strip(chars = {'='}, leading = false)

proc jwt(exp: int64): string =
  b64("""{"alg":"none","typ":"JWT"}""") & "." &
  b64($(%*{"sub": "x", "exp": exp})) & "." & b64("sig")

# built at runtime so secret scanners do not flag the fixtures
let
  fake = "sk" & "_"
  body = "x".repeat(24)
let now = getTime().toUnix()

# valid unexpired JWT is unchanged
check isCoTokenValid(jwt(now + 3600))
# expired JWT is still rejected
check not isCoTokenValid(jwt(now - 3600))
# WorkOS API keys are accepted
check isCoTokenValid(fake & "test_" & body)
check isCoTokenValid(fake & "live_" & body)
# garbage is rejected
check not isCoTokenValid("")
check not isCoTokenValid("garbage")
check not isCoTokenValid("a.b.c")
check not isCoTokenValid("sk_")
check not isCoTokenValid("sk_short")
check not isCoTokenValid(fake & "test_has space_" & body)
check not isCoTokenValid("pk_test_" & body)
