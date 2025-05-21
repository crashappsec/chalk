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

include "../certs.c"

proc extract_cert_data(fd: FileHandle, version: ptr cint): cstringarray {.importc.}
proc cleanup_cert_info(info: cstringarray) {.importc.}

type X509Cert = ref object of RootRef
  keyValue: TableRef[string, string]
  version:  int

proc certsSearch(self: Plugin,
                 path: string,
                 ): seq[ChalkObj] {.cdecl.} =
  result = newSeq[ChalkObj]()
  withFileStream(path, mode = fmRead, strict = false):
    if stream == nil:
      return
    stream.setPosition(0)
    var version: cint = 0
    let output = extract_cert_data(stream.getOsFileHandle(), addr version)
    if output == nil:
      return
    try:
      let
        metadata = cStringArrayToSeq(output)
        keyValue = newTable[string, string]()
        cache    = X509Cert(
          version:  int(version),
          keyValue: keyValue,
        )
      for i in 0..<int(len(metadata)/2):
        let
          key = metadata[i*2]
          value = metadata[i*2+1]
        keyValue[key] = $value
      let
        data  = ChalkDict()
        chalk = newChalk(
          name          = path,
          fsRef         = path,
          codec         = self,
          marked        = true, # allows to "extract"
          resourceType  = {ResourceCert},
          cache         = cache,
          collectedData = data,
          extract       = data,
        )
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
  let cert = X509Cert(chalk.cache)
  result = ChalkDict()
  result.setIfNeeded(prefix & "X509_VERSION",                  cert.version)
  result.setIfNeeded(prefix & "X509_SUBJECT",                  cert.keyValue.getOrDefault("Subject"))
  result.setIfNeeded(prefix & "X509_SERIAL",                   cert.keyValue.getOrDefault("Serial"))
  result.setIfNeeded(prefix & "X509_KEY",                      cert.keyValue.getOrDefault("Key"))
  result.setIfNeeded(prefix & "X509_KEY_USAGE",                cert.keyValue.getOrDefault("X509v3 Key Usage"))
  result.setIfNeeded(prefix & "X509_BASIC_CONSTRAINTS",        cert.keyValue.getOrDefault("X509v3 Basic Constraints"))
  result.setIfNeeded(prefix & "X509_ISSUER",                   cert.keyValue.getOrDefault("Issuer"))
  result.setIfNeeded(prefix & "X509_SUBJECT_KEY_IDENTIFIER",   cert.keyValue.getOrDefault("X509v3 Subject Key Identifier"))
  result.setIfNeeded(prefix & "X509_AUTHORITY_KEY_IDENTIFIER", cert.keyValue.getOrDefault("X509v3 Authority Key Identifier"))
  result.setIfNeeded(prefix & "X509_NOT_BEFORE",               cert.keyValue.getOrDefault("Not Before"))
  result.setIfNeeded(prefix & "X509_NOT_AFTER",                cert.keyValue.getOrDefault("Not After"))

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
