##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[base64, httpclient, net]
import ".."/[chalk_common, config, sinks, util]
import "."/utils

const
  obfuscatorCmd         = "dd status=none if=/dev/random bs=1 count=16 | base64"
  attestationObfuscator = staticExec(obfuscatorCmd).decode()

type Backup = ref object of AttestationKeyProvider
  location: string
  url:      string
  timeout:  int
  auth:     AuthConfig

proc id(self: AttestationKey): string =
  return sha256Hex(attestationObfuscator & self.privateKey)

proc request(self: Backup,
             key:  AttestationKey,
             body: string,
             mth:  HttpMethod): Response =
  # This is the id that will be used to identify the secret in the API
  let signingId = key.id()

  if mth == HttPGet:
    trace("Calling Signing Key Backup Service to retrieve key with ID: " & signingID)
  else:
    trace("Calling Signing Key Backup Service to store key with ID: " & signingID)

  let url = self.url & "/" & signingId

  var
    headers     = newHttpHeaders()
    authHeaders = self.auth.implementation.injectHeaders(self.auth, headers)

  # Call the API with authz header - rety twice with backoff
  try:
    let response = safeRequest(url               = url,
                               httpMethod        = mth,
                               headers           = authHeaders,
                               body              = body,
                               timeout           = self.timeout,
                               retries           = 2,
                               firstRetryDelayMs = 100)

    trace("Signing Key Backup Service URL: " & url)
    trace("Signing Key Backup Service status code: " & response.status)
    trace("Signing Key Backup Service response[:15]: " & response.bodyStream.peekStr(15)) # truncate not to leak secrets
    return response
  except:
    error("Could not call Signing Key Backup Service: " & getCurrentExceptionMsg())
    raise

proc backup(self: Backup,
            key:  AttestationKey) =
  var nonce: string
  let
    ct   = prp(attestationObfuscator, key.password, nonce)
    body = nonce.hex() & ct.hex()

  trace("Sending encrypted secret: " & body)
  let response = self.request(key, body, HttpPut)
  if response.code == Http405:
    info("This encrypted signing key is already backed up.")
  elif not response.code.is2xx():
    trace("Signing key backup service returned: " & response.body())
    raise newException(ValueError,
                       "When attempting to save encrypted signing key: " & response.status)
  else:
    info("Successfully stored encrypted signing key.")
    warn("Please Note: Encrypted signing keys that have not been READ in the previous 30 days will be deleted!")

proc restore(self: Backup,
             key:  AttestationKey): string =
  let response = self.request(key, "", HttpGet)
  if not response.code.is2xx():
    raise newException(
      ValueError,
      "Could not retrieve encrypted signing key: " &
      response.status & "\n" & "Will not be able to sign / verify."
    )

  let hexBits = response.body()
  var body: string

  try:
    body = parseHexStr(hexBits)
    if len(body) != 40:
      raise newException(
        ValueError,
        "Encrypted key returned from server is incorrect size. " &
        "Received " & $len(body) & "bytes, exected 40 bytes."
      )

  except:
    raise newException(
      ValueError,
      "When retrieving encrypted key, received an invalid " &
      "response from service: " & response.status
    )

  trace("Successfully retrieved encrypted key from backup service.")

  let
    nonce = body[0 ..< 16]
    ct    = body[16 .. ^1]

  return brb(attestationObfuscator, ct, nonce)

proc initCallback(this: AttestationKeyProvider) =
  let
    self         = Backup(this)
    backupConfig = chalkConfig.attestationConfig.attestationKeyBackupConfig
    authName     = backupConfig.getAuth()
    location     = backupConfig.getLocation()
    authOpt      = getAuthConfigByName(authName)
    url          = backupConfig.getUri().removeSuffix("/")
    timeout      = cast[int](backupConfig.getTimeout())

  if authOpt.isNone():
    raise newException(ValueError,
                       "auth_config." & authName &
                       " is required to use signing key backup service")

  if url == "":
    raise newException(ValueError,
                       "attestation.attestation_key_backup.uri " &
                       " is required to use signing key backup service")

  self.auth     = authOpt.get()
  self.url      = url
  self.timeout  = timeout
  self.location = location

proc generateKeyCallback(this: AttestationKeyProvider): AttestationKey =
  let self = Backup(this)
  result = mintCosignKey(self.location)
  try:
    self.backup(key = result)
    info("The ID of the backed up key is: " & result.id())
  except:
    error(getCurrentExceptionMsg())
    error("Could not backup password. Either try again later, or " &
          "use the below password with the CHALK_PASSWORD environment " &
          "variable. We attempt to store when attestation.key_provider = 'backup'.\n" &
          "If you forget the password, delete chalk.key and " &
          "chalk.pub before rerunning.")
    echo()
    echo("------------------------------------------")
    echo("CHALK_PASSWORD=", result.password)
    echo("""------------------------------------------)
Write this down. In future chalk commands, you will need
to provide it via CHALK_PASSWORD environment variable.
""")


proc retrieveKeyCallback(this: AttestationKeyProvider): AttestationKey =
  let self = Backup(this)
  result = getCosignKeyFromDisk(self.location)
  info("Loaded existing attestation keys from: " & self.location)
  try:
    self.backup(key = result)
  except:
    error(getCurrentExceptionMsg())
    error("Could not backup password. You will need to provide " &
          "CHALK_PASSWORD environment variable to keep using attestation.")

proc retrievePasswordCallback(this: AttestationKeyProvider, key: AttestationKey): string =
  let self = Backup(this)
  try:
    result = getChalkPassword()
  except:
    result = self.restore(key)
    info("Retrieved attestation key password from Signing Key Backup Service")

let backupProvider* = Backup(
  name:             "backup",
  init:             initCallback,
  generateKey:      generateKeyCallback,
  retrieveKey:      retrieveKeyCallback,
  retrievePassword: retrievePasswordCallback,
)
