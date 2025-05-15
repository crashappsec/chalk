##
## Copyright (c) 2025, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## This plugin is responsible for providing metadata gleaned from a
## Jenkins CI environment.


import std/[options]
import ".."/[config, plugin_api, fd_cache]

proc certsSearch(self: Plugin,
                 path: string,
                 ): seq[ChalkObj] {.cdecl.} =
  result = newSeq[ChalkObj]()
  withFileStream(path, mode = fmRead, strict = false):
    if stream == nil:
      return
    let contents = stream.readAll()
    if "BEGIN CERTIFICATE" in contents and "END CERTIFICATE" in contents:
        let chalk = newChalk(
          name         = path,
          fsRef        = path,
          codec        = self,
          resourceType = {ResourceCert},
        )
        result.add(chalk)

proc certsHandleWrite*(self: Plugin,
                       chalk: ChalkObj,
                       data: Option[string],
                       ) {.cdecl.} =
  # we do not update cert files
  return

proc certsGetUnchalkedHash(self: Plugin,
                           chalk: ChalkObj,
                           ): Option[string] {.cdecl.} =
  return some("01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b")

proc certsRunTimeCallback(self: Plugin,
                          chalk: ChalkObj,
                          ins: bool,
                          ): ChalkDict {.exportc, cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_OP_ARTIFACT_TYPE", artX509Cert)

proc loadCodecCerts*() =
  newCodec(
    "certs",
     search           = SearchCb(certsSearch),
     handleWrite      = HandleWriteCb(certsHandleWrite),
     getUnchalkedHash = UnchalkedHashCb(certsGetUnchalkedHash),
     rtArtCallback    = RunTimeArtifactCb(certsRunTimeCallback),
  )
