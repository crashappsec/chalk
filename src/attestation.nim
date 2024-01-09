##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import base64, chalkjson, config, httpclient, net, os, selfextract, 
       sinks, uri, nimutils/sinks

const
  attestationObfuscator = staticExec(
    "dd status=none if=/dev/random bs=1 count=16 | base64").decode()
  cosignLoader = "load_attestation_binary(bool) -> string"
  #c4mAttest    = "push_attestation(string, string, string) -> bool"

var
  cosignTempDir = ""
  cosignLoc     = ""
  cosignPw      = ""    # Note this is not encrypted in memory.
  cosignLoaded  = false
  signingID     = ""

template withCosignPassword(code: untyped) =
  putEnv("COSIGN_PASSWORD", cosignPw)
  trace("Adding COSIGN_PASSWORD to env")

  try:
    code
  finally:
    delEnv("COSIGN_PASSWORD")
    trace("Removed COSIGN_PASSWORD from env")

when false:
  ## The below code imports keys generated via the OpenSSL PAI.
  ## I'd eventually like to not require downloading cosign
  ## to get the keys set up.
  ##
  ## I'm done w/ the OpenSSL part; the rest I'd have to wrap via
  ## secretbox.
  const
    importFlags = ["import-key-pair", "--key", "chalk.pem",
                   "--output-key-prefix=chalk"]

  {.emit: """
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/bio.h>

char *
BIO_to_string(BIO *bio) {
    char *tmp;
    char *result;
    size_t len;

    len    = BIO_get_mem_data(bio, &tmp);
    result = (char *)calloc(len + 1, 1);
    memcpy(result, tmp, len);
    BIO_free(bio);

    return result;
}

void
generate_keypair(char **s1, char **s2) {
    EVP_PKEY *pkey     = NULL;
    EVP_PKEY_CTX *pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519, NULL);
    BIO *pri           = BIO_new(BIO_s_mem());
    BIO *pub           = BIO_new(BIO_s_mem());

    EVP_PKEY_keygen_init(pctx);
    EVP_PKEY_keygen(pctx, &pkey);
    EVP_PKEY_CTX_free(pctx);
    PEM_write_bio_PrivateKey(pri, pkey, NULL, NULL, 0, NULL, NULL);
    PEM_write_bio_PUBKEY(pub, pkey);

    char *x = BIO_to_string(pri);
    char *y = BIO_to_string(pub);

    *s1 = x;
    *s2 = y;
}
""" .}
  proc generateKeypair(pri: ptr cstring, pub: ptr cstring) {.importc:
                                                           "generate_keypair".}
  proc generateKeyMaterial*(cosign: string) =
    let
      prikey: cstring
      pubkey: cstring
      fpPri = newFileStream("chalk.pem", fmWrite)

    generateKeypair(addr prikey, addr pubkey)

    fpPri.write($(prikey))
    fpPri.close()

    discard execProcess(cosign, args = importFlags, options={})

## End of code that's not compiled in.  Again, it does work, it's just
## not finished enough to replace what we already have.


template callTheSigningKeyBackupService(base: string, prKey: string, bodytxt: untyped,
                              mth: untyped): Response =
  let
    # Timeout asssociated with the signing key backup service
    timeout:      int    = cast[int](chalkConfig.getSigningKeyBackupServiceTimeout())
    # Name of the auth config section to load from the config which contains the jwt
    auth_config:  string = chalkConfig.getSigningKeyBackupServiceAuthConfigName()
  var
    url:      string
    uri:      Uri
    client:   HttpClient
    context:  SslContext
    response: Response

  # This is the id that will be used to identify the secret in the API
  signingID = sha256Hex(attestationObfuscator & prkey)

  if mth == HttPGet:
    trace("Calling Signing Key Backup Service to retrieve key with ID: " & signingID)
  else:
    trace("Calling Signing Key Backup Service to store key with iD: " & signingID)

  if base[^1] == '/':
    url = base & signingID
  else:
    url = base & "/" & signingID

  let authOpt = getAuthConfigByName(auth_config)
  if authOpt.isNone():
    error("Could not retrieve Chalk Data API token from configuration profile. Unable to use Signing Key Backup Service.")
    return false
  var
    auth = authOpt.get()
    headers = newHttpHeaders()
    authHeaders = auth.implementation.injectHeaders(auth, headers)

  # Call the API with authz header - rety twice with backoff
  uri       = parseUri(url)
  context   = newContext(verifyMode = CVerifyPeer)
  client    = newHttpClient(sslContext = context, timeout = timeout)
  response  = client.safeRequest(url = uri,
                                 httpMethod        = mth,
                                 headers           = authHeaders,
                                 body              = bodytxt,
                                 retries           = 2,
                                 firstRetryDelayMs = 100)

  trace("Signing Key Backup Service URL: " & $uri)  
  trace("Signing Key Backup Service HTTP headers: " & $authHeaders)
  trace("Signing Key Backup Service status code: " & response.status)
  trace("Signing Key Backup Service response: " & response.body)

  # Cleanup & return from template
  client.close()
  response

proc backupSigningKeyToService*(content: string, prkey: string): bool =
  var
    nonce:    string
    response: Response

  let
    base  = chalkConfig.getSigningKeyBackupServiceUrl()
    ct    = prp(attestationObfuscator, cosignPw, nonce)

  if len(base) == 0:
    error("Cannot backup signing key; no Signing Key Backup Service URL configured.")
    return false

  let body = nonce.hex() & ct.hex()
  response = callTheSigningKeyBackupService(base, prkey, body, HttpPut)

  trace("Sending encrypted secret: " & body)
  if response.code == Http405:
    info("This encrypted signing key is already backed up.")
  elif not response.code.is2xx():
    error("When attempting to save envcrypted signing key: " & response.status)
    trace(response.body())
    return false
  else:
    info("Successfully stored encrypted signing key.")
    warn("Please Note: Encrypted signing keys that have not been READ in the previous 30 days will be deleted!")
  return true

proc restoreSigningKeyFromService*(prkey: string): bool =

  if cosignPw != "":
    return true

  let base: string = chalkConfig.getSigningKeyBackupServiceUrl()

  if len(base) == 0 or prkey == "":
    return false

  let response = callTheSigningKeyBackupService(base, prKey, "", HttpGet)

  if not response.code.is2xx():
    # authentication issue / token expiration - begin reauth
    if response.code == Http401:
      # parse json response and save / return values()
      let jsonNodeReason = parseJson(response.body())
      trace("JSON body of response from Signing key Backup Service: " & $jsonNodeReason)
    else:
      warn("Could not retrieve encrypted signing key: " & response.status & "\n" & "Will not be able to sign / verify.")
      return false

  var
    body:    string
    hexBits: string

  try:
    hexBits = response.body()
    body    = parseHexStr($hexBits)

    if len(body) != 40:
      raise newException(ValueError, "Nice hex, but wrong size.")
  except:
    error("When loading the signing secret, received an invalid " &
          "response from server: " & response.status)
    return false

  trace("Successfully retrieved secret from secret manager.")

  var
    nonce = body[0 ..< 16]
    ct    = body[16 .. ^1]

  cosignPw = brb(attestationObfuscator, ct, nonce)

  return true

proc getCosignLocation*(downloadCosign = false): string =
  once:
    let args = @[pack(downloadCosign)]
    cosignLoc = unpack[string](runCallback(cosignLoader, args).get())

    if cosignLoc == "":
      warn("Could not find or install cosign; cannot sign or verify.")

  return cosignLoc

proc getCosignTempDir(): string =
  once:
    if cosignTempDir == "":
      let
        extract = getSelfExtraction().get().extract
        priKey  = unpack[string](extract["$CHALK_ENCRYPTED_PRIVATE_KEY"])
        pubKey  = unpack[string](extract["$CHALK_PUBLIC_KEY"])

      cosignTempDir = getNewTempDir()
      withWorkingDir(cosignTempDir):
        if not (tryToWriteFile("chalk.key", priKey) and
                tryToWriteFile("chalk.pub", pubKey)):
          error("Cannot write to temporary directory; sign and verify " &
                "will not work this run.")
          cosignTempDir = ""

  return cosignTempDir

proc getKeyFileLoc*(): string =
  let
    confLoc = chalkConfig.getSigningKeyLocation()

  if confLoc.endswith(".key") or confLoc.endswith(".pub"):
    result = resolvePath(confLoc[0 ..< ^4])
  else:
    result = resolvePath(confLoc)

  if dirExists(result):
    error("Invalid key file specified; base (without the extension) must " &
      "include a file name.")
    return ""

  let
    (dir, _) = result.splitPath()

  if dirExists(dir):
    return
  else:
    error("Directory '" & dir & "' does not exist.")
    return ""

proc generateKeyMaterial*(cosign: string): bool =
  let keyCmd  = @["generate-key-pair", "--output-key-prefix", "chalk"]
  var results: ExecOutput

  withCosignPassword:
    results = runCmdGetEverything(cosign, keyCmd)

  if results.getExit() != 0:
    return false
  else:
    return true

proc commitPassword(pri: string, gen: bool) =
  var
    storeIt = chalkConfig.getUseSigningKeyBackupService()
    printIt = not storeIt

  if storeIt:
    # If the manager doesn't work, then we need to fall back.
    if not cosignPw.backupSigningKeyToService(pri):
      error("Could not store password. Either try again later, or " &
        "use the below password with the CHALK_PASSWORD environment " &
        "variable. We attempt to store as long as use_signing_key_backup_service " &
        "is true.\nIf you forget the password, delete chalk.key and " &
        "chalk.pub before rerunning.")

      if gen:
        printIt = true

    else:
      let idString = "The ID of the backed up key is: " & $signingID
      info(idString)

  if printIt:
    echo "------------------------------------------"
    echo "Your password is: ", cosignPw
    echo """------------------------------------------

Write this down. Even if you embedded it in the Chalk binary, you
will need it to load the key pair into another chalk binary.
"""

  # Right now we are not using the result.
proc acquirePassword(optfile = ""): bool {.discardable.} =
  var
    prikey = optfile

  # If Env var with signing password is set use that
  if existsEnv("CHALK_PASSWORD"):
    cosignPw = getEnv("CHALK_PASSWORD")
    delEnv("CHALK_PASSWORD")
    return true

  if chalkConfig.getUseSigningKeyBackupService() == false:
    return false

  if prikey == "":

    let
      boxedOpt = selfChalkGetKey("$CHALK_ENCRYPTED_PRIVATE_KEY")
      boxed    = boxedOpt.getOrElse(pack(""))

    prikey  = unpack[string](boxed)

    if prikey == "":
      return false

  # Use Chalk Data API key to retrieve previously saved encrypted secret 
  #  from API, then use retrieved private key to decrypt
  if restoreSigningKeyFromService(prikey):
    return true
  else:
    error("Could not retrieve encrypted signing key from API")
    return false

proc testSigningSetup(pubKey, priKey: string): bool =
  cosignTempDir = getNewTempDir()

  if cosignTempDir == "":
    return false

  withWorkingDir(cosignTempDir):
    if not (tryToWriteFile("chalk.key", priKey) and
            tryToWriteFile("chalk.pub", pubKey)):
        error("Cannot write to temporary directory; sign and verify NOT " &
              "configured.")
        return false

    withCosignPassword:
      let
        cosign   = getCosignLocation()
        toSign   = "Test string for signing"
        signArgs = @["sign-blob", "--tlog-upload=false", "--yes",
                     "--key=chalk.key", "-"]
        signOut  = getCosignLocation().runCmdGetEverything(signArgs, tosign)
        sig      = signOut.getStdout()

      if signOut.getExit() != 0 or sig == "":
        error("Could not sign; either password is wrong, or key is invalid.")
        return false

      info("Test sign successful.")

      let
        vfyArgs = @["verify-blob", "--key=chalk.pub",
                    "--insecure-ignore-tlog=true",
                    "--insecure-ignore-sct=true", ("--signature=" & sig), "-"]
        vfyOut  = runCmdGetEverything(cosign, vfyArgs, tosign)

      if vfyOut.getExit() != 0:
        error("Could not validate; public key is invalid.")
        return false

      info("Test verify successful.")

      return true

proc writeSelfConfig(selfChalk: ChalkObj): bool {.importc, discardable.}

proc saveSigningSetup(pubKey, priKey: string, gen: bool): bool =
  let selfChalk = getSelfExtraction().get()

  selfChalk.extract["$CHALK_ENCRYPTED_PRIVATE_KEY"] = pack(priKey)
  selfChalk.extract["$CHALK_PUBLIC_KEY"]            = pack(pubKey)

  commitPassword(priKey, gen)

  when false:
    # This is old code, but it might make a comeback at some point,
    # so I'm not removing it.
    if chalkConfig.getUseInternalPassword():
      let pw = pack(encryptPassword(cosignPw))
      selfChalk.extract["$CHALK_ATTESTATION_TOKEN"] = pw
    else:
      if "$CHALK_ATTESTATION_TOKEN" in selfChalk.extract:
        selfChalk.extract.del("$CHALK_ATTESTATION_TOKEN")

  let savedCommandName = getCommandName()
  setCommandName("setup")
  result = selfChalk.writeSelfConfig()
  setCommandName(savedCommandName)

proc copyGeneratedKeys(pubKey, priKey, baseLoc: string) =
  let
    pubLoc  = baseLoc & ".pub"
    priLoc  = baseLoc & ".key"

  if not tryToCopyFile("chalk.pub", pubLoc):
    error("Could not copy public key to " & pubLoc & "; printing to stdout")
  else:
    info("Public key written to: " & pubLoc)
  if not tryToCopyFile("chalk.key", priLoc):
    error("Could not copy private key to " & priLoc & "; printing to stdout")
  else:
    info("Public key (encrypted) written to: " & priLoc)

proc loadSigningSetup(): bool =
  let
    selfOpt = getSelfExtraction()

  if selfOpt.isNone():
    return false

  let selfChalk = selfOpt.get()

  if selfChalk.extract == nil:
    return false

  let extract = selfChalk.extract

  if "$CHALK_ENCRYPTED_PRIVATE_KEY" notin extract:
    return false

  if "$CHALK_PUBLIC_KEY" notin extract:
    return false

  if cosignPw == "":
    error("Cannot attest; no password is available for the private key. " &
      "Note that the private key *must* be encrypted.")
    return false

  let
    priKey = unpack[string](extract["$CHALK_ENCRYPTED_PRIVATE_KEY"])
    pubKey = unpack[string](extract["$CHALK_PUBLIC_KEY"])

  withWorkingDir(getCosignTempDir()):
      if not tryToWriteFile("chalk.key", priKey):
        return false
      if not tryToWriteFile("chalk.pub", pubKey):
        return false

  cosignLoaded = true
  return cosignLoaded

proc attemptToLoadKeys*(silent=false): bool =
  if getCosignLocation() == "":
    return false

  let withoutExtension = getKeyFileLoc()

  if withoutExtension == "":
      return false

  var
    pubKey = tryToLoadFile(withoutExtension & ".pub")
    priKey = tryToLoadFile(withoutExtension & ".key")

  if pubKey == "":
    if not silent:
      error("Could not read public key.")
    return false
  if priKey == "":
    if not silent:
      error("Could not read public key.")
    return false

  acquirePassword(priKey)
  if cosignPw == "":
    cosignPw = getPassword("Password: ")
    if cosignPw == "":
      return false

  if not testSigningSetup(pubKey, priKey):
    return false

  cosignLoaded = true

  # Ensure any changed chalk keys are saved to self
  let savedCommandName = getCommandName()
  setCommandName("setup")
  result = selfChalk.writeSelfConfig()
  setCommandName(savedCommandName)

  return true

proc attemptToGenKeys*(): bool =

  if getCosignLocation() == "":
    return false

  let keyOutLoc = getKeyFileLoc()
  
  if keyOutLoc == "":
    return false

  if cosignTempDir == "":
    cosignTempDir = getNewTempDir()

  withWorkingDir(cosignTempDir):
    cosignPw = randString(16).encode(safe = true)

    withCosignPassword:
      if not generateKeyMaterial(getCosignLocation()):
        return false
    let
      pubKey = tryToLoadFile("chalk.pub")
      priKey = tryToLoadFile("chalk.key")

    if pubKey == "" or priKey == "":
      return false

    copyGeneratedKeys(pubKey, priKey, keyOutLoc)
    cosignLoaded = true

    result = saveSigningSetup(pubKey, priKey, true)
    
proc canAttest*(): bool =
  if getCosignLocation() == "":
    return false
  return cosignLoaded

proc checkSetupStatus*() =
  # This should really only be called from chalk.nim.
  # Beyond that, call canAttest()

  once:
    acquirePassword()

    let cmd = getBaseCommandName()
    if cmd in ["setup", "help", "load", "dump", "version", "env", "exec"]:
      return

    if loadSigningSetup():
      # loadSigningSetup checks for the info we need to sign. If it's true,
      # we are good.
      return
    let
      countOpt = selfChalkGetKey("$CHALK_LOAD_COUNT")
      countBox = countOpt.getOrElse(pack(0))
      count    = unpack[int](countBox)

    if count == 0:
      # Don't auto-load when compiling.
      return

    if cosignPw != "":
      warn("Found CHALK_PASSWORD; looking for code signing keys.")
      if not attemptToLoadKeys(silent=true):
        warn("Could not load code signing keys. Run `chalk setup` to generate")
      return

    warn("Code signing not initialized. Run `chalk setup` to fix.")


    if count == 1:
      warn("If you want an easy way to do code signing and want to " &
           "get rid of this warning, run:\n" &
           "      `chalk setup --store-password`.")
      warn("The better way is to generate a keypair with `chalk setup` " &
           "and store the generated password in a secret manager. See " &
           "`chalk help setup` for more information.")

proc writeInToto(info:      DockerInvocation,
                 tag:       string,
                 digestStr: string,
                 mark:      string,
                 cosign:    string): bool =
  let
    randint = secureRand[uint]()
    hexval  = toHex(randint and 0xffffffffffff'u).toLowerAscii()
    path    = "chalk-toto-" & hexval & ".json"
    f       = newFileStream(path, fmWrite)
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
  f.write(toto)
  f.close()

  #let
  #  args = @[pack(path), pack(digestStr), pack(cosign)]
  #  box  = runCallback(c4mAttest, args).get()

  #info("c4mpush called with args = " & $(args))
  #result  = unpack[bool](box)

  let
    log  = $(chalkConfig.getUseTransparencyLog())
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

  withWorkingDir(getCosignTempDir()):
    withCosignPassword:
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
  delEnv("COSIGN_PASSWORD")

proc coreVerify(pk: string, chalk: ChalkObj): bool =
  ## Used both for validation, and for downloading just the signature
  ## after we've signed.
  let
    noTlog = not chalkConfig.getUseTransparencyLog()
    fName  = "chalk.pub"

  withWorkingDir(getNewTempDir()):
    if not tryToWriteFile(fName, pk):
      error(chalk.name & ": Cannot retrieve signature; " &
                         "Could not write to tmp file")
      return true  # Don't error that it's invalid.

    let
      args   = @["verify-attestation", "--key", fName,
                 "--insecure-ignore-tlog=" & $(noTlog), "--type", "custom",
                 chalk.repo & "@sha256:" & chalk.repoHash]
    let
      allOut = runCmdGetEverything(getCosignLocation(), args)
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
      ok     = coreVerify(pubKey, chalk)
    if ok:
      chalk.setIfNeeded("_VALIDATED_SIGNATURE", true)
      info(chalk.name & ": Successfully validated signature.")
    else:
      chalk.setIfNeeded("_INVALID_SIGNATURE", true)
      warn(chalk.name & ": Could not extract valid mark from attestation.")

proc extractSigAndValidateAfterInsert(chalk: ChalkObj) =
  let
    pubkey = unpack[string](selfChalkGetKey("$CHALK_PUBLIC_KEY").get())
    ok     = coreVerify(pubKey, chalk)

  if ok:
    info("Confirmed attestation and collected signature.")
  else:
    warn("Error collecting attestation signature.")

proc extractAttestationMark*(chalk: ChalkObj): ChalkDict =
  result = ChalkDict(nil)

  if not canAttest():
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

proc extractAndValidateSignature*(chalk: ChalkObj) {.exportc,cdecl.} =
  if not canAttest():
    return

  if not chalk.signed:
    info(chalk.name & ": Not signed.")

  withWorkingDir(getCosignTempDir()):
    if getCommandName() in ["build", "push"]:
      chalk.extractSigAndValidateAfterInsert()
    else:
      chalk.extractSigAndValidateNonInsert()

proc willSignNonContainer*(chalk: ChalkObj): string =
  ## sysDict is the chlak dict the metsys plugin is currently
  ## operating on.  The items in it will get copied into
  ## chalk.collectedData after the plugin returns.

  if not canAttest():
    # They've already been warn()'d.
    return ""

  # We sign non-container artifacts if either condition is true.
  if not (isSubscribedKey("SIGNATURE") or chalkConfig.getAlwaysTryToSign()):
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
    log    = $(chalkConfig.getUseTransparencyLog())
    args   = @["sign-blob", ("--tlog-upload=" & log), "--yes", "--key",
               "chalk.key", "-"]
    blob   = unchalkedMD & metadataMD

  trace("signing blob: " & blob )
  withWorkingDir(getCosignTempDir()):
    withCosignPassword:
      let allOutput = getCosignLocation().runCmdGetEverything(args, blob & "\n")

      result = allOutput.getStdout().strip()

      if result == "":
        error(chalk.name & ": Signing failed. Cosign error: " &
          allOutput.getStderr())

proc cosignNonContainerVerify*(chalk: ChalkObj,
                               artHash, mdHash, sig, pk: string):
                             ValidateResult =
  let
    log    = $(not chalkConfig.getUseTransparencyLog())
    args   = @["verify-blob", ("--insecure-ignore-tlog=" & log),
               "--key=chalk.pub", ("--signature=" & sig),
               "--insecure-ignore-sct=true", "-"]
    blob   = artHash & mdHash

  trace("blob = >>" & blob & "<<")
  withWorkingDir(getNewTempDir()):
    if not tryToWriteFile("chalk.pub", pk):
      error(chalk.name & ": cannot validate; could not write to tmp file.")
      return vNoCosign

    withCosignPassword:
      let allOutput = getCosignLocation().runCmdGetEverything(args, blob & "\n")

      if allOutput.getExit() == 0:
        info(chalk.name & ": Signature successfully validated.")
        return vSignedOk
      else:
        info(chalk.name & ": Signature failed. Cosign reported: " &
          allOutput.getStderr())
        return vBadSig
