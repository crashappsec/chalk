##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[chalk_common, config]
import "."/utils

type Embed = ref object of AttestationKeyProvider
  location: string

proc initCallback(this: AttestationKeyProvider) =
  let
    self        = Embed(this)
    location    = get[string](getChalkScope(), "attestation.attestation_key_embed.location")
  self.location = location

proc generateKeyCallback(this: AttestationKeyProvider): AttestationKey =
  let self = Embed(this)
  result = mintCosignKey(self.location)
  echo()
  echo("------------------------------------------")
  echo("CHALK_PASSWORD=", result.password)
  echo("""------------------------------------------
Write this down. In future chalk commands, you will need
to provide it via CHALK_PASSWORD environment variable.
""")

proc retrieveKeyCallback(this: AttestationKeyProvider): AttestationKey =
  let self = Embed(this)
  result = getCosignKeyFromDisk(self.location)
  info("Loaded existing attestation keys from: " & self.location)

proc retrievePasswordCallback(this: AttestationKeyProvider, key: AttestationKey): string =
  return getChalkPassword()

let embedProvider* = Embed(
  name:             "embed",
  init:             initCallback,
  generateKey:      generateKeyCallback,
  retrieveKey:      retrieveKeyCallback,
  retrievePassword: retrievePasswordCallback,
)
