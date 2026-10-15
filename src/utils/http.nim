##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  httpclient,
  httpcore,
  strutils,
]
import pkg/nimutils/[
  sha,
]
import ".."/[
  config,
  run_management,
  types,
]

export httpclient
export httpcore

proc update*(self: HttpHeaders, with: HttpHeaders): HttpHeaders =
  for k, v in with.pairs():
    self[k] = v
  return self

proc mustGet*(headers: HttpHeaders, header: string, msg: string): string =
  if not headers.hasKey(header):
    raise newException(ValueError, msg)
  return headers[header]

proc mustGetInt*(headers: HttpHeaders, header: string, msg: string): int =
  let value = headers.mustGet(header, msg)
  try:
    return parseInt(value)
  except:
    raise newException(ValueError, msg & ": invalid integer: " & value)

proc addChalkCoreHeaders*(
    headers: HttpHeaders,
    body:    string,
    digest  = "",
): HttpHeaders =
  ## Merges chalk core headers into `headers`, applying them last so they
  ## take precedence over any same-named user-configured header.
  ## _ACTION_ID is guarded: absent when no report template subscribes it.
  ## digest defaults to sha256(body) when not provided.
  headers["X-Chalk-Version"]       = getChalkExeVersion()
  headers["X-Chalk-Operation"]     = getBaseCommandName()
  headers["X-Content-Length"]      = $len(body)
  headers["X-Chalk-Digest-Sha256"] = if digest != "": digest else: body.sha256Hex()
  let actionId = lookupCollectedKey("_ACTION_ID")
  if actionId.isSome():
    headers["X-Chalk-Action-Id"] = unpack[string](actionId.get())
  return headers

proc addForwardedHeaders*(headers: HttpHeaders, response: Response): HttpHeaders =
  ## Copies headers listed in the response's x-forward-headers into headers.
  ## Allows the sign server to request that specific response headers be
  ## forwarded to the actual upload request (e.g. extra metadata headers).
  if not response.headers.hasKey("x-forward-headers"):
    return headers
  for item in response.headers["x-forward-headers"].strip().split(','):
    let name = item.strip()
    if response.headers.hasKey(name):
      headers[name] = response.headers[name]
  return headers

proc nextLink*(link: string): string =
  ## The `rel="next"` URL of a `Link` header, empty when there is none.
  ## https://docs.github.com/en/rest/using-the-rest-api/using-pagination-in-the-rest-api
  ## https://www.rfc-editor.org/rfc/rfc8288#section-3
  for entry in link.split(','):
    let parts = entry.split(';')
    let target = parts[0].strip()
    if len(parts) < 2 or not target.startsWith('<') or not target.endsWith('>'):
      continue
    for param in parts[1 .. ^1]:
      let pair = param.split('=', maxsplit = 1)
      if len(pair) != 2 or pair[0].strip().toLowerAscii() != "rel":
        continue
      # `rel` may list several relation types
      for rel in pair[1].strip().strip(chars = {'"'}).splitWhitespace():
        if rel.toLowerAscii() == "next":
          return target[1 .. ^2]
  return ""
