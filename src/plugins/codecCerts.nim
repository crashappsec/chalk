##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## Jenkins CI environment.


import std/[options]
import ".."/[config, plugin_api, fd_cache, util, chalkjson]

{.compile:"../certs.c".}

type
  CertBIO  = pointer
  Cert     = ptr object
    key_value: cstringArray
    version:   cint
  X509Cert = ref object of RootRef
    keyValue: TableRef[string, string]
    version:  int

proc open_cert(fd: FileHandle): CertBIO {.importc.}
proc close_cert(c: CertBIO) {.importc.}
proc extract_cert_data(c: CertBIO): Cert {.importc.}
proc cleanup_cert_info(cert: Cert) {.importc.}

proc certsSearch(self: Plugin,
                 path: string,
                 ): seq[ChalkObj] {.cdecl.} =
  result = newSeq[ChalkObj]()
  withFileStream(path, mode = fmRead, strict = false):
    if stream == nil:
      return
    stream.setPosition(0)
    let bio = open_cert(stream.getOsFileHandle())
    try:
      while true:
        let output = extract_cert_data(bio)
        if output == nil:
          return
        try:
          let
            metadata = cStringArrayToSeq(output.key_value)
            keyValue = newTable[string, string]()
            cache    = X509Cert(
              version:  int(output.version),
              keyValue: keyValue,
            )
            data     = ChalkDict()
            chalk    = newChalk(
              name          = path,
              fsRef         = path,
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
          data.setIfNotEmpty("CHALK_VERSION", getChalkExeVersion())
          data.setIfNotEmpty("CHALK_ID",      chalk.callGetChalkId())
          data.merge(chalk.computeMetadataHashAndId())
          result.add(chalk)
        finally:
          cleanup_cert_info(output)
    finally:
      close_cert(bio)

proc certsHandleWrite*(self: Plugin,
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
  result.setIfNeeded(prefix & "X509_KEY_USAGE",                kv.popOrDefault("X509v3 Key Usage", ""))
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

proc certsRunTimeCallback(self: Plugin,
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
     handleWrite        = HandleWriteCb(certsHandleWrite),
     getUnchalkedHash   = UnchalkedHashCb(certsGetHash),
     getPrechalkingHash = PrechalkingHashCb(certsGetHash),
     getEndingHash      = EndingHashCb(certsGetHash),
     rtArtCallback      = RunTimeArtifactCb(certsRunTimeCallback),
  )
