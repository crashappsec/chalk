##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Very basic implementation of https://www.rfc-editor.org/rfc/rfc7235#section-4.1
## Currently only bearer chellenge is supported

import std/[httpclient, uri, tables, strutils, json]
import pkg/nimutils/net
import "."/[config, util]

type
  AuthChellengeType = enum
    bearer
    other

  AuthChellenge* = ref object
    scheme:    string
    options:   OrderedTable[string, string]
    case kind: AuthChellengeType
      of bearer:
        realm: string
        url:   string
      of other:
        discard

proc `$`(self: AuthChellenge): string =
  var options = ""
  for k, v in self.options.pairs():
    options &= k & "=\"" & v & "\","
  let value = self.scheme & " " & options
  return value.strip(chars = {' ', ','})

proc initOtherChellenge(scheme: string, options: OrderedTable[string, string]): AuthChellenge =
  return AuthChellenge(scheme:  scheme,
                       kind:    other,
                       options: options)

proc initBearerChellenge(options: var OrderedTable[string, string]): AuthChellenge =
  if "realm" notin options:
    raise newException(ValueError, "bearer chellenge doesnt have realm URL: " & $options)
  let realm = options["realm"]
  if not (realm.startsWith("http://") or realm.startsWith("https://")):
    raise newException(ValueError, "bearer chellenge realm is not http or https url: " & $options)
  options.del("realm")
  let uri = parseUri(realm) ? options.items()
  return AuthChellenge(scheme:  "bearer",
                       kind:    bearer,
                       options: options,
                       realm:   realm,
                       url:     $uri)

proc elicitHeaders*(self: AuthChellenge): HttpHeaders =
  case self.kind:
    of other:
      raise newException(ValueError, "unsupported auth chellenge scheme: " & self.scheme)
    of bearer:
      trace("docker: fetching manifest bearer token from: " & self.url)
      let tokenResponse = safeRequest(self.url)
      if not tokenResponse.code().is2xx():
        raise newException(ValueError,
                           "Bearer auth realm URL did not return valid response: " &
                           tokenResponse.status)
      let
        tokenBody  = tokenResponse.body()
        tokenJson  = parseJson(tokenBody)
        token      = tokenJson{"token"}.getStr()
      return newHttpHeaders({"Authorization": "Bearer " & token})

proc elicitHeaders*(chellenges: seq[AuthChellenge]): HttpHeaders =
  result = newHttpHeaders()
  for chellenge in chellenges:
    try:
      return chellenge.elicitHeaders()
    except:
      continue

proc parseAuthChellenge*(data: string): AuthChellenge =
  let typeAndOptions = data.split(maxsplit = 1)
  if len(typeAndOptions) != 2:
    raise newException(ValueError, "invalid auth chellenge: " & data)
  let
    scheme  = typeAndOptions[0].toLower()
    options = typeAndOptions[1].split(",")
  var allOptions = initOrderedTable[string, string]()
  for option in options:
    if option.strip() == "":
      continue
    let keyValue = option.split("=", maxsplit = 1)
    if len(keyValue) != 2:
      raise newException(ValueError, "invalid auth chellenge option: " & option)
    let
      key   = keyValue[0].strip()
      value = keyValue[1].strip().strip(chars = {'"'})
    allOptions[key] = value
  case scheme:
    of "bearer":
      return initBearerChellenge(allOptions)
    else:
      return initOtherChellenge(scheme, allOptions)

proc parseAuthChellenges*(data: string): seq[AuthChellenge] =
  # https://www.rfc-editor.org/rfc/rfc7235#section-4.1
  # for example:
  # www-authenticate: Bearer realm="https://public.ecr.aws/token/",service="public.ecr.aws",scope="aws"
  result = @[]
  let words = data.split(seps = {' ', ','})
  var chellenge = ""
  for word in words:
    if word.strip() == "":
      continue
    if "=" notin word and chellenge != "":
      result.add(parseAuthChellenge(chellenge.strip(chars = {' ', ','})))
      chellenge = ""
    if chellenge == "":
      chellenge = word & " "
    else:
      chellenge &= word & ","
  if chellenge != "":
    result.add(parseAuthChellenge(chellenge.strip(chars = {' ', ','})))
