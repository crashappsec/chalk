##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  os,
  sequtils,
]
import ".."/[
  types,
  utils/base64,
  utils/files,
  utils/json,
]

{.compile:"./attestation.c".}

type ucstring = ptr uint8

proc cfree(data: pointer) {.importc.}

proc toString(data: ucstring, length: csize_t): string =
  result = newString(length)
  copyMem(addr result[0], data, length)
  cfree(addr data)

proc decodeKey(data: string): JsonNode =
  var encoded = ""
  for l in data.splitLines():
    if l.startsWith('-'):
      continue
    encoded &= l
  let decoded = base64.safeDecode(encoded)
  result = parseJson(decoded)

proc pem_to_der(
  pem:     cstring,
  der:     ptr ucstring,
  der_len: ptr csize_t,
): bool {.importc.}

proc asDer*(self: AttestationKey): string =
  var
    der:       ucstring
    derLength: csize_t
  if not pem_to_der(
    pem     = cstring(self.publicKey),
    der     = addr der,
    der_len = addr derLength,
  ):
    raise newException(ValueError, "could not convert pem to der")
  return base64.encode(der.toString(derLength))

proc generate_and_encrypt_keypair(
  password:       ucstring,
  password_len:   csize_t,
  kdf_name:       cstring,
  N:              uint64,
  r:              uint32,
  p:              uint32,
  cipher_name:    cstring,
  public_key_out: ptr ucstring,
  public_key_len: ptr csize_t,
  salt_out:       ptr ucstring,
  salt_len:       ptr csize_t,
  nonce_out:      ptr ucstring,
  nonce_len:      ptr csize_t,
  ciphertext_out: ptr ucstring,
  ciphertext_len: ptr csize_t,
): bool {.importc.}

proc mintKey(): AttestationKey =
  let
    password = base64.encode(randString(16), safe = true)
    kdf      = "scrypt"
    cipher   =  "nacl/secretbox"
    N        = 65536
    r        = 8
    p        = 1
  var
    publicKey:        ucstring
    publicKeyLength:  csize_t
    salt:             ucstring
    saltLength:       csize_t
    nonce:            ucstring
    nonceLength:      csize_t
    ciphertext:       ucstring
    ciphertextLength: csize_t
  if not generate_and_encrypt_keypair(
    password       = cast[ucstring](cstring(password)),
    password_len   = csize_t(len(password)),
    kdf_name       = cstring(kdf),
    N              = uint64(N),
    r              = uint32(r),
    p              = uint32(p),
    cipher_name    = cstring(cipher),
    public_key_out = addr publicKey,
    public_key_len = addr publicKeyLength,
    salt_out       = addr salt,
    salt_len       = addr saltLength,
    nonce_out      = addr nonce,
    nonce_len      = addr nonceLength,
    ciphertext_out = addr ciphertext,
    ciphertext_len = addr ciphertextLength,
  ):
    raise newException(ValueError, "could not mint new attestation key")
  let
    data = %*({
      "kdf": {
        "name": kdf,
        "params": {
          "N": N,
          "r": r,
          "p": p
        },
        "salt": base64.encode(salt.toString(saltLength)),
      },
      "cipher": {
        "name": cipher,
        "nonce": base64.encode(nonce.toString(nonceLength)),
      },
      "ciphertext": base64.encode(ciphertext.toString(ciphertextLength)),
    })
  result = AttestationKey(
    password: password,
    publicKey: publicKey.toString(publicKeyLength),
    privateKey: (
      "-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----\n" &
      base64.encode($data).chunks(64).toSeq().join("\n") & "\n" &
      "-----END ENCRYPTED SIGSTORE PRIVATE KEY-----\n"
    ),
  )

proc decrypt_secretbox(
  password:       ucstring,
  password_len:   csize_t,
  salt:           ucstring,
  salt_len:       csize_t,
  kdf_name:       cstring,
  N:              uint64,
  r:              uint32,
  p:              uint32,
  cipher_name:    cstring,
  nonce:          ucstring,
  nonce_len:      csize_t,
  ciphertext:     ucstring,
  ciphertext_len: csize_t,
  plaintext:      ptr ucstring,
  plaintext_len:  ptr csize_t,
): bool {.importc.}

proc decrypt(self: AttestationKey): string =
  var
    plaintext:       ucstring
    plaintextLength: csize_t
  let
    data       = self.privateKey.decodeKey()
    password   = self.password.strip()
    salt       = base64.safeDecode(data{"kdf"}{"salt"}.getStr())
    nonce      = base64.safeDecode(data{"cipher"}{"nonce"}.getStr())
    ciphertext = base64.safeDecode(data{"ciphertext"}.getStr())
    cipher     = data{"cipher"}{"name"}.getStr()
    kdf        = data{"kdf"}{"name"}.getStr()
    N          = data{"kdf"}{"params"}{"N"}.getInt()
    r          = data{"kdf"}{"params"}{"r"}.getInt()
    p          = data{"kdf"}{"params"}{"p"}.getInt()

  if not decrypt_secretbox(
    password       = cast[ucstring](cstring(password)),
    password_len   = csize_t(len(password)),
    salt           = cast[ucstring](cstring(salt)),
    salt_len       = csize_t(len(salt)),
    kdf_name       = cstring(kdf),
    N              = uint64(N),
    r              = uint32(r),
    p              = uint32(p),
    cipher_name    = cstring(cipher),
    nonce          = cast[ucstring](cstring(nonce)),
    nonce_len      = csize_t(len(nonce)),
    ciphertext     = cast[ucstring](cstring(ciphertext)),
    ciphertext_len = csize_t(len(ciphertext)),
    plaintext      = addr plaintext,
    plaintext_len  = addr plaintextLength,
  ):
    raise newException(ValueError, "could not decrypt key with secretbox")

  result = plaintext.toString(plaintextLength)

proc sign_message(
  private_key:        ucstring,
  private_key_length: csize_t,
  message:            ucstring,
  message_length:     csize_t,
  signature:          ptr ucstring,
  signature_length:   ptr csize_t,
): bool {.importc.}

proc sign*(self: AttestationKey,
           message: string,
           ): string =
  var
    signature:       ucstring
    signatureLength: csize_t
  let private  = self.decrypt()

  if not sign_message(
    private_key        = cast[ucstring](cstring(private)),
    private_key_length = csize_t(len(private)),
    message            = cast[ucstring](cstring(message)),
    message_length     = csize_t(len(message)),
    signature          = addr signature,
    signature_length   = addr signatureLength,
  ) or signature == nil:
    raise newException(ValueError, "could not sign")

  return base64.encode(signature.toString(signatureLength))

proc verify_signature(
  public_key:       cstring,
  message:          ucstring,
  message_length:   csize_t,
  signature:        ucstring,
  signature_length: csize_t,
): bool {.importc.}

proc verify*(self:      AttestationKey,
             message:   string,
             signature: string,
             ): bool =
  let sig = base64.safeDecode(signature)
  return verify_signature(
    public_key       = cstring(self.publicKey),
    message          = cast[ucstring](cstring(message)),
    message_length   = csize_t(len(message)),
    signature        = cast[ucstring](cstring(sig)),
    signature_length = csize_t(len(sig)),
  )

proc dsse*(payload: string, payloadType: string): string =
  return (
    "DSSEv1 " &
    $len(payloadType) & " " &
    payloadType & " " &
    $len(payload) & " " &
    payload
  )

proc canAttest*(key: AttestationKey): bool =
  if key == nil:
    return false
  return (
    key.privateKey != "" and
    key.publicKey != "" and
    key.password != ""
  )

proc canAttestVerify*(key: AttestationKey): bool =
  if key == nil:
    return false
  return (
    key.publicKey != ""
  )

proc canVerifyByHash*(chalk: ChalkObj): bool =
  return chalk.fsRef != "" and ResourceCert notin chalk.resourceType

proc canVerifyBySigStore*(chalk: ChalkObj): bool =
  return (
    ResourceImage     in    chalk.resourceType and
    ResourceContainer notin chalk.resourceType and
    len(chalk.repos)  >     0
  )

proc isValid*(self: AttestationKey): bool =
  let toSign = "Test string for signing"
  var sig    = ""

  try:
    sig = self.sign(toSign)
    trace("attestation: test sign successful.")
  except:
    error("attestation: could not sign; either password is wrong, or key is invalid: " & getCurrentExceptionMsg())
    return false

  if not self.verify(toSign, sig):
    error("attestation: could not validate; public key is invalid.")
    return false
  trace("attestation: test verify successful.")

  return true

proc getChalkPassword*(): string =
  if not existsEnv("CHALK_PASSWORD"):
    raise newException(ValueError, "CHALK_PASSWORD env var is missing")
  result = getEnv("CHALK_PASSWORD")
  delEnv("CHALK_PASSWORD")

proc normalizeKeyPath(path: string): tuple[publicKey: string, privateKey: string] =
  let
    resolved       = path.resolvePath()
    (dir, name, _) = resolved.splitFile()
    publicKey      = dir / name & ".pub"
    privateKey     = dir / name & ".key"
  trace("attestation public attestion keys path: " & publicKey)
  trace("attestation private attestion keys path: " & privateKey)
  return (publicKey, privateKey)

proc getAttestationKeyFromDisk*(path: string, password = ""): AttestationKey =
  let
    pass       = if password != "": password else: getChalkPassword()
    paths      = normalizeKeyPath(path)
    publicKey  = tryToLoadFile(paths.publicKey)
    privateKey = tryToLoadFile(paths.privateKey)

  if publicKey == "":
    raise newException(ValueError, "Unable to read attestation public key @" & paths.publicKey)
  if privateKey == "":
    raise newException(ValueError, "Unable to read attestation private key @" & paths.privateKey)

  return AttestationKey(
    password:   pass,
    publicKey:  publicKey,
    privateKey: privateKey,
  )

proc mintAttestationKeyToDisk*(path: string): AttestationKey =
  let
    (dir, _, _) = path.splitFile()
    paths       = normalizeKeyPath(path)

  if not dir.dirExists():
    dir.createDir()
  if paths.publicKey.fileExists():
    raise newException(ValueError, paths.publicKey & ": already exists. Remove to generate new key.")
  if paths.privateKey.fileExists():
    raise newException(ValueError, paths.privateKey & ": already exists. Remove to generate new key.")

  result = mintKey()
  if not tryToWriteFile(paths.publicKey, result.publicKey):
    raise newException(ValueError, paths.publicKey & ": could not save public key.")
  if not tryToWriteFile(paths.privateKey, result.privateKey):
    raise newException(ValueError, paths.publicKey & ": could not save private key.")
