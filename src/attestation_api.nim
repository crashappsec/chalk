##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[base64, net, os]
import "."/[chalk_common, chalkjson, config, selfextract]
import ./attestation/[embed, backup, get, utils]
export getCosignLocation # from utils

proc writeSelfConfig(selfChalk: ChalkObj): bool {.importc, discardable.}

let keyProviders = {
  embedProvider.name:  AttestationKeyProvider(embedProvider),
  backupProvider.name: AttestationKeyProvider(backupProvider),
  getProvider.name:    AttestationKeyProvider(getProvider),
}.toTable()

var cosignKey = AttestationKey(nil)

proc canAttest*(): bool =
  return cosignKey.canAttest()

proc getProvider(): AttestationKeyProvider =
  let name = get[string](chalkConfig, "attestation.key_provider")
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
# Everything below is related to actually signing/validating an artifact

proc writeInToto(info:      DockerInvocation,
                 tag:       string,
                 digestStr: string,
                 mark:      string,
                 cosign:    string): bool =
  let
    randint = secureRand[uint]()
    hexval  = toHex(randint and 0xffffffffffff'u).toLowerAscii()
    path    = "chalk-toto-" & hexval & ".json"
    tagStr  = escapeJson(tag)
    hashStr = escapeJson(info.opChalkObj.cachedHash)
    toto    = """ {
    "_type": "https://in-toto.io/Statement/v1",
      "subject": [
        {
          "name": """ & tagStr & """,
          "digest": { "sha256": """ & hashstr & """}
        }
      ],
      "predicateType":
               "https://in-toto.io/attestation/scai/attribute-report/v0.2",
      "predicate": {
        "attributes": [{
          "attribute": "CHALK",
          "evidence": """ & mark & """
        }]
      }
  }
"""
  if not tryToWriteFile(path, toto):
    raise newException(OSError, "could not write toto to file: " & getCurrentExceptionMsg())

  let
    log  = $(get[bool](chalkConfig, "use_transparency_log"))
    args = @["attest", ("--tlog-upload=" & log), "--yes", "--key",
             "chalk.key", "--type", "custom", "--predicate", path,
              digestStr]

  info("Pushing attestation via: `cosign " & args.join(" ") & "`")
  let
    allOut = runCmdGetEverything(cosign, args)
    code   = allout.getExit()

  if code == 0:
    return true
  else:
    return false

proc callC4mPushAttestation*(info: DockerInvocation, mark: string): bool =
  let chalk = info.opChalkObj

  if chalk.repo == "" or chalk.repoHash == "":
    trace("Could not find appropriate info needed for attesting")
    return false

  trace("Writing chalk mark via in toto attestation for image id " &
    chalk.imageId & " with sha256 hash of " & chalk.repoHash)

  cosignKey.withCosignKey:
    result = info.writeInToto(chalk.repo,
                              chalk.repo & "@sha256:" & chalk.repoHash,
                              mark, getCosignLocation())
  if result:
    chalk.signed = true

template pushAttestation*(ctx: DockerInvocation) =
  if not canAttest():
    return

  trace("Attempting to write chalk mark to attestation layer")
  try:
    if not ctx.callC4mPushAttestation(ctx.opChalkObj.getChalkMarkAsStr()):
      warn("Attestation failed.")
    else:
      info("Pushed attestation successfully.")
  except:
    dumpExOnDebug()
    error("Exception occurred during attestation")

proc coreVerify(key: AttestationKey, chalk: ChalkObj): bool =
  ## Used both for validation, and for downloading just the signature
  ## after we've signed.
  const fName = "chalk.pub"
  let noTlog  = not get[bool](chalkConfig, "use_transparency_log")

  key.withCosignKey:
    let
      args   = @["verify-attestation",
                 "--key", fName,
                 "--insecure-ignore-tlog=" & $(noTlog),
                 "--type", "custom",
                 chalk.repo & "@sha256:" & chalk.repoHash]
      cosign = getCosignLocation()
    let
      allOut = runCmdGetEverything(cosign, args)
      res    = allout.getStdout()
      code   = allout.getExit()

    if code != 0:
      trace("Verification failed: " & allOut.getStdErr())
      result = false
    else:
      let
        blob = parseJson(res)
        sig  = blob["signatures"].getElems()[0]

      chalk.collectedData["_SIGNATURE"] = sig.nimJsonToBox()
      trace("Signature is: " & $(blob["signatures"].getElems()[0]))
      result = true

proc extractSigAndValidateNonInsert(chalk: ChalkObj) =
  if "INJECTOR_PUBLIC_KEY" notin chalk.extract:
    warn("Signer did not add their public key to the mark; cannot validate")
    chalk.setIfNeeded("_VALIDATED_SIGNATURE", false)
  elif chalk.repo == "" or chalk.repoHash == "":
    chalk.setIfNeeded("_VALIDATED_SIGNATURE", false)
  else:
    let
      pubKey = unpack[string](chalk.extract["INJECTOR_PUBLIC_KEY"])
      key    = AttestationKey(publicKey: pubKey)
      ok     = coreVerify(key, chalk)
    if ok:
      chalk.setIfNeeded("_VALIDATED_SIGNATURE", true)
      info(chalk.name & ": Successfully validated signature.")
    else:
      chalk.setIfNeeded("_INVALID_SIGNATURE", true)
      warn(chalk.name & ": Could not extract valid mark from attestation.")

proc extractSigAndValidateAfterInsert(chalk: ChalkObj) =
  let ok = coreVerify(cosignKey, chalk)
  if ok:
    info("Confirmed attestation and collected signature.")
  else:
    warn("Error collecting attestation signature.")

proc extractAndValidateSignature*(chalk: ChalkObj) {.exportc,cdecl.} =
  if not cosignKey.canAttestVerify():
    return
  if not chalk.signed:
    info(chalk.name & ": Not signed.")
  if getCommandName() in ["build", "push"]:
    chalk.extractSigAndValidateAfterInsert()
  else:
    chalk.extractSigAndValidateNonInsert()

proc extractAttestationMark*(chalk: ChalkObj): ChalkDict =
  result = ChalkDict(nil)

  if not cosignKey.canAttestVerify():
    return

  if chalk.repo == "":
    info("Cannot look for attestation mark w/o repo info")
    return

  let
    refStr = chalk.repo & "@sha256:" & chalk.repoHash
    args   = @["download", "attestation", refStr]
    cosign = getCosignLocation()

  trace("Attempting to download attestation via: cosign " & args.join(" "))

  let
    allout = runCmdGetEverything(cosign, args)
    res    = allOut.getStdout()
    code   = allout.getExit()

  if code != 0:
    info(chalk.name & ": No attestation found.")
    return

  try:
    let
      json      = parseJson(res)
      payload   = parseJson(json["payload"].getStr().decode())
      data      = payload["predicate"]["Data"].getStr().strip()
      predicate = parseJson(data)["predicate"]
      attrs     = predicate["attributes"].getElems()[0]
      rawMark   = attrs["evidence"]

    chalk.cachedMark = $(rawMark)

    result = extractOneChalkJson(newStringStream(chalk.cachedMark), chalk.name)
    info("Successfully extracted chalk mark from attestation.")
  except:
    info(chalk.name & ": Bad attestation found.")

proc willSignNonContainer*(chalk: ChalkObj): string =
  ## sysDict is the chlak dict the metsys plugin is currently
  ## operating on.  The items in it will get copied into
  ## chalk.collectedData after the plugin returns.

  if not canAttest():
    # They've already been warn()'d.
    return ""

  # We sign non-container artifacts if either condition is true.
  if not (isSubscribedKey("SIGNATURE") or get[bool](chalkConfig, "always_try_to_sign")):
    trace("File artifact signing not configured.")
    return ""

  # If there's no associated fs ref, it's either a container or
  # something we don't have permission to read; either way, it's not
  # getting signed in this flow.
  if chalk.fsRef == "":
    return ""

  let
    pubKeyOpt = selfChalkGetKey("$CHALK_PUBLIC_KEY")

  return unpack[string](pubKeyOpt.get())

proc signNonContainer*(chalk: ChalkObj, unchalkedMD, metadataMD : string):
                     string =
  let
    log    = $(get[bool](chalkConfig, "use_transparency_log"))
    args   = @["sign-blob", ("--tlog-upload=" & log), "--yes", "--key",
               "chalk.key", "-"]
    blob   = unchalkedMD & metadataMD

  trace("signing blob: " & blob )
  cosignKey.withCosignKey:
    let cosign = getCosignLocation()
    let allOutput = runCmdGetEverything(cosign, args, blob & "\n")

    result = allOutput.getStdout().strip()

    if result == "":
      error(chalk.name & ": Signing failed. Cosign error: " &
        allOutput.getStderr())

proc cosignNonContainerVerify*(chalk: ChalkObj,
                               artHash, mdHash, sig, pk: string):
                              ValidateResult =
  let
    log    = $(not get[bool](chalkConfig, "use_transparency_log"))
    args   = @["verify-blob",
               "--insecure-ignore-tlog=" & log,
               "--key=chalk.pub",
               "--signature=" & sig,
               "--insecure-ignore-sct=true",
               "-"]
    blob   = artHash & mdHash
    key    = AttestationKey(publicKey: pk)

  trace("blob = >>" & blob & "<<")
  key.withCosignKey:
    let cosign = getCosignLocation()
    let allOutput = runCmdGetEverything(cosign, args, blob & "\n")

    if allOutput.getExit() == 0:
      info(chalk.name & ": Signature successfully validated.")
      return vSignedOk
    else:
      info(chalk.name & ": Signature failed. Cosign reported: " &
        allOutput.getStderr())
      return vBadSig
