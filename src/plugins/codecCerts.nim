##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## Jenkins CI environment.

import std/[
  base64,
]
import ".."/[
  chalkjson,
  config,
  plugin_api,
  run_management,
  types,
  utils/files,
  utils/strings,
]

{.compile:"../utils/certs.c".}

type
  CertBIO  = pointer
  Cert     = ptr object
    key_value: cstringArray
    version:   cint
    key_size:  cint
  X509Cert = ref object of RootRef
    keyValue: TableRef[string, string]
    version:  int
    keySize:  int

proc open_cert(fd: FileHandle): CertBIO {.importc.}
proc read_cert(data: cstring, c: cint): CertBIO {.importc.}
proc close_cert(c: CertBIO) {.importc.}
proc extract_cert_data(c: CertBIO): Cert {.importc.}
proc cleanup_cert_info(cert: Cert) {.importc.}

iterator findCerts(self:       Plugin,
                   bio:        CertBIO,
                   name:       string,
                   fsRef:      string = "",
                   envVarName: string = "",
                  ): ChalkObj =
  while true:
    let output = extract_cert_data(bio)
    if output == nil:
      break
    try:
      let
        metadata = cstringArrayToSeq(output.key_value)
        keyValue = newTable[string, string]()
        cache    = X509Cert(
          version:  int(output.version),
          keyValue: keyValue,
          keySize:  int(output.key_size),
        )
        data     = ChalkDict()
        chalk    = newChalk(
          name          = name,
          fsRef         = fsRef,
          envVarName    = envVarName,
          codec         = self,
          marked        = true, # allows to "extract"
          resourceType  = {ResourceCert},
          cache         = cache,
          collectedData = data,
          extract       = data,
        )
      for i in 0..<int(len(metadata)/2):
        let
          key   = metadata[i*2]
          value = metadata[i*2+1]
        keyValue[key] = $value
      # cert is already a key-value store and so we will not be chalking
      # a cert file but we still want chalk to collect metadata about it
      # therefore we "fake" chalkmark to be able to collect/report metadata
      # about it as if was chalked
      data.setIfNotEmpty("MAGIC",         magicUTF8)
      data.setIfNotEmpty("ARTIFACT_TYPE", artX509Cert)
      data.setIfNotEmpty("CHALK_VERSION", getChalkExeVersion())
      data.setIfNotEmpty("CHALK_ID",      chalk.callGetChalkId())
      data.merge(chalk.computeMetadataHashAndId(onlyCollected = true))
      discard chalk.getChalkMarkAsStr(onlyCollected = true) # cache chalkmark for future validation
      yield chalk
    finally:
      cleanup_cert_info(output)

proc certsPathSearch(self: Plugin,
                     path: string,
                    ): seq[ChalkObj] =
  result = newSeq[ChalkObj]()
  withFileStream(path, mode = fmRead, strict = false):
    if stream == nil:
      return
    stream.setPosition(0)
    let bio = open_cert(stream.getOsFileHandle())
    try:
      for chalk in self.findCerts(
        bio   = bio,
        name  = path,
        fsRef = path,
      ):
        result.add(chalk)
    finally:
      close_cert(bio)

proc certsSearch(self: Plugin,
                 path: string,
                 ): seq[ChalkObj] {.cdecl.} =
  result = newSeq[ChalkObj]()
  let
    mtd            = attrGet[string]("certs.filter_method")
    (_, name, ext) = path.splitFile()
    filename       = name & ext
  if mtd == "blacklist":
    let
      ignoreNames    = attrGet[seq[string]]("certs.ignore_filenames")
      ignorePrefixes = attrGet[seq[string]]("certs.ignore_prefixes")
      ignoreExts     = attrGet[seq[string]]("certs.ignore_extensions")
    for i in ignoreExts:
      if filename.toLowerAscii().endsWith("." & i.toLowerAscii()):
        trace(path & ": ignored via certs.ignore_extensions")
        return
    for i in ignorePrefixes:
      if filename.toLowerAscii().startsWith(i.toLowerAscii()):
        trace(path & ": ignored via certs.ignore_prefixes")
        return
    for i in ignoreNames:
      if filename.toLowerAscii() == i.toLowerAscii():
        trace(path & ": ignored via certs.ignore_filenames")
        return
    return self.certsPathSearch(path)
  else:
    let
      scanNoExt = attrGet[bool]("certs.scan_no_extension")
      scanExts  = attrGet[seq[string]]("certs.scan_extensions")
    if ext == "" and scanNoExt:
        return self.certsPathSearch(path)
    for i in scanExts:
      if filename.toLowerAscii().endsWith("." & i.toLowerAscii()):
        return self.certsPathSearch(path)
    trace(path & ": ignored due to certs whitelist settings. See " &
          @["certs.scan_no_extension",
            "certs.scan_extensions"].join(", "))

iterator certsSearchEnvVar(self: Plugin,
                           k:    string,
                           bio:  CertBIO,
                           ): ChalkObj =
  try:
    for chalk in self.findCerts(
      bio        = bio,
      name       = k,
      envVarName = k,
    ):
      yield chalk
  finally:
    close_cert(bio)

proc certsSearchEnvVar(self: Plugin,
                       k: string,
                       v: string,
                       ): seq[ChalkObj] {.cdecl.} =
  result = newSeq[ChalkObj]()
  for chalk in self.certsSearchEnvVar(
    bio = read_cert(cstring(v), cint(len(v))),
    k   = k,
  ):
    result.add(chalk)

  # sometimes env vars are base64-encoded certs os attempt to parse them
  if len(result) == 0:
    var b64 = ""
    try:
      b64 = decode(v)
    except:
      discard # not base64 string
    if b64 != "":
      for chalk in self.certsSearchEnvVar(
        bio = read_cert(cstring(b64), cint(len(b64))),
        k   = k,
      ):
        result.add(chalk)

proc certsHandleWrite(self: Plugin,
                      chalk: ChalkObj,
                      data: Option[string],
                      ) {.cdecl.} =
  # we do not update cert files
  return

proc certsGetHash(self: Plugin,
                  chalk: ChalkObj,
                  ): Option[string] {.cdecl.} =
  let
    cert   = X509Cert(chalk.cache)
    serial = cert.keyValue.getOrDefault("Serial")
  # serial is not guaranteed to be enough bits for a chalk hash
  # and so we expand it with sha256 to guarantee supported length
  return some(serial.sha256Hex())

proc certsCallback(chalk: ChalkObj, prefix = ""): ChalkDict =
  let
    cert       = X509Cert(chalk.cache)
    kv         = cert.keyValue.copy()
    extensions = newTable[string, string]()
  result = ChalkDict()
  result.setIfNeeded(prefix & "X509_VERSION",                  cert.version)
  result.setIfNeeded(prefix & "X509_SUBJECT",                  kv.popOrDefault("Subject", ""))
  result.setIfNeeded(prefix & "X509_SUBJECT_ALTERNATIVE_NAME", kv.popOrDefault("X509v3 Subject Alternative Name", ""))
  result.setIfNeeded(prefix & "X509_SERIAL",                   kv.popOrDefault("Serial", ""))
  result.setIfNeeded(prefix & "X509_KEY",                      kv.popOrDefault("Key", ""))
  result.setIfNeeded(prefix & "X509_KEY_TYPE",                 kv.popOrDefault("Key Type", ""))
  result.setIfNeeded(prefix & "X509_KEY_SIZE",                 cert.keySize)
  result.setIfNeeded(prefix & "X509_KEY_USAGE",                kv.popOrDefault("X509v3 Key Usage", ""))
  result.setIfNeeded(prefix & "X509_SIGNATURE",                kv.popOrDefault("Signature", ""))
  result.setIfNeeded(prefix & "X509_SIGNATURE_TYPE",           kv.popOrDefault("Signature Type", ""))
  result.setIfNeeded(prefix & "X509_EXTENDED_KEY_USAGE",       kv.popOrDefault("X509v3 Extended Key Usage", ""))
  result.setIfNeeded(prefix & "X509_BASIC_CONSTRAINTS",        kv.popOrDefault("X509v3 Basic Constraints", ""))
  result.setIfNeeded(prefix & "X509_ISSUER",                   kv.popOrDefault("Issuer", ""))
  result.setIfNeeded(prefix & "X509_SUBJECT_KEY_IDENTIFIER",   kv.popOrDefault("X509v3 Subject Key Identifier", ""))
  result.setIfNeeded(prefix & "X509_AUTHORITY_KEY_IDENTIFIER", kv.popOrDefault("X509v3 Authority Key Identifier", ""))
  result.setIfNeeded(prefix & "X509_NOT_BEFORE",               kv.popOrDefault("Not Before", ""))
  result.setIfNeeded(prefix & "X509_NOT_AFTER",                kv.popOrDefault("Not After", ""))
  for k, v in kv:
    if k.startsWith("X509") or k[0].isDigit():
      extensions[k] = v
  result.setIfNeeded(prefix & "X509_EXTRA_EXTENSIONS",         extensions)

proc certsRunTimeArtCallback(self: Plugin,
                          chalk: ChalkObj,
                          ins: bool,
                          ): ChalkDict {.exportc, cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_OP_ARTIFACT_TYPE", artX509Cert)
  result.merge(chalk.certsCallback(prefix = "_"))

proc loadCodecCerts*() =
  newCodec(
    "certs",
     search             = SearchCb(certsSearch),
     searchEnvVar       = SearchEnvVarCb(certsSearchEnvVar),
     handleWrite        = HandleWriteCb(certsHandleWrite),
     getUnchalkedHash   = UnchalkedHashCb(certsGetHash),
     getPrechalkingHash = PrechalkingHashCb(certsGetHash),
     getEndingHash      = EndingHashCb(certsGetHash),
     rtArtCallback      = RunTimeArtifactCb(certsRunTimeArtCallback),
  )
