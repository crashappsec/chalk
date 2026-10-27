import std/[
  strutils,
  base64,
  httpclient,
  json,
  options,
  tables,
  times,
]
import pkg/nimutils/auth
import pkg/nimutils/jwt as nimjwt
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

# shape boundaries: case-sensitive prefix, at least 20 chars
check not isApiKey(fake & "x".repeat(16))
check isApiKey(fake & "x".repeat(17))
check not isApiKey("SK_test_" & body)
# keys are not trimmed: a padded key must never reach a header
for pad in [" ", "\t", "\n", "\r\n", "\v", "\f"]:
  check not isCoTokenValid(pad & fake & "test_" & body)
  check not isCoTokenValid(fake & "test_" & body & pad)

proc legacyIsJwtValid(token: string): bool =
  ## is_jwt_valid before API keys were accepted, verbatim
  if len(token) == 0:
    return false
  try:
    let
      parsed  = parseJwtToken(token)
      isAlive = parsed.isStillAlive()
    return isAlive
  except:
    return false

proc jwtNoExp(): string =
  b64("""{"alg":"none","typ":"JWT"}""") & "." &
  b64($(%*{"sub": "x"})) & "." & b64("sig")

let
  apiKey = fake & "test_" & body
  live   = jwt(now + 3600)
  # every token that is not an API key must validate exactly as before
  legacyCorpus = @[
    live, jwt(now - 3600), jwt(0), jwtNoExp(),
    live & "\n", " " & live, "Bearer " & live,
    live.rsplit('.', 1)[0],
    "", " ", "\n", "garbage", "a.b.c", "eyJ", "sk_", "sk_short",
    "pk_test_" & body, "SK_test_" & body,
    " " & apiKey, apiKey & "\n", apiKey & "\r\n",
  ]

# a JWT never takes the API key path
check not isApiKey(live)
for token in legacyCorpus:
  doAssert not isApiKey(token), "API key shape: " & token.escape()
  doAssert isCoTokenValid(token) == legacyIsJwtValid(token),
    "legacy mismatch: " & token.escape()

proc authError(impl: AuthImplementation, token: string): string =
  try:
    discard configAuth(impl, "co", some(newOrderedTable({"token": token})))
    return ""
  except CatchableError:
    return getCurrentExceptionMsg()

# runtime `jwt` auth (sinks, attestation, object store, docker login)
addDefaultAuths()
let impl = getAuthImplementation("jwt").get()
# nimutils alone parses every token as a JWT, so it rejects API keys
check authError(impl, apiKey) == "Invalid JWT"
var legacyErrors: seq[string]
for token in legacyCorpus:
  legacyErrors.add(authError(impl, token))
check legacyErrors[0] == ""
check legacyErrors[1].startsWith("JWT token has expired since")

acceptApiKeysInJwtAuth()
acceptApiKeysInJwtAuth() # idempotent
check authError(impl, apiKey) == ""
check authError(impl, fake & "live_" & body) == ""
let
  conf   = configAuth(impl, "co", some(newOrderedTable({"token": apiKey}))).get()
  bearer: string = impl.injectHeaders(conf, newHttpHeaders())["Authorization"]
check bearer == "Bearer " & apiKey
for i, token in legacyCorpus:
  let err = authError(impl, token)
  doAssert err == legacyErrors[i],
    "auth error changed for " & token.escape() & ": " & err
  if len(token.strip()) > 3:
    doAssert token.strip() notin err, "error leaks token: " & err
