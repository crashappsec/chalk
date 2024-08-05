##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[httpclient, net]
import ".."/[chalk_common, config, sinks, util]

type Get = ref object of AttestationKeyProvider
  location: string
  url:      string
  timeout:  int
  auth:     AuthConfig

proc request(self: Get, query = ""): JsonNode =
  let url       = self.url & query
  var
    headers     = newHttpHeaders()
    authHeaders = self.auth.implementation.injectHeaders(self.auth, headers)
    response:   Response

  try:
    response = safeRequest(url               = url,
                           httpMethod        = HttpGet,
                           headers           = authHeaders,
                           timeout           = self.timeout,
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

proc initCallback(this: AttestationKeyProvider) =
  let
    self      = Get(this)
    authName  = attrGet[string]("attestation.attestation_key_get.auth")
    authOpt   = getAuthConfigByName(authName)
    url       = attrGet[string]("attestation.attestation_key_get.uri").removeSuffix("/")
    timeout   = cast[int](attrGet[Con4mDuration]("attestation.attestation_key_get.timeout"))

  if authOpt.isNone():
    raise newException(ValueError,
                       "auth_config." & authName &
                       " is required to use signing key retrieval service")

  if url == "":
    raise newException(ValueError,
                       "attestation.attestation_key_get.uri " &
                       " is required to use signing key retrieval service")

  self.auth     = authOpt.get()
  self.url      = url
  self.timeout  = timeout

proc retrieveKeyCallback(this: AttestationKeyProvider): AttestationKey =
  let
    self = Get(this)
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

proc retrievePasswordCallback(this: AttestationKeyProvider, key: AttestationKey): string =
  let
    self     = Get(this)
    data     = self.request(query = "?only=password")
    password = data{"password"}.getStr("")
  if password == "":
    raise newException(ValueError, "Signing Key Provider Service did not return key password")
  info("Retrieved attestation key password from Signing Key Provider Service")
  return password

let getProvider* = Get(
  name:             "get",
  init:             initCallback,
  retrieveKey:      retrieveKeyCallback,
  retrievePassword: retrievePasswordCallback,
)
