##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## X.509 certificate parsing (see certs.c), shared by the certs codec and
## the certificates build policy.

import std/[
  tables,
]

{.compile:"certs.c".}

type
  CertBIO* = pointer
  Cert     = ptr object
    key_value:     cstringArray
    subject:       cstringArray
    subject_short: cstringArray
    issuer:        cstringArray
    issuer_short:  cstringArray
    version:       cint
    key_size:      cint
  X509Cert* = ref object of RootRef
    keyValue*:     TableRef[string, string]
    subject*:      TableRef[string, string]
    subjectShort*: TableRef[string, string]
    issuer*:       TableRef[string, string]
    issuerShort*:  TableRef[string, string]
    ## short names in certificate order, as the tables lose order and
    ## repeated attributes
    subjectNames*: seq[(string, string)]
    issuerNames*:  seq[(string, string)]
    version*:      int
    keySize*:      int

proc open_cert*(fd: FileHandle): CertBIO {.importc.}
proc read_cert*(data: cstring, c: cint): CertBIO {.importc.}
proc close_cert*(c: CertBIO) {.importc.}
proc extract_cert_data(c: CertBIO): Cert {.importc.}
proc cleanup_cert_info(cert: Cert) {.importc.}

proc toPairs(t: cstringArray): seq[(string, string)] =
  # cstringArrayToSeq walks a[0] without a nil check, so guard the C side
  # handing back nil under allocation failure.
  if t == nil:
    return
  let kv = cstringArrayToSeq(t)
  for i in 0..<int(len(kv)/2):
    result.add((kv[i*2], kv[i*2+1]))

proc toTable(pairs: seq[(string, string)]): TableRef[string, string] =
  result = newTable[string, string]()
  for (key, value) in pairs:
    result[key] = value

iterator x509Certs*(bio: CertBIO): X509Cert =
  ## every certificate (PEM or DER) readable from `bio`, in order
  while true:
    let output = extract_cert_data(bio)
    if output == nil:
      break
    var cert: X509Cert
    try:
      let
        subjectShort = output.subject_short.toPairs()
        issuerShort  = output.issuer_short.toPairs()
      cert = X509Cert(
        version:      int(output.version),
        keyValue:     output.key_value.toPairs().toTable(),
        subject:      output.subject.toPairs().toTable(),
        subjectShort: subjectShort.toTable(),
        issuer:       output.issuer.toPairs().toTable(),
        issuerShort:  issuerShort.toTable(),
        subjectNames: subjectShort,
        issuerNames:  issuerShort,
        keySize:      int(output.key_size),
      )
    finally:
      cleanup_cert_info(output)
    yield cert

proc parseX509*(data: string, limit = 0): seq[X509Cert] =
  ## certificates in `data`, at most `limit` of them when it is positive
  if len(data) == 0:
    return
  let bio = read_cert(cstring(data), cint(len(data)))
  if bio == nil:
    return
  try:
    for cert in bio.x509Certs():
      result.add(cert)
      if limit > 0 and len(result) >= limit:
        break
  finally:
    close_cert(bio)
