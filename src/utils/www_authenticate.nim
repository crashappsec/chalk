##
## Copyright (c) 2024-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Very basic implementation of https://www.rfc-editor.org/rfc/rfc7235#section-4.1
## Currently only bearer challenge is supported

import std/[
  net,
  sequtils,
  uri,
]
import pkg/[
  nimutils/net,
  nimutils/logging,
]
import "."/[
  http,
  json,
  strings,
  tables,
]

type
  AuthChallengeType = enum
    bearer
    other

  AuthChallenge = ref object
    scheme:    string
    options:   OrderedTable[string, string]
    case kind: AuthChallengeType
    of bearer:
      realm: string
      url:   string
    of other:
      discard

proc `$`(self: AuthChallenge): string =
  var options = ""
  for k, v in self.options.pairs():
    options &= k & "=\"" & v & "\","
  let value = self.scheme & " " & options
  return value.strip(chars = {' ', ','})

proc initOtherChallenge(scheme: string, options: OrderedTable[string, string]): AuthChallenge =
  return AuthChallenge(scheme:  scheme,
                       kind:    other,
                       options: options)

proc initBearerChallenge(options: var OrderedTable[string, string]): AuthChallenge =
  ## initialize bearer challenge
  ## it requires realm to be defined which is deleted from options
  ## as it is a top level challenge attribute
  if "realm" notin options:
    raise newException(ValueError, "bearer challenge doesnt have realm URL: " & $options)
  let realm = options["realm"]
  if not (realm.startsWith("http://") or realm.startsWith("https://")):
    raise newException(ValueError, "bearer challenge realm is not http or https url: " & $options)
  options.del("realm")
  let uri = parseUri(realm) ? options.pairs().toSeq()
  return AuthChallenge(scheme:  "bearer",
                       kind:    bearer,
                       options: options,
                       realm:   realm,
                       url:     $uri)

proc elicitHeaders(self: AuthChallenge, headers = newHttpHeaders()): HttpHeaders =
  case self.kind:
  of other:
    raise newException(ValueError, "unsupported auth challenge scheme: " & self.scheme)
  of bearer:
    trace("http: fetching bearer token from: " & self.url)
    let tokenResponse = safeRequest(self.url, headers = headers)
    if not tokenResponse.code().is2xx():
      raise newException(ValueError,
                         "Bearer auth realm URL did not return valid response: " &
                         tokenResponse.status)
    let
      tokenBody  = tokenResponse.body()
      tokenJson  = parseJson(tokenBody)
      token      = tokenJson{"token"}.getStr()
    if token == "":
      raise newException(ValueError,
                         "Bearer auth realm URL did not return auth token: " &
                         tokenBody)
    result = newHttpHeaders({"Authorization": "Bearer " & token})

proc elicitHeaders*(challenges: seq[AuthChallenge], headers = newHttpHeaders()): HttpHeaders =
  result = newHttpHeaders()
  for challenge in challenges:
    try:
      return challenge.elicitHeaders(headers = headers)
    except:
      continue

proc parseAuthChallenge(data: seq[string]): AuthChallenge =
  if len(data) < 2:
    raise newException(ValueError, "invalid auth challenge: " & $data)
  let scheme  = data[0].toLower()
  var allOptions = initOrderedTable[string, string]()
  for option in data[1..^1]:
    if option.strip() == "":
      continue
    let keyValue = option.split("=", maxsplit = 1)
    if len(keyValue) != 2:
      raise newException(ValueError, "invalid auth challenge option: " & option)
    let
      key   = keyValue[0].strip()
      value = keyValue[1].strip()
    allOptions[key] = value
  case scheme:
  of "bearer":
    return initBearerChallenge(allOptions)
  else:
    return initOtherChallenge(scheme, allOptions)

proc parseAuthChallenges(data: string): seq[AuthChallenge] =
  # https://www.rfc-editor.org/rfc/rfc7235#section-4.1
  # for example:
  # www-authenticate: Bearer realm="https://public.ecr.aws/token/",service="public.ecr.aws",scope="aws"
  result = @[]
  var challenge = newSeq[string]()
  for word in data.quotedWords(seps = {' ', ','}):
    if word.strip() == "":
      continue
    if "=" notin word and len(challenge) > 0:
      result.add(parseAuthChallenge(challenge))
      challenge = @[]
    challenge.add(word)
  if len(challenge) > 0:
    result.add(parseAuthChallenge(challenge))

proc authHeadersSafeRequest*(url: Uri | string,
                             httpMethod: HttpMethod | string = HttpGet,
                             body = "",
                             headers: HttpHeaders = newHttpHeaders(),
                             multipart: MultipartData = nil,
                             retries: int = 0,
                             firstRetryDelayMs: int = 0,
                             timeout: int = 1000,
                             pinnedCert: string = "",
                             verifyMode = CVerifyPeer,
                             maxRedirects: int = 3,
                             disallowHttp: bool = false,
                             acceptStatusCodes: openArray[Slice[int]] = @[],
                             rejectStatusCodes: openArray[Slice[int]] = @[],
                             ): (HttpHeaders, Response) =
  var
    authHeaders = headers
    newHeaders  = newHttpHeaders()
    response    = safeRequest(
      url               = url,
      httpMethod        = httpMethod,
      body              = body,
      headers           = authHeaders,
      multipart         = multipart,
      retries           = retries,
      firstRetryDelayMs = firstRetryDelayMs,
      timeout           = timeout,
      pinnedCert        = pinnedCert,
      verifyMode        = verifyMode,
      maxRedirects      = maxRedirects,
      disallowHttp      = disallowHttp,
    )

  if (
    response.code() == Http401 and
    response.headers.hasKey("www-authenticate")
  ):
    trace("http: eliciting auth headers via www-authenticate for " & $url)
    let
      wwwAuthenticate = response.headers["www-authenticate"]
      challenges      = parseAuthChallenges(wwwAuthenticate)
    newHeaders        = challenges.elicitHeaders(authHeaders)
    authHeaders       = authHeaders.update(newHeaders)

    # reattempt request
    response = safeRequest(
      url               = url,
      httpMethod        = httpMethod,
      body              = body,
      headers           = authHeaders,
      multipart         = multipart,
      retries           = retries,
      firstRetryDelayMs = firstRetryDelayMs,
      timeout           = timeout,
      pinnedCert        = pinnedCert,
      verifyMode        = verifyMode,
      maxRedirects      = maxRedirects,
      disallowHttp      = disallowHttp,
      acceptStatusCodes = acceptStatusCodes,
      rejectStatusCodes = rejectStatusCodes,
    )

  try:
    discard response.check(
      url               = url,
      acceptStatusCodes = acceptStatusCodes,
      rejectStatusCodes = rejectStatusCodes,
    )
  except:
    # reattempt the request with retries as above response error
    # might be transient however however never retried as
    # status code is never checked on the first call
    response = safeRequest(
      url               = url,
      httpMethod        = httpMethod,
      body              = body,
      headers           = authHeaders,
      multipart         = multipart,
      retries           = retries,
      firstRetryDelayMs = firstRetryDelayMs,
      timeout           = timeout,
      pinnedCert        = pinnedCert,
      verifyMode        = verifyMode,
      maxRedirects      = maxRedirects,
      disallowHttp      = disallowHttp,
      acceptStatusCodes = acceptStatusCodes,
      rejectStatusCodes = rejectStatusCodes,
    )

  return (newHeaders, response)

proc authSafeRequest*(url: Uri | string,
                      httpMethod: HttpMethod | string = HttpGet,
                      body = "",
                      headers: HttpHeaders = newHttpHeaders(),
                      multipart: MultipartData = nil,
                      retries: int = 0,
                      firstRetryDelayMs: int = 0,
                      timeout: int = 1000,
                      pinnedCert: string = "",
                      verifyMode = CVerifyPeer,
                      maxRedirects: int = 3,
                      disallowHttp: bool = false,
                      acceptStatusCodes: openArray[Slice[int]] = @[],
                      rejectStatusCodes: openArray[Slice[int]] = @[],
                      ): Response =
  let (_, response) = authHeadersSafeRequest(
    url               = url,
    httpMethod        = httpMethod,
    body              = body,
    headers           = headers,
    multipart         = multipart,
    retries           = retries,
    firstRetryDelayMs = firstRetryDelayMs,
    timeout           = timeout,
    pinnedCert        = pinnedCert,
    verifyMode        = verifyMode,
    maxRedirects      = maxRedirects,
    disallowHttp      = disallowHttp,
    acceptStatusCodes = acceptStatusCodes,
    rejectStatusCodes = rejectStatusCodes,
  )
  return response
