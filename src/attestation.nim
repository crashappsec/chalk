## :Author: Theofilos Petsios
## :Copyright: 2023, Crash Override, Inc.

import base64, osproc, config, util, selfextract, commands/cmd_load, chalkjson

template showSetupInfo() =
  info("Initializing code signing.")
  echo ("""To support transparent code signing, Chalk will inject a public key and an encrypted private key into itself.

Additionally, the private key is encrypted with a password that we randomly generate. The application will need access to that password.

Currently, the password is stored encrypted. We'll add support for escrowing it in a secrets API at some point.

The password will be printed out once only. After that, it will be encrypted with a key specific to this binary. The encrypted private key and the public key will be in the current operation's chalk report.
""")

# 2 128 bit keys for (future) 4-round Luby-Rackoff
const
  attestationObfuscator = staticExec(
    "dd status=none if=/dev/random bs=1 count=32 | base64").decode()
  cosignLoader = "load_attestation_binary() -> string"
  c4mAttest    = "push_attestation(string, string, string) -> bool"


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

proc generateKeyMaterial*(cosign: string) =
   let keyCmd = ["generate-key-pair", "--output-key-prefix", "chalk"]
   discard execProcess(cosign, args = keyCmd, options={})

proc getRandomPassword(): string =
  var
    randomBinary = secureRand[array[15, char]]()
    binStr       = newStringOfCap(15)

  for ch in randomBinary: binStr.add(ch)
  return binStr.encode(safe=true)

proc encryptPassword(s: string): string =
  # For now, let's use XOR then b64.
  for i, ch in s:
    result.add(char(uint8(ch) xor uint8(attestationObfuscator[i])))

  result = result.encode(safe=true)

proc decryptPassword(s: string): string =
  for i, ch in s.decode():
    result.add(char(uint8(ch) xor uint8(attestationObfuscator[i])))


proc initAttestation*() =
  let
    cosign    = unpack[string](runCallback(cosignLoader, @[]).get())
    selfChalk = getSelfExtraction().get()

  if cosign == "":
    warn("Could not install cosign; cannot set up attestation.")
    return

  showSetupInfo()

  let
    cwd    = getCurrentDir()
    tmpdir = getNewTempDir()
    pw     = getRandomPassword()
    cmd    = getCommandName()

  setCommandName("setup")
  setCurrentDir(tmpdir)

  putEnv("COSIGN_PASSWORD", pw)
  cosign.generateKeyMaterial()
  delEnv("COSIGN_PASSWORD")

  let
    pubKeyFile = newFileStream("chalk.pub")
    priKeyFile = newFileStream("chalk.key")

  if pubKeyFile == nil or priKeyFile == nil:
    error("cosign failed; cannot set up attestation.")
  else:
    let
      pubKey = pubKeyFile.readAll()
      priKey = priKeyFile.readAll()
      encPw  = encryptPassword(pw)

    pubKeyFile.close()
    priKeyFile.close()

    # These should always print.
    echo "------------------------------------------"
    echo "Your password is: ", pw
    echo "------------------------------------------"


    # We add to selfChalk.extract here because:
    # 1) Writing the mark carries $ keys from extract into collectedData
    # 2) If this is an auto-setup, we might need to use the values,
    #    and we look for them in the extract.
    if selfChalk.extract == nil:
      selfChalk.extract = ChalkDict()
    selfChalk.extract["$CHALK_ENCRYPTED_PRIVATE_KEY"] = pack(priKey)
    selfChalk.extract["$CHALK_PUBLIC_KEY"]            = pack(pubkey)
    selfChalk.extract["$CHALK_ATTESTATION_TOKEN"]     = pack(encPw)

    forceArtifactKeys([ "$CHALK_ENCRYPTED_PRIVATE_KEY",
                        "$CHALK_PUBLIC_KEY",
                        "$CHALK_ATTESTATION_TOKEN" ])
    selfChalk.writeSelfConfig()

  setCurrentDir(cwd)
  setCommandName(cmd)

proc canAttest*(): bool =
  let selfChalk = getSelfExtraction().getOrElse(nil)

  if selfChalk == nil:
    return false # Cannot setup if we can't get a self-chalk mark!
  elif selfChalk.extract == nil:
    return false
  elif "$CHALK_ENCRYPTED_PRIVATE_KEY" notin selfChalk.extract:
    return false
  elif "$CHALK_PUBLIC_KEY" notin selfChalk.extract:
    return false
  elif "$CHALK_ATTESTATION_TOKEN" notin selfChalk.extract:
    return false
  else:
    return true

proc checkAnnotationSetupStatus*() =
  once:
    if canAttest():
      trace("Signing is already set up.")
      return

    if getBaseCommandName() in [ "setup", "exec", "defaults", "version",
                                 "help", "env", "profile", "dump" ]:
      trace("Not taking setup action.")
      return

    let countOpt = selfChalkGetKey("$CHALK_LOAD_COUNT")
    if countOpt.isSome() and not canAttest() and findExePath("cosign").isSome():
      info("We found a `cosign` executable. Attempting to auto-setup signing")
      initAttestation()
      return

    if countOpt.isSome():
      warn("Code signing (attestation) is not set up.")
      warn("Set up by running `chalk setup`.")
      warn("It's that easy, we swear.")

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
    log  = $(chalkConfig.dockerConfig.getUseTransparencyLog())
    args = @["attest", ("--tlog-upload=" & log), "--yes", "--key",
             "chalk.key", "--type", "custom", "--predicate", path,
              digestStr]

  info("Pushing attestation via: `cosign " & args.join(" ") & "`")
  let
    allOut = runCmdGetEverything(cosign, args)
    res    = allout.getStdOut()
    code   = allout.getExit()

  if code == 0:
    return true
  else:
    return false

var
  cosignTmpDir = ""
  cosignLoc    = ""
  cosignPw     = ""

proc getCosignLocation*(): string =
  once:
    let
      selfChalk = getSelfExtraction().get()
      extract   = selfChalk.extract
      priKey    = unpack[string](extract["$CHALK_ENCRYPTED_PRIVATE_KEY"])
      pubKey    = unpack[string](extract["$CHALK_PUBLIC_KEY"])
      encPw     = unpack[string](extract["$CHALK_ATTESTATION_TOKEN"])
      cwd       = getCurrentDir()
    var
      cosign: string

    cosign       = unpack[string](runCallback(cosignLoader, @[]).get())
    cosignTmpDir = getNewTempDir()
    cosignPw     = decryptPassword(encPw)

    if cosign == "":
      error("Failed to find or install cosign.")
      return

    setCurrentDir(cosignTmpDir)

    let
      pubFile = newFileStream("chalk.pub", fmWrite)
      priFile = newFileStream("chalk.key", fmWrite)

    if pubFile == nil or priFile == nil:
      error("Cannot write temp files needed for attestation.")
      return

    pubFile.write(pubKey)
    priFile.write(priKey)
    pubFile.close()
    priFile.close()

    trace("Wrote attestation keys in " & getCurrentDir())

    cosignLoc = cosign

    setCurrentDir(cwd)

  return cosignLoc

proc callC4mPushAttestation*(info: DockerInvocation, mark: string): bool =
  let
    cosign = getCosignLocation()
    chalk  = info.opChalkObj
    cwd    = getCurrentDir()

  if coSign == "":
    return

  if chalk.repo == "" or chalk.repoHash == "":
    trace("Could not find appropriate info needed for attesting")
    return false

  setCurrentDir(cosignTmpDir)
  putEnv("COSIGN_PASSWORD", cosignPw)

  trace("Writing chalk mark via in toto attestation for image id " &
    chalk.imageId & " with sha256 hash of " & chalk.repoHash)
  result = info.writeInToto(chalk.repo, chalk.repo & "@sha256:" & chalk.repoHash,
                                                                  mark, cosign)
  if result:
    chalk.signed = true

  delEnv("COSIGN_PASSWORD")
  setCurrentDir(cwd)

template pushAttestation*(ctx: DockerInvocation) =
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


proc coreVerify(cosign: string, pk: string, chalk: ChalkObj): bool =
  ## Used both for validation, and for downloading just the signature
  ## after we've signed.
  let
    cwd    = getCurrentDir()
    noTlog = not chalkConfig.dockerConfig.getUseTransparencyLog()
    fName  = "chalk.pub"

  setCurrentDir(getNewTempDir())
  putEnv("COSIGN_PASSWORD", cosignPw)
  let
    f = newFileStream(fName, fmWrite)

  if f == nil:
    error(chalk.name & ": Cannot retrieve signature; " &
                       "Could not write to tmp file")
    delEnv("COSIGN_PASSWORD")
    setCurrentDir(cwd)
    return true  # Don't error that it's invalid.
  f.write(pk)
  f.close()

  let
    args   = @["verify-attestation", "--key", fName,
               "--insecure-ignore-tlog=" & $(noTlog), "--type", "custom",
               chalk.repo & "@sha256:" & chalk.repoHash]
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

  delEnv("COSIGN_PASSWORD")
  setCurrentDir(cwd)

proc extractSigAndValidateNonInsert(chalk: ChalkObj, cosign: string) =
  if "INJECTOR_PUBLIC_KEY" notin chalk.extract:
    warn("Signer did not add their public key to the mark; cannot validate")
    chalk.setIfNeeded("_VALIDATED_SIGNATURE", false)
  elif chalk.repo == "" or chalk.repoHash == "":
    chalk.setIfNeeded("_VALIDATED_SIGNATURE", false)
  else:
    let
      pubKey = unpack[string](chalk.extract["INJECTOR_PUBLIC_KEY"])
      ok     = coreVerify(cosign, pubKey, chalk)
    if ok:
      chalk.setIfNeeded("_VALIDATED_SIGNATURE", true)
      info(chalk.name & ": Successfully validated signature.")
    else:
      chalk.setIfNeeded("_INVALID_SIGNATURE", true)
      warn(chalk.name & ": Could not extract valid mark from attestation.")

proc extractSigAndValidateAfterInsert(chalk: ChalkObj, cosign: string) =
  let
    pubkey = unpack[string](selfChalkGetKey("$CHALK_PUBLIC_KEY").get())
    ok     = coreVerify(cosign, pubKey, chalk)

  if ok:
    info("Confirmed attestation and collected signature.")
  else:
    warn("Error collecting attestation signature.")

proc extractAttestationMark*(chalk: ChalkObj): ChalkDict =
  result = ChalkDict(nil)

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
  let cosign = getCosignLocation()
  if cosign == "":
    once:
      warn("Cannot validate signatures: cosign not found.")
    return

  if not chalk.signed:
    info(chalk.name & ": Not signed.")

  let cwd = getCurrentDir()

  setCurrentDir(cosignTmpDir)
  if getCommandName() in ["build", "push"]:
    chalk.extractSigAndValidateAfterInsert(cosign)
  else:
    chalk.extractSigAndValidateNonInsert(cosign)

  setCurrentDir(cwd)
