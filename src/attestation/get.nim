##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[httpclient, net]
import ".."/[chalk_common, config, sinks, util]

proc request(self: AttestationKeyProvider, query = ""): JsonNode =
  let
    url         = self.getUrl & query
  var
    headers     = newHttpHeaders()
    authHeaders = self.getAuth.implementation.injectHeaders(self.getAuth, headers)
    response:   Response

  try:
    response = safeRequest(url               = url,
                           httpMethod        = HttpGet,
                           headers           = authHeaders,
                           timeout           = self.getTimeout,
                           retries           = 2,
                           firstRetryDelayMs = 100)

    trace("Signing Key Provider Service URL: " & url)
    trace("Signing Key Provider Service status code: " & response.status)
    trace("Signing Key Provider Service response[:15]: " & response.bodyStream.peekStr(15)) # truncate not to leak secrets
  except:
    error("Could not call Signing Key Provider Service: " & getCurrentExceptionMsg())
    raise

  if not response.code.is2xx():
    error("Signing Key Provider Service returned invalid response: " & response.status)
    raise newException(ValueError, "API Error")

  try:
    return parseJson(response.body())
  except:
    error("Signing Key Provider Service returned invalid response: " & getCurrentExceptionMsg())
    raise

proc init(self: AttestationKeyProvider) =
  let
    getConfig = chalkConfig.attestationConfig.attestationKeyGetConfig
    authName  = getConfig.getAuth()
    authOpt   = getAuthConfigByName(authName)
    url       = getConfig.getUri().removeSuffix("/")
    timeout   = cast[int](getConfig.getTimeout())

  if authOpt.isNone():
    raise newException(ValueError,
                       "auth_config." & authName &
                       " is required to use signing key retrieval service")

  if url == "":
    raise newException(ValueError,
                       "attestation.attestation_key_get.uri " &
                       " is required to use signing key retrieval service")

  self.getAuth     = authOpt.get()
  self.getUrl      = url
  self.getTimeout  = timeout

proc retrieveKey(self: AttestationKeyProvider): AttestationKey =
  let
    data = self.request()
    key  = AttestationKey(
      privateKey: data{"privateKey"}.getStr(""),
      publicKey: data{"publicKey"}.getStr(""),
      password: data{"password"}.getStr(""),
    )
  if key.privateKey == "" or key.publicKey == "" or key.password == "":
    raise newException(ValueError, "Signing Key Provider Service did not return valid attestation key")
  info("Retrieved attestion key from Signing Key Provider Service")
  return key

proc retrievePassword(self: AttestationKeyProvider, key: AttestationKey): string =
  let
    data     = self.request(query = "?only=password")
    password = data{"password"}.getStr("")
  if password == "":
    raise newException(ValueError, "Signing Key Provider Service did not return key password")
  info("Retrieved attestation key password from Signing Key Provider Service")
  return password

let getProvider* = AttestationKeyProvider(
  name:             "get",
  kind:             get,
  init:             init,
  retrieveKey:      retrieveKey,
  retrievePassword: retrievePassword,
)
