##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  base64,
  os,
]
import ".."/[
  config,
  docker/ids,
  n00b/subproc,
  types,
  utils/files,
  utils/json,
  utils/semver,
]

var cosignLoc      = ""
var cosignVersion  = parseVersion("0")
let minimumVersion = parseVersion("2.2.0")

template getOrDownloadCosignLocation(downloadCosign: bool) =
  if cosignLoc == "":
    const cosignLoader = "load_attestation_binary(bool) -> string"
    let args = @[pack(downloadCosign)]
    cosignLoc = unpack[string](runCallback(cosignLoader, args).get())
    if cosignLoc == "":
      warn("Could not find or install cosign; cannot sign or verify.")
    else:
      trace("found cosign: " & cosignLoc)

proc getCosignLocation*(downloadCosign = false): string =
  # a bit repetitive however it allows once blocks to be per download branch
  # otherwise if there is only a single once block
  # if this function is called with downloadCosign=false
  # even if it is later called with downloadCosign=true
  # it will never be downloaded
  if downloadCosign:
    once:
      getOrDownloadCosignLocation(downloadCosign)
  else:
    once:
      getOrDownloadCosignLocation(downloadCosign)
  return cosignLoc

proc getCosignVersion*(): Version =
  once:
    let path = getCosignLocation()
    if path == "":
      return cosignVersion
    let
      cmd    = subproc.runCommand(path, @["version"])
      stdOut = cmd.stdout
      lines  = stdOut.splitLines()
    if cmd.exitCode != 0:
      warn("Could not find cosign version")
      return cosignVersion
    try:
      cosignVersion = lines.getVersionFromLineWhich(startsWith = "GitVersion:")
      trace("cosign version: " & $cosignVersion)
      if cosignVersion < minimumVersion:
        warn("Unsupported cosign version is installed " & $cosignVersion & ". " &
             "Please upgrade to >= " & $minimumVersion & ". " &
             "See https://blog.sigstore.dev/tuf-root-update/ for more details.")
    except:
      warn("Could not find cosign version from: " & stdOut)
  return cosignVersion

proc isCosignInstalled*(): bool =
  return getCosignLocation() != ""

proc canAttest*(key: AttestationKey): bool =
  if key == nil:
    return false
  return (
    isCosignInstalled() and
    # https://blog.sigstore.dev/tuf-root-update/
    getCosignVersion() >= minimumVersion and
    key.privateKey != "" and
    key.publicKey != "" and
    key.password != ""
  )

proc canAttestVerify*(key: AttestationKey): bool =
  if key == nil:
    return false
  return (
    isCosignInstalled() and
    # https://blog.sigstore.dev/tuf-root-update/
    getCosignVersion() >= minimumVersion and
    key.publicKey != ""
  )

proc canVerifyByHash*(chalk: ChalkObj): bool =
  return isCosignInstalled() and chalk.fsRef != "" and ResourceCert notin chalk.resourceType

proc canVerifyBySigStore*(chalk: ChalkObj): bool =
  return (
    isCosignInstalled() and
    ResourceImage     in    chalk.resourceType and
    ResourceContainer notin chalk.resourceType and
    len(chalk.repos)  >     0
  )

template withCosignPassword(password: string, code: untyped) =
  putEnv("COSIGN_PASSWORD", password)
  trace("Adding COSIGN_PASSWORD to env")
  try:
    code
  finally:
    delEnv("COSIGN_PASSWORD")
    trace("Removed COSIGN_PASSWORD from env")

template withCosignKey*(key: AttestationKey, code: untyped) =
  if key.tmpPath == "":
    key.tmpPath = getNewTempDir()
    var wrotePrivateKey, wrotePublicKey = true
    if key.privateKey != "":
      wrotePrivateKey = tryToWriteFile(key.tmpPath / "chalk.key", key.privateKey)
    if key.publicKey != "":
      wrotePublicKey = tryToWriteFile(key.tmpPath / "chalk.pub", key.publicKey)
    if not (wrotePrivateKey and wrotePublicKey):
      error("Cannot write to temporary directory; sign and verify " &
            "will not work this run.")
      key.tmpPath = ""

  withWorkingDir(key.tmpPath):
    if key.password != "":
      withCosignPassword(key.password):
        code
    else:
      code

proc signBlob*(self: AttestationKey, blob: string, tlog: bool): string =
  let
    cosign    = getCosignLocation()
    # in cosign 3 bundle is required
    useBundle = getCosignVersion() >= parseVersion("3")
  var
    bundle = ""
    args   = @["sign-blob",
               "--tlog-upload=" & $tlog,
               "--yes",
               "--key=chalk.key",
               "-"]
  if useBundle:
    let (stream, path) = getNewTempFile(suffix = "bundle.json")
    stream.close() # release fd so that cosign can write to it
    bundle = path
    args.add("--bundle=" & path)

  trace("signing blob: '" & blob & "'")
  trace("cosign " & args.join(" "))
  let
    cmd = runCmdGetEverything(cosign, args, blob)
    err = cmd.getStderr()

  if cmd.getExit() != 0:
    raise newException(ValueError, err)

  if not useBundle:
    result = cmd.getStdout().strip()
  else:
    let bundleData = tryToLoadFile(bundle)
    if bundleData == "":
      raise newException(
        ValueError,
        "Cosign error: empty signed bundle file"
      )
    let bundleJson = parseJson(bundleData)
    if bundleJson.kind != JObject:
      raise newException(
        ValueError,
        "Cosign error: bundle is not a json object"
      )
    trace(bundleJson.pretty())
    result = bundleJson{"messageSignature"}{"signature"}.getStr()

  if result == "":
    raise newException(ValueError, "empty signature. stderr: " & err)
  trace("cosign signature: " & result)

proc isValid*(self: AttestationKey): bool =
  self.withCosignKey:
    let
      cosign   = getCosignLocation()
      toSign   = "Test string for signing"
    var sig    = ""
    try:
      sig = self.signBlob(toSign, tlog = false)
    except:
      error("Could not sign; either password is wrong, or key is invalid: " & getCurrentExceptionMsg())
      return false

    info("Test sign successful.")

    let
      vfyArgs = @["verify-blob",
                  "--key=chalk.pub",
                  "--insecure-ignore-tlog=true",
                  "--insecure-ignore-sct=true",
                  "--signature=" & sig,
                  "-"]
      vfyOut  = runCmdGetEverything(cosign, vfyArgs, toSign)

    if vfyOut.getExit() != 0:
      error("Could not validate; public key is invalid.")
      return false

    info("Test verify successful.")

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
  trace("Cosign public attestion keys path: " & publicKey)
  trace("Cosign private attestion keys path: " & privateKey)
  return (publicKey, privateKey)

proc getCosignKeyFromDisk*(path: string, password = ""): AttestationKey =
  let
    pass       = if password != "": password else: getChalkPassword()
    paths      = normalizeKeyPath(path)
    publicKey  = tryToLoadFile(paths.publicKey)
    privateKey = tryToLoadFile(paths.privateKey)

  if publicKey == "":
    raise newException(ValueError, "Unable to read cosign public key @" & paths.publicKey)
  if privateKey == "":
    raise newException(ValueError, "Unable to read cosign private key @" & paths.privateKey)

  return AttestationKey(
    password:   pass,
    publicKey:  publicKey,
    privateKey: privateKey,
  )

proc mintCosignKey*(path: string): AttestationKey =
  let
    password       = randString(16).encode(safe = true)
    (dir, name, _) = path.splitFile()
    paths          = normalizeKeyPath(path)
    keyCmd         = @["generate-key-pair", "--output-key-prefix", dir / name]

  if not dir.dirExists():
    dir.createDir()

  if paths.publicKey.fileExists():
    raise newException(ValueError, paths.publicKey & ": already exists. Remove to generate new key.")
  if paths.privateKey.fileExists():
    raise newException(ValueError, paths.privateKey & ": already exists. Remove to generate new key.")

  withCosignPassword(password):
    let results = subproc.runCommand(getCosignLocation(), keyCmd)
    if results.exitCode != 0:
      raise newException(ValueError, "Could not mint cosign key: " & getCurrentExceptionMsg())

    return getCosignKeyFromDisk(path, password = password)
