##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[net, os]
import "."/[chalkjson, config, selfextract, plugin_api, semver, util]
import "./attestation"/[embed, get, utils]
import "./docker"/[ids]
export getCosignLocation, canVerifyByHash, canVerifyBySigStore # from utils

proc writeSelfConfig(selfChalk: ChalkObj): bool {.importc, discardable.}

let keyProviders = {
  embedProvider.name:  AttestationKeyProvider(embedProvider),
  getProvider.name:    AttestationKeyProvider(getProvider),
}.toTable()

var cosignKey = AttestationKey(nil)

proc getCosignKey(chalk: ChalkObj): AttestationKey =
  let pubKey = unpack[string](chalk.extract["INJECTOR_PUBLIC_KEY"])
  return AttestationKey(publicKey: pubKey)

proc getProvider(): AttestationKeyProvider =
  let name = attrGet[string]("attestation.key_provider")
  if name notin keyProviders:
    raise newException(KeyError, "Unsupported attestation key provider: " & name)
  return keyProviders[name]

proc loadCosignKeyFromSelf(): AttestationKey =
  result = AttestationKey()

  let selfOpt = getSelfExtraction()
  if selfOpt.isNone():
    return result

  let selfChalk = selfOpt.get()
  if selfChalk.extract == nil:
    return result

  let extract = selfChalk.extract
  if "$CHALK_PUBLIC_KEY" in extract:
    result.publicKey = unpack[string](extract["$CHALK_PUBLIC_KEY"])
  if "$CHALK_ENCRYPTED_PRIVATE_KEY" in extract:
    result.privateKey = unpack[string](extract["$CHALK_ENCRYPTED_PRIVATE_KEY"])

proc loadAttestation*() =
  # This should really only be called from chalk.nim.
  # Beyond that, call canAttest()

  once:
    let
      countOpt = selfChalkGetKey("$CHALK_LOAD_COUNT")
      countBox = countOpt.getOrElse(pack(0))
      count    = unpack[int](countBox)

    if count == 0:
      # Don't auto-load when compiling.
      return

    let
      cmd = getBaseCommandName()
      # TODO this will require private key for all
      # docker commands which is not ideal
      # but there is no easy mechanism to determine docker command here
      withPrivateKey = cmd in ["insert", "docker"]
    if cmd in ["setup", "help", "load", "dump", "version", "env", "exec"]:
      return

    cosignKey = loadCosignKeyFromSelf()
    if cosignKey == nil or not cosignKey.canAttestVerify():
      warn("Code signing not initialized. Run `chalk setup` to fix.")
      # there is no key in self chalkmark
      return

    let provider = getProvider()
    try:
      provider.init(provider)
    except:
      error("Attestation key provider is misconfigured: " & getCurrentExceptionMsg())
      return

    if withPrivateKey:
      try:
        cosignKey.password = provider.retrievePassword(provider, cosignKey)
      except:
        error("Could not retrieve cosign private key password: " & getCurrentExceptionMsg())
        return

      try:
        if not cosignKey.isValid():
          cosignKey = AttestationKey(nil)
          return
      except:
        cosignKey = AttestationKey(nil)
        return

proc saveKeyToSelf(key: AttestationKey): bool =
  let selfChalk = getSelfExtraction().get()
  selfChalk.extract["$CHALK_ENCRYPTED_PRIVATE_KEY"] = pack(key.privateKey)
  selfChalk.extract["$CHALK_PUBLIC_KEY"]            = pack(key.publicKey)

  let savedCommandName = getCommandName()
  setCommandName("setup")
  try:
    result = selfChalk.writeSelfConfig()
  finally:
    setCommandName(savedCommandName)

proc setupAttestation*() =
  info("Ensuring cosign is present to setup attestation.")
  try:
    if getCosignLocation(downloadCosign = true) == "":
      raise newException(ValueError, "Failed to get cosign binary")
  except:
    raise newException(ValueError, "Failed to get cosign binary: " & getCurrentExceptionMsg())

  let provider = getProvider()
  try:
    provider.init(provider)
  except:
    raise newException(ValueError, "Attestation key provider is misconfigured: " & getCurrentExceptionMsg())

  # a bit of nesting of exceptions to propagate appropriate error
  # to the user as key providers can optionally implement
  # retrieval/generation
  try:
    if provider.retrieveKey != nil:
      cosignKey = provider.retrieveKey(provider)
      if cosignKey == nil:
        raise newException(ValueError, "no key returned")
    else:
      raise newException(ValueError, "key retrieval not supported")
  except:
    let retrieveError = getCurrentExceptionMsg()
    if provider.generateKey == nil:
      raise newException(ValueError,
                        "Provider '" & provider.name & "' " &
                        "failed to retrieve existing key due to: " & retrieveError)
    trace("Could not retrieve key. Will attempt to generate. error: " & retrieveError)
    try:
      cosignKey = provider.generateKey(provider)
      if cosignKey == nil:
        raise newException(ValueError, "no key generated")
    except:
      let generateError = getCurrentExceptionMsg()
      raise newException(ValueError,
                         "Provider '" & provider.name & "' " &
                         "failed to retrieve existing key due to: " & retrieveError & "; " &
                         "and failed to generate new key due to: " & generateError)

  try:
    if not cosignKey.saveKeyToSelf():
      raise newException(ValueError, "Failed to store generated attestation key to chalk")
  except:
    raise newException(ValueError, "Failed to store generated attestation key to chalk: " & getCurrentExceptionMsg())

# ----------------------------------------------------------------------------
# signing/validating logic

proc willSign(): bool =
  if not cosignKey.canAttest():
    return false
  # We sign artifacts if either condition is true.
  if isSubscribedKey("SIGNATURE") or attrGet[bool]("always_try_to_sign"):
    return true
  trace("Artifact signing not configured.")
  return false

proc willSignByHash*(chalk: ChalkObj): bool =
  # If there's no associated fs ref, it's either a container or
  # something we don't have permission to read; either way, it's not
  # getting signed in this flow.
  return willSign() and chalk.canVerifyByHash()

proc willSignBySigStore*(chalk: ChalkObj): bool =
  return willSign() and chalk.canVerifyBySigStore()

proc verifyBySigStore(chalk: ChalkObj, key: AttestationKey, image: DockerImage): (ValidateResult, ChalkDict) =
  let
    spec   = image.asRepoDigest()
    log    = attrGet[bool]("use_transparency_log")
    cosign = getCosignLocation()
  var
    dict   = ChalkDict()
    args   = @["verify-attestation",
               "--insecure-ignore-tlog=" & $(not log),
               "--key=chalk.pub",
               "--type=custom",
               "--verbose"]
    # https://github.com/sigstore/cosign/blob/main/CHANGELOG.md#v222
  if not log and getCosignVersion() >= parseVersion("2.2.2"):
    args.add("--private-infrastructure=true")
  args.add(spec)
  info("cosign: verifying attestation for " & spec)
  trace("cosign " & args.join(" "))
  let
    allOut = runCmdGetEverything(cosign, args)
    res    = allOut.getStdout()
    err    = allOut.getStderr()
    code   = allOut.getExit()
  if code == 0:
    let
      blob = parseJson(res)
      sigs = blob["signatures"]
    dict["_SIGNATURES"] = sigs.nimJsonToBox()
    trace("in-toto signatures are: " & $sigs)
    info(spec & ": Successfully validated signature.")
    return (vSignedOk, dict)
  else:
    if "MANIFEST_UNKNOWN" in err or "manifest unknown" in err:
      trace("cosign: no attestation at " & spec)
      return (vNoHash, dict)
    else:
      # note that we fail hard on any connection/auth errors
      trace("Verification failed: " & allOut.getStdErr())
      warn(spec & ": Did not validate signature.")
      return (vBadSig, dict)

proc verifyBySigStore*(chalk: ChalkObj): (ValidateResult, ChalkDict) =
  ## Used both for validation, and for downloading just the signature
  ## after we've signed.
  var
    key  = cosignKey
    dict = ChalkDict()
  if chalk.noCosign:
    return (vNoHash, dict)
  if not isChalkingOp():
    if "INJECTOR_PUBLIC_KEY" notin chalk.extract:
      warn(chalk.name & ": Bad chalk mark; missing INJECTOR_PUBLIC_KEY")
      return (vNoPk, dict)
    key = chalk.getCosignKey()
  if not key.canAttestVerify():
    warn(chalk.name & ": Signed but cannot validate; run `chalk setup` to fix")
    return (vNoCosign, dict)

  key.withCosignKey:
    for image in chalk.repos.manifests:
      let (valid, dict) = chalk.verifyBySigStore(key, image)
      if valid == vNoHash:
        continue
      return (valid, dict)

  trace("cosign: " & chalk.name & ": no attestations were found to verify")
  return (vNoHash, dict)

proc signBySigStore*(chalk: ChalkObj): ChalkDict =
  result = ChalkDict()
  cosignKey.withCosignKey:
    for image in chalk.repos.manifests:
      let
        spec    = image.asRepoDigest()
        mark    = chalk.getChalkMarkAsStr()
        log     = attrGet[bool]("use_transparency_log")
        cosign  = getCosignLocation()
        args    = @["attest",
                    "--tlog-upload=" & $log,
                    "--yes",
                    "--key=chalk.key",
                    "--type=custom",
                    "--predicate=-",
                    spec]
        toto    = """
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": """ & escapeJson(image.repo) & """,
      "config.digest": { "sha256": """ & escapeJson(chalk.imageId) & """},
      "digest": { "sha256": """ & escapeJson(image.digest) & """}
    }
  ],
  "predicateType": "https://in-toto.io/attestation/scai/attribute-report/v0.2",
  "predicate": {
    "attributes": [
      {
        "attribute": "CHALK",
        "evidence": """ & escapeJson(mark) & """
      }
    ]
  }
}
"""
      info("cosign: pushing attestation for " & spec)
      trace("cosign " & args.join(" ") & "\n" & toto)
      let
        allOut = runCmdGetEverything(cosign, args, toto)
        code   = allOut.getExit()
      if code != 0:
        raise newException(
          ValueError,
          "Cosign error: " & allOut.getStderr()
        )
      chalk.signed   = true
      chalk.noCosign = false
      try:
        # fetch the _SIGNATURES from sig-store
        # as attest command does not show signature back :facepalm:
        let (_, dict) = chalk.verifyBySigStore(cosignKey, image)
        result.merge(dict)
      except:
        error("cosign: failed to fetch signature: " & getCurrentExceptionMsg())

proc signByHash*(chalk: ChalkObj, mdHash : string): ChalkDict =
  ## sign chalkmark by artifact/metadata hash
  ## this only applies to signing files
  result = ChalkDict()
  let artHash = chalk.callGetUnchalkedHash().get("")
  if artHash == "":
    raise newException(
      ValueError,
      "No hash available for this artifact at time of signing."
    )
  let
    log  = attrGet[bool]("use_transparency_log")
    args = @["sign-blob",
             "--tlog-upload=" & $log,
             "--yes",
             "--key=chalk.key",
             "-"]
    blob = artHash & mdHash
  info("cosign: signing file " & chalk.name)
  trace("signing blob: " & blob)
  trace("cosign " & args.join(" "))
  cosignKey.withCosignKey:
    let
      cosign    = getCosignLocation()
      allOutput = runCmdGetEverything(cosign, args, blob & "\n")
      signature = allOutput.getStdout().strip()
    if signature == "":
      raise newException(
        ValueError,
        "Cosign error: " & allOutput.getStderr()
      )
    result["SIGNING"]             = pack(true)
    result["SIGNATURE"]           = pack(signature)
    result["INJECTOR_PUBLIC_KEY"] = pack(cosignKey.publicKey)
    chalk.signed = true
    forceChalkKeys(["SIGNING", "SIGNATURE", "INJECTOR_PUBLIC_KEY"])

proc verifyByHash*(chalk: ChalkObj, mdHash: string): ValidateResult =
  ## verify chalkmark signature by artifact/metadata hash
  ## this only applies to signing files
  if "SIGNATURE" notin chalk.extract:
    if "SIGNING" in chalk.extract and unpack[bool](chalk.extract["SIGNING"]):
      error(chalk.name & ": SIGNING was set, but SIGNATURE was not found")
      return vBadMd
    else:
      return vOk

  if "INJECTOR_PUBLIC_KEY" notin chalk.extract:
    error(chalk.name & ": Bad chalk mark; signed, but missing INJECTOR_PUBLIC_KEY")
    return vNoPk

  if not cosignKey.canAttestVerify():
    warn(chalk.name & ": Signed but cannot validate; run `chalk setup` to fix")
    return vNoCosign

  let artHash = chalk.callGetUnchalkedHash().get("")
  if artHash == "":
    return vNoHash

  let
    sig    = unpack[string](chalk.extract["SIGNATURE"])
    noTlog = not attrGet[bool]("use_transparency_log")
    args   = @["verify-blob",
               "--insecure-ignore-tlog=" & $noTlog,
               "--key=chalk.pub",
               "--signature=" & sig,
               "--insecure-ignore-sct=true",
               "-"]
    cosign = getCosignLocation()
    blob   = artHash & mdHash
    key    = chalk.getCosignKey()

  info("cosign: verifying file " & chalk.name)
  trace("verifying blob: " & blob)
  trace("cosign " & args.join(" "))

  key.withCosignKey:
    let allOutput = runCmdGetEverything(cosign, args, blob & "\n")

    if allOutput.getExit() == 0:
      info(chalk.name & ": Signature successfully validated.")
      return vSignedOk
    else:
      info(chalk.name & ": Signature failed. Cosign reported: " &
           allOutput.getStderr())
      return vBadSig
