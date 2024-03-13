##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import ".."/[chalk_common, config]
import "."/utils

proc init(self: AttestationKeyProvider) =
  let
    embedConfig = chalkConfig.attestationConfig.attestationKeyEmbedConfig
    location    = embedConfig.getLocation()
  self.embedLocation = location

proc generateKey(self: AttestationKeyProvider): AttestationKey =
  result = mintCosignKey(self.embedLocation)
  echo()
  echo("------------------------------------------")
  echo("CHALK_PASSWORD=", result.password)
  echo("""------------------------------------------
Write this down. In future chalk commands, you will need
to provide it via CHALK_PASSWORD environment variable.
""")

proc retrieveKey(self: AttestationKeyProvider): AttestationKey =
  result = getCosignKeyFromDisk(self.embedLocation)
  info("Loaded existing attestation keys from: " & self.embedLocation)

proc retrievePassword(self: AttestationKeyProvider, key: AttestationKey): string =
  return getChalkPassword()

let embedProvider* = AttestationKeyProvider(
  name:             "embed",
  kind:             embed,
  init:             init,
  generateKey:      generateKey,
  retrieveKey:      retrieveKey,
  retrievePassword: retrievePassword,
)
