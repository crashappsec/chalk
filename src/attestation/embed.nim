##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[chalk_common, config]
import "."/utils

type Embed = ref object of AttestationKeyProvider
  filename:  string
  save_path: string
  get_paths: seq[string]

proc initCallback(this: AttestationKeyProvider) =
  let self = Embed(this)
  self.filename  = attrGet[string]("attestation.attestation_key_embed.filename")
  self.save_path = attrGet[string]("attestation.attestation_key_embed.save_path")
  self.get_paths = attrGet[seq[string]]("attestation.attestation_key_embed.get_paths")

proc generateKeyCallback(this: AttestationKeyProvider): AttestationKey =
  let self = Embed(this)
  result = mintCosignKey(self.save_path.joinPath(self.filename))
  echo()
  echo("------------------------------------------")
  echo("CHALK_PASSWORD=", result.password)
  echo("""------------------------------------------
Write this down. In future chalk commands, you will need
to provide it via CHALK_PASSWORD environment variable.
""")

proc retrieveKeyCallback(this: AttestationKeyProvider): AttestationKey =
  let
    self      = Embed(this)
    (dir, _)  = getMyAppPath().splitPath()
    password  = getChalkPassword()
  var lastError = "no paths to lookup key"
  for i in self.get_paths:
    let path = i.replace("$CHALK", dir).joinPath(self.filename)
    try:
      result = getCosignKeyFromDisk(path, password = password)
      info("Loaded existing attestation keys from: " & path)
      return
    except:
      lastError = getCurrentExceptionMsg()
  raise newException(ValueError, "Could not retrieve key: " & lastError)

proc retrievePasswordCallback(this: AttestationKeyProvider, key: AttestationKey): string =
  return getChalkPassword()

let embedProvider* = Embed(
  name:             "embed",
  init:             initCallback,
  generateKey:      generateKeyCallback,
  retrieveKey:      retrieveKeyCallback,
  retrievePassword: retrievePasswordCallback,
)
