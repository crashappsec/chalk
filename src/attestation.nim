##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import api, base64, chalkjson, config, httpclient, net, os, selfextract, 
       uri, nimutils/sinks

const
  attestationObfuscator = staticExec(
    "dd status=none if=/dev/random bs=1 count=16 | base64").decode()
  cosignLoader = "load_cosign_binary() -> string"
  minisignLoader = "load_minisign_binary() -> string"
  #c4mAttest    = "push_attestation(string, string, string) -> bool"

var
  signerTempDir  = ""
  cosignLoc      = ""
  minisignLoc    = ""
  attestationPw       = ""    # Note this is not encrypted in memory.
  signerLoaded   = false
  signingID      = ""

template withCosignPassword(code: untyped) =
  putEnv("COSIGN_PASSWORD", attestationPw)
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


template callTheSecretService(base: string, prKey: string, apiToken: string, bodytxt: untyped,
                              mth: untyped): Response =
  let
    timeout:  int    = cast[int](chalkConfig.getSecretManagerTimeout())
  var
    url:      string
    uri:      Uri
    client:   HttpClient
    context:  SslContext
    response: Response
  
  # This is the id that will be used to identify the secret in the API
  signingID = sha256Hex(attestationObfuscator & prkey)

  if mth == HttPGet:
    trace("Calling secret manager to retrieve key with id: " & signingID)
  else:
    trace("Calling secret manager to store key with id: " & signingID)

  if base[^1] == '/':
    url = base & signingID
  else:
    url = base & "/" & signingID

  uri = parseUri(url)

  if uri.scheme == "https":
    context = newContext(verifyMode = CVerifyPeer)
    client  = newHttpClient(sslContext = context, timeout = timeout)
  else:
    client  = newHttpClient(timeout = timeout)

  # add in API token obtained via user login process if set
  if apiToken != "":
    client.headers = newHttpHeaders(
                                    {
                                     "Authorization": "Bearer " & $apiToken
                                    }
                                    )

  response  = client.safeRequest(url = uri, httpMethod = mth, body = bodytxt)

  client.close()
  response

proc saveToSecretManager*(content: string, prkey: string, apiToken: string): bool =
  var
    nonce:    string
    response: Response

  let
    base  = chalkConfig.getSecretManagerUrl()
    ct    = prp(attestationObfuscator, attestationPw, nonce)

  if len(base) == 0:
    error("Cannot save secret; no secret manager URL configured.")
    return false

  let body = nonce.hex() & ct.hex()
  trace("Sending encrypted secret: " & body)
  response = callTheSecretService(base, prkey, apiToken, body, HttpPut)

  if response.status.startswith("405"):
    info("This secret is already saved.")
  elif response.status[0] != '2':
    error("When attempting to save signing secret: " & response.status)
    return false
  else:
    info("Successfully stored secret.")
    warn("Please Note: Secrets that have not been READ in the previous 30 days will be deleted!")
  return true

proc loadFromSecretManager*(prkey: string, apikey: string): bool =

  if attestationPw != "":
    return true

  let base: string = chalkConfig.getSecretManagerUrl()

  if len(base) == 0 or prkey == "" or apikey == "":
    return false

  let response = callTheSecretService(base, prKey, apikey, "", HttpGet)

  if response.status[0] != '2':
    # authentication issue / token expiration - begin reauth
    if response.status.startswith("401"):
      # parse json response and save / return values()
      let jsonNodeReason = parseJson(response.body())
      let reasonCode     = jsonNodeReason["Message"].getStr()

      if reasonCode.startswith("token_expired"):
        info("API access token expired, refreshing ...")
        # Remove current API token from self chalk mark
        selfChalk.extract["$CHALK_API_KEY"] = pack("")
        
        # refresh access_token 
        let boxedOptRefresh = selfChalkGetKey("$CHALK_API_REFRESH_TOKEN")
        if boxedOptRefresh.isSome():
          let
            boxedRefresh  = boxedOptRefresh.get()
            refreshToken = unpack[string](boxedRefresh)
          trace("Refresh token retrieved from chalk mark: " & $refreshToken)

          let newApiToken = refreshAccessToken($refreshToken)
          if newApiToken == "":
            return false
          else:
            trace("API Token refreshed: " & newApiToken)
            #save new api token to self chalk mark
            selfChalk.extract["$CHALK_API_KEY"] = pack($newApiToken)
            return loadFromSecretManager(prkey, $newApiToken)
    else:
      warn("Could not retrieve signing secret: " & response.status & "\n" &
        "Will not be able to sign / verify.")
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

  attestationPw = brb(attestationObfuscator, ct, nonce)

  trace("attestation pw is " & attestationPw)

  return true

proc getCosignLocation(): string =
  once:
    cosignLoc = unpack[string](runCallback(cosignLoader, @[]).get())

    if cosignLoc == "":
      warn("Could not find or install cosign; cannot sign or verify.")

  return cosignLoc

proc getMinisignLocation(): string =
  once:
    minisignLoc = unpack[string](runCallback(minisignLoader, @[]).get())

    if minisignLoc == "":
      warn("Could not find or install minisign; cannot sign or verify.")

  return minisignLoc

proc getSignerLocation*(): string = 

  # By default minisign is now used as its a much smaller d/l
  # cosign can still be forced by setting use_cosign in the config
  let useCosign = chalkConfig.getUseCosign()

  if useCosign:
    return getCosignLocation()
  else:
    return getMinisignLocation()

proc getSignerTempDir(): string =
  once:
    if signerTempDir == "":
      let
        extract = getSelfExtraction().get().extract
        priKey  = unpack[string](extract["$CHALK_ENCRYPTED_PRIVATE_KEY"])
        pubKey  = unpack[string](extract["$CHALK_PUBLIC_KEY"])

      signerTempDir = getNewTempDir()
      withWorkingDir(signerTempDir):
        if not (tryToWriteFile("chalk.key", priKey) and
                tryToWriteFile("chalk.pub", pubKey)):
          error("Cannot write to temporary directory; sign and verify " &
                "will not work this run.")
          signerTempDir = ""

  return signerTempDir

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

proc generateKeyMaterial*(signerPath: string): bool =
  var results: ExecOutput

  if chalkConfig.getUseCosign():
    let keyCmd  = @["generate-key-pair", "--output-key-prefix", "chalk"]
    withCosignPassword:
      results = runCmdGetEverything(signerPath, keyCmd)
  else:
    # do minisign
    info("Generating keys with minisign...")
    let keyCmd  = @["-G", "-f", "-p", "chalk.pub", "-s", "chalk.key"]
    let setPwStr = attestationPw & "\n" & attestationPw
    results = runCmdGetEverything(signerPath, keyCmd, newStdIn = setPwStr)
    trace($results.getStdOut())
    trace($results.getStdErr())

  trace("Password used to protect key: " & $attestationPw)

  if results.getExit() != 0:
    return false
  else:
    return true

proc commitPassword(pri, apiToken: string, gen: bool) =
  var
    storeIt = chalkConfig.getUseSecretManager()
    printIt = not storeIt

  if storeIt:
    # If the manager doesn't work, then we need to fall back.
    if not attestationPw.saveToSecretManager(pri, apiToken):
      error("Could not store password. Either try again later, or " &
        "use the below password with the CHALK_PASSWORD environment " &
        "variable. We attempt to store as long as use_secret_manager is " &
        "true.\nIf you forget the password, delete chalk.key and " &
        "chalk.pub before rerunning.")

      if gen:
        printIt = true
    
    else:
      let idString = "The ID of the backed up key is: " & $signingID
      info(idString)

  if printIt:
    echo "------------------------------------------"
    echo "Your password is: ", attestationPw
    echo """------------------------------------------

Write this down. Even if you embedded it in the Chalk binary, you
will need it to load the key pair into another chalk binary.
"""

  # Right now we are not using the result.
proc acquirePassword(optfile = ""): bool {.discardable.} =
  var
    prikey = optfile

  if existsEnv("CHALK_PASSWORD"):
    attestationPw = getEnv("CHALK_PASSWORD")
    delEnv("CHALK_PASSWORD")
    return true

  if chalkConfig.getUseSecretManager() == false:
    return false

  if prikey == "":
    let
      boxedOpt = selfChalkGetKey("$CHALK_ENCRYPTED_PRIVATE_KEY")
      boxed    = boxedOpt.getOrElse(pack(""))

    prikey  = unpack[string](boxed)

    if prikey == "":
      return false

  # get API key to pass to secret manager
  let boxedOptApi = selfChalkGetKey("$CHALK_API_KEY")
  if boxedOptApi.isSome():
    let
       boxedApi = boxedOptApi.get()
       apikey   = unpack[string](boxedApi)
    trace("API token retrieved from chalk mark: " & $apikey)

    if loadFromSecretManager(prikey, apikey):
      return true
    else:
      error("Could not retrieve secret from API")
      return false

  error("Could not retrieve API token from chalk mark")
  return false

template cosignFile() =
  # ToDo - Sign provided file with cosign
  sig = ""

template minisignFile(filePathToSign) =
  # Sign provided file with minisign
  
  let 
    signArgs = @["-Sm", filePathToSign, "-s", "chalk.key"]
  signOut  = signerBin.runCmdGetEverything(signArgs, newStdIn = attestationPw)

  trace(signOut.getStdout())

  # Read sig from file & set as sig, gets return from calling proc
  sig = tryToLoadFile($filePathToSign & ".minisig")

proc signFile*(pathToSign: string): string=
    # top level proc to sign a blob with whicherver signer is configured

  let
    signerBin = getSignerLocation()
    filePathToSign = pathToSign
  var 
    signOut: ExecOutput
    sig = ""

  # sign with whichever signer has been configured - cosign or minisign
  if chalkConfig.getUseCosign():
    # sign blob with cosign
    cosignFile()
  else:
    # sign blob with minisign
    minisignFile($filePathToSign)

  # test for signing success
  if signOut.getExit() != 0 or sig == "":
    return ""
  
  return sig

template cosignBlob() =
  # Sign provided datablob with cosign
  withCosignPassword:
    let signArgs = @["sign-blob", "--tlog-upload=false", "--yes",
                  "--key=chalk.key", "-"]
    signOut  = getCosignLocation().runCmdGetEverything(signArgs, tosign)
    sig      = signOut.getStdout()
    # ToDo ensure sig actually contains only the sig

template minisignBlob() =
  # Sign provided datablob with minisign
  
  # get random tempfile
  var (testFileToSign, filePathToSign) = getNewTempFile()
  if $filePathToSign == "":
    error("Unable to generate a new temporary file object; sign and verify NOT " &
          "configured.")
  
  # Write test string to tmp file
  elif not tryToWriteFile($filePathToSign, toSign):
    error("Cannot write testfile to temporary directory; sign and verify NOT " &
          "configured.")

  else:
    # Sign temp file
    minisignFile($filePathToSign)

proc signBlob*(toSign: string): string=
  # top level proc to sign a blob with whicherver signer is configured

  let
    signerBin = getSignerLocation()
  var 
    signOut: ExecOutput
    sig = ""

  # sign with whichever signer has been configured - cosign or minisign
  if chalkConfig.getUseCosign():
    # sign blob with cosign
    cosignBlob()
  else:
    # sign blob with minisign
    minisignBlob()
  trace($sig)

  # test for signing success
  if signOut.getExit() != 0 or sig == "":
    return ""
  
  return sig

template cosignVerifyBlob() =
  withCosignPassword:
    let
      vfyArgs = @["verify-blob", "--key=chalk.pub",
                  "--insecure-ignore-tlog=true",
                  "--insecure-ignore-sct=true", ("--signature=" & sig), "-"]
      vfyOut  = runCmdGetEverything(signerBin, vfyArgs, tosign)

template minisignVerifyBlob() =
  # write provided signature to verify to .minisig file to then verify
  
  # get random tempfile
  var (sigToVerifyAsFile, sigToVerifyAsFilePath) = getNewTempFile()
  if $sigToVerifyAsFilePath == "":
    error("Unable to generate a new temporary file object; sign and verify NOT " &
          "configured.")
    return false 

  # write sign string to that temp file
  if not tryToWriteFile($sigToVerifyAsFilePath, sig):
    error("Cannot write testfile to temporary directory; sign and verify NOT " &
          "configured.")
  
  let 
    vfyArgs = @["-Vm", $sigToVerifyAsFilePath, "-p", "chalk.pub"]
    vfyOut  = runCmdGetEverything(signerBin, vfyArgs)
  
proc verifyBlob*(sig, toSign: string): bool=

  let 
    signerBin   = getSignerLocation()
  var 
    vfyOut : ExecOutput

  if chalkConfig.getUseCosign():
    # verify blob with cosign
    cosignVerifyBlob()
  else:
    # verify blob with minisign
    minisignVerifyBlob()

  if vfyOut.getExit() != 0:
    error("Could not validate; public key is invalid.")
    return false

  return true

proc testSigningSetup(pubKey, priKey: string): bool =
  signerTempDir = getNewTempDir()
  if signerTempDir == "":
    return false
  
  withWorkingDir(signerTempDir):
    # Organise keys in temp dir, check perms
    if not (tryToWriteFile("chalk.key", priKey) and
            tryToWriteFile("chalk.pub", pubKey)):
      error("Cannot write to temporary directory; sign and verify NOT " &
            "configured.")
      return false

    # Perform test signing operation
    let toSign = "Test string for signing"
    var sig    = signBlob(toSign)
    if sig == "":
      error("Could not sign; either password is wrong, or key is invalid.")
      return false
    else:
      info("Test sign successful.")

    # Verify the test signature
    if not verifyBlob(sig, toSign):
      error("Could not verify; either password is wrong, or key is invalid.")
      return false
    else:
      info("Test verify successful.")
    
    return true

proc writeSelfConfig(selfChalk: ChalkObj): bool {.importc, discardable.}

proc saveSigningSetup(pubKey, priKey, apiToken, refreshToken: string, gen: bool): bool =
  let selfChalk = getSelfExtraction().get()

  selfChalk.extract["$CHALK_ENCRYPTED_PRIVATE_KEY"] = pack(priKey)
  selfChalk.extract["$CHALK_PUBLIC_KEY"]            = pack(pubKey)
  if apiToken != "":
    selfChalk.extract["$CHALK_API_KEY"]             = pack(apiToken)
    selfChalk.extract["$CHALK_API_REFRESH_TOKEN"]   = pack(refreshToken)

  commitPassword(prikey, apiToken, gen)

  when false:
    # This is old code, but it might make a comeback at some point,
    # so I'm not removing it.
    if chalkConfig.getUseInternalPassword():
      let pw = pack(encryptPassword(attestationPw))
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

  if attestationPw == "":
    error("Cannot attest; no password is available for the private key. " &
      "Note that the private key *must* be encrypted.")
    return false

  let
    priKey = unpack[string](extract["$CHALK_ENCRYPTED_PRIVATE_KEY"])
    pubKey = unpack[string](extract["$CHALK_PUBLIC_KEY"])

  withWorkingDir(getSignerTempDir()):
      if not tryToWriteFile("chalk.key", priKey):
        return false
      if not tryToWriteFile("chalk.pub", pubKey):
        return false

  signerLoaded = true
  return signerLoaded

proc attemptToLoadKeys*(silent=false): bool =
  
  if getSignerLocation() == "":
    return false

  let
    withoutExtension = getKeyFileLoc()
    use_api = chalkConfig.getApiLogin()

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
  if attestationPw == "":
    attestationPw = getPasswordViaTty()
    if attestationPw == "":
      return false

  if not testSigningSetup(pubKey, priKey):
    return false

  signerLoaded = true

  # Ensure any changed chalk keys are saved to self
  let savedCommandName = getCommandName()
  setCommandName("setup")
  result = selfChalk.writeSelfConfig()
  setCommandName(savedCommandName)

  return true

proc attemptToGenKeys*(): bool =
  var 
    apiToken     = ""
    refreshToken = ""
  let use_api    = chalkConfig.getApiLogin()

  if use_api:
    (apiToken, refreshToken) = getChalkApiToken()
    if apiToken == "":
      return false
    else:
      trace("API Token received: " & apiToken)

  if getSignerLocation() == "":
    return false

  let
    keyOutLoc = getKeyFileLoc()
    # Any relative path needs to be resolved before we push the temp
    # dir.

  if keyOutLoc == "":
    return false

  if signerTempDir == "":
    signerTempDir = getNewTempDir()

  withWorkingDir(signerTempDir):
    attestationPw = randString(16).encode(safe = true)

    if chalkConfig.getUseCosign():
      withCosignPassword:
        if not generateKeyMaterial(getSignerLocation()):
          return false
    else:
      if not generateKeyMaterial(getSignerLocation()):
          error("Error generating keys with minisign")
          return false

    let
      pubKey = tryToLoadFile("chalk.pub")
      priKey = tryToLoadFile("chalk.key")

    if pubKey == "" or priKey == "":
      return false

    copyGeneratedKeys(pubKey, priKey, keyOutLoc)
    signerLoaded = true

    if use_api:
      result = saveSigningSetup(pubKey, priKey, apiToken, refreshToken, true)
    else:
      result = saveSigningSetup(pubKey, priKey, "", "", true)

proc canAttest*(): bool =
  if getSignerLocation() == "":
    return false
  return signerLoaded

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

    if attestationPw != "":
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

  withWorkingDir(getSignerTempDir()):
    if chalkConfig.getUseCosign():
      withCosignPassword:
        result = info.writeInToto(chalk.repo,
                                  chalk.repo & "@sha256:" & chalk.repoHash,
                                  mark, getSignerLocation())
    else:
      info("Unsupported operation with minisign, please enable use of cosign via setting 'use_cosign=true' in your chalk config")
      result = false
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
      allOut = runCmdGetEverything(getSignerLocation(), args)
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
    cosign = getSignerLocation()

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

  withWorkingDir(getSignerTempDir()):
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
    blob   = unchalkedMD & metadataMD

  trace("signing blob: " & blob )
  withWorkingDir(getSignerTempDir()):
    var sig = signBlob(blob)
    if sig == "":
      error("Could not sign NonContainer ; either password is wrong, or key is invalid.")
      return ""
    else:
      return sig

proc cosignNonContainerVerify*(chalk: ChalkObj,
                               artHash, mdHash, sig, pk: string):
                             ValidateResult =
  let
    log    = $(not chalkConfig.getUseTransparencyLog())
    blob   = artHash & mdHash

  trace("blob = >>" & blob & "<<")
  withWorkingDir(getNewTempDir()):
    if not tryToWriteFile("chalk.pub", pk):
      error(chalk.name & ": cannot validate; could not write to tmp file.")
      return vNoCosign

    # Verify the test signature
    if not verifyBlob(sig, blob):
      error("Could not NonContainer verify; either password is wrong, or key is invalid.")
      return vBadSig
    else:
      return vSignedOk
