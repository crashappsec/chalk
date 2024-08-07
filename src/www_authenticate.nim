##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Very basic implementation of https://www.rfc-editor.org/rfc/rfc7235#section-4.1
## Currently only bearer challenge is supported

import std/[httpclient, uri, tables, strutils, json, sequtils]
import pkg/nimutils/net
import "."/[config]

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

proc elicitHeaders(self: AuthChallenge): HttpHeaders =
  case self.kind:
  of other:
    raise newException(ValueError, "unsupported auth challenge scheme: " & self.scheme)
  of bearer:
    trace("http: fetching bearer token from: " & self.url)
    let tokenResponse = safeRequest(self.url)
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
    return newHttpHeaders({"Authorization": "Bearer " & token})

proc elicitHeaders*(challenges: seq[AuthChallenge]): HttpHeaders =
  result = newHttpHeaders()
  for challenge in challenges:
    try:
      return challenge.elicitHeaders()
    except:
      continue

proc parseAuthChallenge(data: string): AuthChallenge =
  let typeAndOptions = data.split(maxsplit = 1)
  if len(typeAndOptions) != 2:
    raise newException(ValueError, "invalid auth challenge: " & data)
  let scheme  = typeAndOptions[0].toLower()
  var allOptions = initOrderedTable[string, string]()
  for option in typeAndOptions[1].split(","):
    if option.strip() == "":
      continue
    let keyValue = option.split("=", maxsplit = 1)
    if len(keyValue) != 2:
      raise newException(ValueError, "invalid auth challenge option: " & option)
    let
      key   = keyValue[0].strip()
      value = keyValue[1].strip().strip(chars = {'"'})
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
  var challenge = ""
  for word in data.split(seps = {' ', ','}):
    if word.strip() == "":
      continue
    if "=" notin word and challenge != "":
      result.add(parseAuthChallenge(challenge.strip(chars = {' ', ','})))
      challenge = ""
    if challenge == "":
      challenge = word & " "
    else:
      challenge &= word & ","
  if challenge != "":
    result.add(parseAuthChallenge(challenge.strip(chars = {' ', ','})))

var authByHost = initTable[string, HttpHeaders]()

proc authSafeRequest*(url: Uri | string,
                      httpMethod: HttpMethod | string = HttpGet,
                      body = "",
                      headers: HttpHeaders = newHttpHeaders(),
                      multipart: MultipartData = nil,
                      retries: int = 0,
                      firstRetryDelayMs: int = 0,
                      timeout: int = 1000,
                      pinnedCert: string = "",
                      maxRedirects: int = 3,
                      disallowHttp: bool = false,
                      only2xx: bool = false,
                      raiseWhenAbove: int = 0,
                      ): Response =
  let uri =
    when url is string:
      parseUri(url)
    else:
      url

  var authHeaders = headers
  if uri.hostname in authByHost:
    for k, v in authByHost[uri.hostname]:
      if not authheaders.hasKey(k):
        authHeaders[k] = v

  result = safeRequest(url               = uri,
                       httpMethod        = httpMethod,
                       body              = body,
                       headers           = authHeaders,
                       multipart         = multipart,
                       retries           = retries,
                       firstRetryDelayMs = firstRetryDelayMs,
                       timeout           = timeout,
                       pinnedCert        = pinnedCert,
                       maxRedirects      = maxRedirects,
                       disallowHttp      = disallowHttp,
                       only2xx           = false,
                       raiseWhenAbove    = 0)

  if (
    result.code() == Http401 and
    result.headers.hasKey("www-authenticate")
  ):
    trace("http: eliciting auth headers via www-authenticate for " & $uri)
    let
      wwwAuthenticate = result.headers["www-authenticate"]
      challenges      = parseAuthChallenges(wwwAuthenticate)
      newHeaders      = challenges.elicitHeaders()
    authByHost[uri.hostname] = newHeaders
    for k, v in newHeaders.pairs():
      authHeaders[k] = v

    # reattempt request
    result = safeRequest(url               = uri,
                         httpMethod        = httpMethod,
                         body              = body,
                         headers           = authHeaders,
                         multipart         = multipart,
                         retries           = retries,
                         firstRetryDelayMs = firstRetryDelayMs,
                         timeout           = timeout,
                         pinnedCert        = pinnedCert,
                         maxRedirects      = maxRedirects,
                         disallowHttp      = disallowHttp,
                         only2xx           = false,
                         raiseWhenAbove    = 0)

  discard result.check(url            = url,
                       only2xx        = only2xx,
                       raiseWhenAbove = raiseWhenAbove)
