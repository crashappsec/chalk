##
## Copyright (c) 2023-2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  base64,
  net,
]
import "."/[
  chalkjson,
  config,
  plugin_api,
  run_management,
  selfextract,
  types,
  utils/json,
  utils/times,
]
import "./attestation"/[
  embed,
  get,
  utils,
]
import "./docker"/[
  ids,
  manifest,
  registry,
]

export canVerifyByHash, canVerifyBySigStore # from utils

proc writeSelfConfig(selfChalk: ChalkObj): bool {.importc, discardable.}

let keyProviders = {
  embedProvider.name:  AttestationKeyProvider(embedProvider),
  getProvider.name:    AttestationKeyProvider(getProvider),
}.toTable()

var attestationKey = AttestationKey(nil)

proc getAttestationKey(chalk: ChalkObj): AttestationKey =
  let pubKey = unpack[string](chalk.extract["INJECTOR_PUBLIC_KEY"])
  return AttestationKey(publicKey: pubKey)

proc getProvider(): AttestationKeyProvider =
  let name = attrGet[string]("attestation.key_provider")
  if name notin keyProviders:
    raise newException(KeyError, "Unsupported attestation key provider: " & name)
  return keyProviders[name]

proc loadAttestationKeyFromSelf(): AttestationKey =
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

proc loadAttestation*(forceLoad = false, withPrivateKey = false) =
  let
    countOpt = selfChalkGetKey("$CHALK_LOAD_COUNT")
    countBox = countOpt.getOrElse(pack(0))
    count    = unpack[int](countBox)

  if count == 0:
    # Don't auto-load when compiling.
    return

  let
    cmd = getBaseCommandName()
    loadPrivateKey = cmd in ["insert"] or withPrivateKey
  if not forceLoad and cmd in [
    "setup",
    "help",
    "load",
    "dump",
    "version",
    "env",
    "exec",
    # docker calls this function explicitly when appropriate for its subcommands
    # e.g. no need to init attestation for docker version
    #      but we need it for docker build
    "docker",
  ]:
    return

  if attestationKey == nil:
    attestationKey = loadAttestationKeyFromSelf()
  if attestationKey == nil or not attestationKey.canAttestVerify():
    warn("Code signing not initialized. Run `chalk setup` to fix.")
    # there is no key in self chalkmark
    return

  let provider = getProvider()
  try:
    provider.init(provider)
  except:
    error("Attestation key provider is misconfigured: " & getCurrentExceptionMsg())
    return

  if loadPrivateKey:
    try:
      attestationKey.password = provider.retrievePassword(provider, attestationKey)
    except:
      error("Could not retrieve attestation private key password: " & getCurrentExceptionMsg())
      return

    try:
      if not attestationKey.isValid():
        attestationKey = AttestationKey(nil)
        return
    except:
      attestationKey = AttestationKey(nil)
      return

proc saveKeyToSelf(key: AttestationKey): bool =
  let selfChalk = getSelfExtraction().get()
  selfChalk.extract["$CHALK_ENCRYPTED_PRIVATE_KEY"] = pack(key.privateKey)
  selfChalk.extract["$CHALK_PUBLIC_KEY"]            = pack(key.publicKey)

  let savedCommandName = getFullCommandName()
  setFullCommandName("setup")
  try:
    result = selfChalk.writeSelfConfig()
  finally:
    setFullCommandName(savedCommandName)

proc setupAttestation*() =
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
      attestationKey = provider.retrieveKey(provider)
      if attestationKey == nil:
        raise newException(ValueError, "no key returned")
      if not attestationKey.isValid():
        raise newException(ValueError, "retrieved key is not valid")
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
      attestationKey = provider.generateKey(provider)
      if attestationKey == nil:
        raise newException(ValueError, "no key generated")
    except:
      let generateError = getCurrentExceptionMsg()
      raise newException(ValueError,
                         "Provider '" & provider.name & "' " &
                         "failed to retrieve existing key due to: " & retrieveError & "; " &
                         "and failed to generate new key due to: " & generateError)

  info("attestation: Configured attestation key. Saving it to chalk binary.")
  try:
    if not attestationKey.saveKeyToSelf():
      raise newException(ValueError, "Failed to store generated attestation key to chalk")
  except:
    raise newException(ValueError, "Failed to store generated attestation key to chalk: " & getCurrentExceptionMsg())

# ----------------------------------------------------------------------------
# signing/validating logic

proc willSign(): bool =
  if not attestationKey.canAttest():
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
  return willSign() and not chalk.skipAttestation and chalk.canVerifyByHash()

proc willSignBySigStore*(chalk: ChalkObj): bool =
  return willSign() and not chalk.skipAttestation and chalk.canVerifyBySigStore()

proc verifyBySigStore(chalk:        ChalkObj,
                      key:          AttestationKey,
                      image:        DockerImage,
                      fetchOci    = true,
                      fetchCosign = true,
                      ): (ValidateResult, ChalkDict) =
  trace("attestation: verifying attestation for " & $image)
  var
    dict      = ChalkDict()
    foundSome = false
  for (dsse, mark) in image.fetchDsseInTotoMark(fetchOci = fetchOci, fetchCosign = fetchCosign):
    trace("dsse in-toto statement: " & dsse.pretty())
    foundSome = true
    dsse.assertIs(JObject, "bad dsse envelope type")
    let
      payload    = base64.decode(dsse{"payload"}.getStr())
      signatures = dsse{"signatures"}.assertIs(JArray, "bad dsse envelope signatures type")
    for i in signatures.items():
      i.assertIs(JObject, "bad dsse signature type")
      if key.verify(payload.dsse(dsse{"payloadType"}.getStr()), i{"sig"}.getStr()):
        info($image & ": Successfully validated signature.")
        dict.setIfNotEmpty("_SIGNATURES", %(@[dsse]))
        break
    let extract = extractOneChalkJson(mark, $image)
    # the same key can be used for other chalkmarks
    # so make sure we are validating signature for the same chalk
    if extract.getOrDefault("METADATA_ID", pack("")) == chalk.collectedData["METADATA_ID"]:
      return (vSignedOk, dict)
    else:
      trace("attestation: has valid signature however chalkmark has mismatching METADATA_ID")
  if foundSome:
    warn($image & ": did not validate any matching attestation statement signatures")
    return (vBadSig, ChalkDict())
  else:
    trace("attestation: no dsse intoto statements to validate signature for " & $image)
    return (vNoAttestation, ChalkDict())

proc verifyBySigStore*(chalk: ChalkObj): (ValidateResult, ChalkDict) =
  ## Used both for validation, and for downloading just the signature
  ## after we've signed.
  var
    key  = attestationKey
    dict = ChalkDict()
  if chalk.noAttestation:
    return (vNoHash, dict)
  if not isChalkingOp():
    if "INJECTOR_PUBLIC_KEY" notin chalk.extract:
      warn(chalk.name & ": Bad chalk mark; missing INJECTOR_PUBLIC_KEY")
      return (vNoPk, dict)
    key = chalk.getAttestationKey()
  if not key.canAttestVerify():
    warn(chalk.name & ": Signed but cannot validate; run `chalk setup` to fix")
    return (vNoAttestation, dict)

  for image in chalk.repos.manifests:
    let (valid, dict) = chalk.verifyBySigStore(key, image)
    if valid == vNoAttestation:
      continue
    return (valid, dict)

  trace("attestation: " & chalk.name & ": no attestations were found to verify")
  return (vNoAttestation, dict)

proc signBySigStore*(chalk: ChalkObj,
                     image: DockerImage,
                     ): ChalkDict =
  result = ChalkDict()

  try:
    let (verify, _) = chalk.verifyBySigStore(attestationKey, image, fetchCosign = false)
    if verify == vSignedOk:
      trace("attestation: " & $image & " is already attested by chalk. skipping")
      return
  except:
    discard

  var manifest: DockerManifest
  let spec = image.asOciAttestation()
  try:
    manifest = spec.fetchListManifest(fetchManifests = true)
    trace("attestation: adding to existing manifest list")
  except RegistryResponseError:
    manifest = DockerManifest(
      name: spec,
      kind: DockerManifestType.list,
      mediaType: "application/vnd.oci.image.index.v1+json",
      manifests: @[],
    )
    trace("attestation: creating new manifest list")

  let
    mark    = parseJson(chalk.getChalkMarkAsStr())
    subject = image.fetchImageManifest(chalk.platform)
    data    = %*({
      # https://github.com/in-toto/attestation/blob/main/spec/predicates/scai.md#schema
      "_type": "https://in-toto.io/Statement/v0.1",
      "subject": [
        {
          "name": subject.name.repo,
          "digest": {
            "sha256": subject.digest.extractDockerHash(),
          },
          "config.digest": {
            "sha256": subject.config.digest.extractDockerHash(),
          },
        },
      ],
      "predicateType": "https://in-toto.io/attestation/scai/v0.3",
      "predicate": {
        "attributes": [
          {
            "attribute": "CHALK",
            "evidence": mark,
          },
        ],
      },
    })
    payload     = $data
    payloadType = "application/vnd.in-toto+json"
    signature   = attestationKey.sign(dsse(payload, payloadType = payloadType))
    dsse        = %*({
      "payload":     base64.encode(payload),
      "payloadType": payloadType,
      "signatures":  [
        {
          "sig": signature,
        }
      ],
    })
    bundle      = %*({
      # https://docs.sigstore.dev/about/bundle/
      "mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json",
      "verificationMaterial": {
        "certificate": {
          "rawBytes": attestationKey.asDer(),
        },
      },
      "dsseEnvelope": dsse,
    })
  result.setIfNotEmpty("_SIGNATURES", %(@[dsse]))
  manifest.add(
    DockerManifest(
      kind:         DockerManifestType.image,
      mediaType:    "application/vnd.oci.image.manifest.v1+json",
      artifactType: "application/vnd.dev.sigstore.bundle.v0.3+json",
      subject:      subject,
      annotations:  %*({
        "dev.sigstore.bundle.content":       "dsse-envelope",
        "dev.sigstore.bundle.predicateType": "https://sigstore.dev/cosign/sign/v1",
        "org.opencontainers.image.created":  startTime.utc.format(timesIso8601Format),
      }),
      config: DockerManifest(
        kind:         DockerManifestType.config,
        json:         newJObject(),
        mediaType:    "application/vnd.oci.empty.v1+json",
      ),
      layers: @[
        DockerManifest(
          kind:       DockerManifestType.layer,
          mediaType: "application/vnd.dev.sigstore.bundle.v0.3+json",
          json:       bundle,
        ),
      ],
    ),
  )
  info("attestation: pushing attestation for " & $image & " to " & $spec)
  manifest.put()

proc signBySigStore*(chalk: ChalkObj): ChalkDict =
  result = ChalkDict()
  for image in chalk.repos.manifests:
    try:
      result.merge(chalk.signBySigStore(image))
      chalk.signed        = true
      chalk.noAttestation = false
    except:
      error("attestation: failed to sign attestation: " & getCurrentExceptionMsg())

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
  let blob = artHash & mdHash
  info("attestation: signing file " & chalk.name)
  let signature = attestationKey.sign(blob & "\n")
  result["SIGNING"]             = pack(true)
  result["SIGNATURE"]           = pack(signature)
  result["INJECTOR_PUBLIC_KEY"] = pack(attestationKey.publicKey)
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

  if not attestationKey.canAttestVerify():
    warn(chalk.name & ": Signed but cannot validate; run `chalk setup` to fix")
    return vNoAttestation

  let artHash = chalk.callGetUnchalkedHash().get("")
  if artHash == "":
    return vNoHash

  let
    sig    = unpack[string](chalk.extract["SIGNATURE"])
    blob   = artHash & mdHash
    key    = chalk.getAttestationKey()

  info("attestation: verifying file " & chalk.name)
  trace("verifying blob: '" & blob & "'")

  if key.verify(blob & "\n", sig):
    info(chalk.name & ": Signature successfully validated.")
    return vSignedOk
  else:
    info(chalk.name & ": Signature failed")
    return vBadSig
