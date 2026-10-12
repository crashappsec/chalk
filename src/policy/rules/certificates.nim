##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## `policy.certificates`: checks X.509 certificates found in the local build
## context directories. See docs/design-build-policy.md.
##
## The context subchalk that chalks (and reports) context files runs after
## policies, so the rule walks the context itself and parses certificates
## with the certs codec's parser (utils/x509).

import std/[
  algorithm,
  json,
  os,
  sets,
  strutils,
  tables,
  times,
]
from std/posix import Stat, S_ISREG, stat
import "../.."/[
  types,
  utils/x509,
]
from ../../docker/tar import isExcluded, isValidPattern, hasNegationForDir
from ./golden_images import globMatch
import ".."/[
  api,
  configuration,
]

const
  ruleName = "certificates"
  defaultExtensions* = @["pem", "crt", "cer", "cert", "der", "ca-bundle"]
  ## well-known CA bundles that would otherwise flood findings, skipped only
  ## in `caBundleNameDirs` so an application's own `roots.pem` is checked
  caBundleNames = [
    "ca-bundle.crt",
    "ca-bundle.pem",
    "ca-bundle.trust.crt",
    "ca-certificates.crt",
    "cacert.pem",
    "cacerts.pem",
    "curl-ca-bundle.crt",
    "roots.pem",
    "tls-ca-bundle.pem",
  ]
  caBundleNameDirs = @[
    "**/etc/ssl",
    "**/etc/pki",
    "**/usr/lib/ssl",
    "**/usr/local/etc/openssl",
    "**/usr/local/etc/openssl@*",
    "**/certifi",
    "**/grpc/_cython/_credentials",
  ]
  caBundleDirs = @[
    "**/etc/ssl/certs",
    "**/etc/pki/ca-trust",
    "**/etc/pki/tls/certs",
    "**/usr/share/ca-certificates",
    "**/usr/local/share/ca-certificates",
  ]
  maxCertsPerFile* = 1000
  ## bounds over all contexts, so a hostile context cannot exhaust memory or
  ## time: certificates parsed (CA bundles included), and findings listed
  ## (the rest are counted in one finding)
  maxCerts* = 10_000
  maxFindings* = 100
  pemMarkers = ["-----BEGIN CERTIFICATE-----", "-----BEGIN X509 CERTIFICATE-----"]
  trustedMarker = "-----BEGIN TRUSTED CERTIFICATE-----"
  issuerKinds* = ["cn", "dn", "sha256"]
  ## how much of a file over `max_file_size` is read to tell whether it holds
  ## certificates
  headSize = 65536
  weakDigests = ["md2", "md4", "md5", "sha1"]

type
  CertificatesConfig* = object
    denyExpired*:        bool
    denyNotYetValid*:    bool
    expiresWithinDays*:  int
    denySelfSigned*:     bool
    denyCa*:             bool
    denyWeakSignatures*: bool
    minRsaKeySize*:      int
    allowedKeyTypes*:    seq[string]
    allowedEcCurves*:    seq[string]
    allowedIssuers*:     seq[(string, string)]
    includePaths*:       seq[string]
    excludePaths*:       seq[string]
    extensions*:         seq[string]
    skipCaBundles*:      bool
    honorDockerignore*:  bool
    maxFiles*:           int
    maxFileSize*:        int
    message*:            string

  CertInfo* = object
    path*:       string # context-relative, see `scanContexts`
    index*:      int    # 1-based position within the file
    count*:      int    # certificates in the file
    subjectDn*:  string
    issuerDn*:   string
    subjectCn*:  string
    issuerCn*:   string
    ski*:        string
    aki*:        string
    selfSigned*: bool
    isCa*:       bool
    keyType*:    string # rsa, ec, ed25519, ed448, dsa or the OpenSSL name
    keySize*:    int
    keyLoaded*:  bool   # false: OpenSSL could not load the key, size unknown
    curve*:      string
    signature*:  string
    signatureDigest*: string
    der*:        string # copied certificate for issuer pin verification
    sha256*:     string # lowercase hex without separators
    notBefore*:  Option[Time]
    notAfter*:   Option[Time]

  CertScan* = object
    certs*:  seq[CertInfo]
    errors*: seq[PolicyFinding]
    ## pinned certificates of skipped CA bundles, only candidates for
    ## `sha256` issuer pins
    issuers*: seq[CertInfo]
    parsed:   int # certificates parsed, for `maxCerts`

  ## candidates for `sha256` issuer pins by subject DN, one per fingerprint:
  ## only a pinned candidate can allow an issuer, so signature checks are
  ## bounded by the number of pins
  PinnedIssuers* = Table[string, seq[CertInfo]]

proc defaultCertificatesConfig*(): CertificatesConfig =
  CertificatesConfig(
    denyExpired:        true,
    denyNotYetValid:    true,
    denyWeakSignatures: true,
    minRsaKeySize:      2048,
    extensions:         defaultExtensions,
    skipCaBundles:      true,
    honorDockerignore:  true,
    maxFiles:           100_000,
    maxFileSize:        1_048_576,
  )

proc escapeDnValue(value: string): string =
  # https://www.rfc-editor.org/rfc/rfc4514#section-2.4
  for i, c in value:
    if c in {',', '+', '"', '\\', '<', '>', ';'} or
       (i == 0 and c in {' ', '#'}) or (i == len(value) - 1 and c == ' '):
      result.add('\\')
    result.add(c)

proc toDn*(names: seq[(string, string)]): string =
  ## RFC 4514 string (most specific attribute first), e.g.
  ## `CN=Acme Root CA,O=Acme,C=US`
  var parts: seq[string]
  for i in countdown(len(names) - 1, 0):
    parts.add(names[i][0] & "=" & names[i][1].escapeDnValue())
  parts.join(",")

proc commonName(names: seq[(string, string)]): string =
  # the most specific CN when there are several
  for (key, value) in names:
    if key == "CN":
      result = value

proc normalizeHex*(value: string): string =
  for c in value.toLowerAscii():
    if c in HexDigits:
      result.add(c)

proc keyIdentifier(value: string): string =
  ## OpenSSL 1.x prints the AKI as `keyid:AA:BB...` (plus issuer and serial
  ## lines), 3.x as the bare hex; only the key id matters here
  let lines = value.strip().splitLines()
  if len(lines) == 0:
    return ""
  var first = lines[0].strip()
  if first.toLowerAscii().startsWith("keyid:"):
    first = first[6 .. ^1]
  elif ':' in first and first.split(':', 1)[0].toLowerAscii() in ["dirname", "serial"]:
    return ""
  first.normalizeHex()

proc normalizeKeyType*(name: string): string =
  case name
  of "rsaEncryption", "rsassaPss", "RSA", "RSA-PSS": "rsa"
  of "id-ecPublicKey", "EC": "ec"
  of "ED25519": "ed25519"
  of "ED448": "ed448"
  of "dsaEncryption", "DSA": "dsa"
  else: name.toLowerAscii()

proc normalizeCurve*(name: string): string =
  ## NIST names for the curves known by several names
  case name.toLowerAscii()
  of "prime256v1", "secp256r1", "p-256", "p256": "P-256"
  of "secp384r1", "p-384", "p384": "P-384"
  of "secp521r1", "p-521", "p521": "P-521"
  else: name.toLowerAscii()

proc isWeakSignature*(signature: string, digest = ""): bool =
  let s = (signature & " " & digest).toLowerAscii()
  # `shaWithRSAEncryption` is SHA-0
  if "shawith" in s:
    return true
  for digest in weakDigests:
    var at = s.find(digest)
    while at >= 0:
      let next = at + len(digest)
      # sha1 but not e.g. a sha1xx
      if next >= len(s) or s[next] notin Digits:
        return true
      at = s.find(digest, next)
  false

proc parseCertTime*(value: string): Option[Time] =
  ## `ASN1_TIME_print` format, e.g. `Jan  1 00:00:00 2030 GMT`
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  let parts = value.splitWhitespace()
  if len(parts) != 5 or parts[4] != "GMT":
    return none(Time)
  let month = months.find(parts[0])
  let clock = parts[2].split('.')[0].split(':')
  if month < 0 or len(clock) != 3:
    return none(Time)
  try:
    let dt = dateTime(parseInt(parts[3]), Month(month + 1), parseInt(parts[1]),
                      parseInt(clock[0]), parseInt(clock[1]), parseInt(clock[2]),
                      zone = utc())
    return some(dt.toTime())
  except CatchableError:
    return none(Time)

proc toCertInfo*(cert: X509Cert, path = "", index = 1, count = 1): CertInfo =
  let kv = cert.keyValue
  result = CertInfo(
    path:      path,
    index:     index,
    count:     count,
    subjectDn: cert.subjectNames.toDn(),
    issuerDn:  cert.issuerNames.toDn(),
    subjectCn: cert.subjectNames.commonName(),
    issuerCn:  cert.issuerNames.commonName(),
    ski:       kv.getOrDefault("X509v3 Subject Key Identifier").keyIdentifier(),
    aki:       kv.getOrDefault("X509v3 Authority Key Identifier").keyIdentifier(),
    isCa:      "CA:TRUE" in kv.getOrDefault("X509v3 Basic Constraints"),
    keyType:   kv.getOrDefault("Key Type").normalizeKeyType(),
    keySize:   cert.keySize,
    keyLoaded: cert.keyLoaded,
    curve:     kv.getOrDefault("Key Group").normalizeCurve(),
    signature: kv.getOrDefault("Signature Type"),
    signatureDigest: cert.signatureDigest,
    der:       cert.der,
    sha256:    kv.getOrDefault("SHA256 Fingerprint").normalizeHex(),
    notBefore: kv.getOrDefault("Not Before").parseCertTime(),
    notAfter:  kv.getOrDefault("Not After").parseCertTime(),
  )
  # self-issued; the signature itself is not verified
  result.selfSigned = result.subjectDn == result.issuerDn and
                      (result.aki == "" or result.aki == result.ski)

proc looksLikeDerCert*(data: string): bool =
  ## Certificate ::= SEQUENCE { tbsCertificate SEQUENCE, ... }: both are
  ## longer than 127 bytes, so both have long-form lengths, unlike DER keys
  ## (an INTEGER or a short AlgorithmIdentifier SEQUENCE first)
  proc longForm(c: char): bool = ord(c) in 0x81 .. 0x84
  if len(data) < 4 or data[0] != '\x30' or not data[1].longForm():
    return false
  let inner = 2 + (ord(data[1]) and 0x7f)
  inner + 1 < len(data) and data[inner] == '\x30' and data[inner + 1].longForm()

proc expectedCerts*(data: string): int =
  ## certificates a file holds by its PEM markers, or 1 for a DER certificate
  for marker in pemMarkers:
    result += data.count(marker)
  if result == 0 and data.looksLikeDerCert():
    result = 1

proc looksLikeCert(data: string): bool =
  # PEM anywhere in the file, or DER (an ASN.1 SEQUENCE)
  for marker in pemMarkers:
    if marker in data:
      return true
  trustedMarker in data or (len(data) > 0 and data[0] == '\x30')

proc parseCertFile*(data: string, path = ""): CertScan =
  ## The certificates in `data`, and an error when some of them could not be
  ## checked: malformed or unsupported blocks, more than `maxCertsPerFile`
  ## certificates or `TRUSTED CERTIFICATE` blocks.
  let
    certs = parseX509(data, limit = maxCertsPerFile + 1, lenient = true)
    count = min(len(certs), maxCertsPerFile)
  for i in 0 ..< count:
    result.certs.add(certs[i].toCertInfo(path, i + 1, count))
  var problems: seq[string]
  if len(certs) > maxCertsPerFile:
    problems.add("only the first " & $maxCertsPerFile & " certificates were checked")
  else:
    let expected = data.expectedCerts()
    if len(certs) < expected:
      problems.add($(expected - len(certs)) & " of " & $expected &
                   " certificates could not be parsed (malformed or unsupported)")
  let trusted = data.count(trustedMarker)
  if trusted > 0:
    problems.add($trusted & " TRUSTED CERTIFICATE block(s) are not supported")
  if len(problems) > 0:
    result.errors.add(newSubjectFinding(ruleName, "error", path,
                      "certificate file not fully checked: " & problems.join("; "), path))

proc parseCertInfos*(data: string, path = ""): seq[CertInfo] =
  data.parseCertFile(path).certs

proc hasCertExtension(name: string, extensions: seq[string], wildcard = true): bool =
  if wildcard and "*" in extensions:
    return true
  let lower = name.toLowerAscii()
  for ext in extensions:
    if ext != "*" and lower.endsWith("." & ext.strip(chars = {'.'}).toLowerAscii()):
      return true
  false

proc readHead(path: string): string =
  var f = open(path)
  defer: f.close()
  result = newString(headSize)
  result.setLen(f.readBuffer(addr result[0], headSize))

proc pins(settings: CertificatesConfig): HashSet[string] =
  for (kind, value) in settings.allowedIssuers:
    let pin = value.normalizeHex()
    if kind == "sha256" and pin != "":
      result.incl(pin)

proc isCaBundle(rel, relDir, entry: string): bool =
  isExcluded(rel, caBundleDirs) or
    (entry.toLowerAscii() in caBundleNames and relDir != "" and
     isExcluded(relDir, caBundleNameDirs))

proc dockerignorePath(dir, dockerfilePath: string): string =
  ## `<Dockerfile>.dockerignore` next to the Dockerfile takes precedence over
  ## `<context>/.dockerignore`
  ## https://docs.docker.com/build/concepts/context/#filename-and-location
  if dockerfilePath != "":
    let specific = dockerfilePath & ".dockerignore"
    if fileExists(specific):
      return specific
  let root = dir / ".dockerignore"
  if fileExists(root):
    return root
  ""

proc cleanPath(path: string): string =
  ## Go's `filepath.Clean`: `./a` -> `a`, `a//b` -> `a/b`, `a/../b` -> `b`,
  ## `..` above a leading `/` dropped
  ## https://pkg.go.dev/path/filepath#Clean
  let rooted = path.startsWith('/')
  var parts: seq[string]
  for part in path.split('/'):
    case part
    of "", ".":
      discard
    of "..":
      if len(parts) > 0 and parts[^1] != "..":
        discard parts.pop()
      elif not rooted:
        parts.add(part)
    else:
      parts.add(part)
  result = parts.join("/")
  if rooted:
    result = "/" & result
  elif result == "":
    result = "."

proc parseDockerignore*(content: string): seq[string] =
  ## Patterns as moby's ignorefile.ReadAll reads them, so a re-include such
  ## as `!./cert.pem` matches what docker sends
  ## https://github.com/moby/patternmatcher/blob/main/ignorefile/ignorefile.go
  var first = true
  for line in content.splitLines():
    var p = line
    if first:
      p.removePrefix("\xEF\xBB\xBF")
      first = false
    # a comment only at the very start of the line, as in moby
    if p.startsWith('#'):
      continue
    p = p.strip()
    if p.len == 0:
      continue
    let negate = p.startsWith('!')
    if negate:
      p = p[1 .. ^1].strip()
    if p.len > 0:
      p = p.cleanPath()
      if p.len > 1 and p.startsWith('/'):
        p = p[1 .. ^1]
    if not isValidPattern(p):
      warn("policy: certificates: ignoring invalid .dockerignore pattern: " & line)
      continue
    result.add((if negate: "!" else: "") & p)

proc readDockerignore(dir: string, dockerfilePath = ""): seq[string] =
  let path = dir.dockerignorePath(dockerfilePath)
  if path == "":
    return
  readFile(path).parseDockerignore()

proc prunes(rel: string, patterns: seq[string]): bool =
  isExcluded(rel, patterns) and not hasNegationForDir(rel, patterns)

proc byLocation(a, b: CertInfo): int =
  result = cmp(a.path, b.path)
  if result == 0:
    result = cmp(a.index, b.index)

proc scanFile(scan: var CertScan, full, report, entry: string,
              settings: CertificatesConfig, pins: HashSet[string], bundle: bool) =
  ## Files of skipped CA bundles only supply issuer candidates, so they
  ## report nothing: a missing candidate fails the pin rather than passing.
  var st: Stat
  if stat(cstring(full), st) != 0:
    if not bundle:
      scan.errors.add(newSubjectFinding(ruleName, "error", report,
                      "not checked: " & osErrorMsg(osLastError()), report))
    return
  if not S_ISREG(st.st_mode):
    # FIFOs, sockets and devices: reading could block, and docker sends no
    # contents for them
    trace("policy: certificates: skipping non-regular file " & full)
    return
  try:
    if int64(st.st_size) > int64(settings.maxFileSize):
      if not bundle and (entry.hasCertExtension(settings.extensions, wildcard = false) or
                         full.readHead().looksLikeCert()):
        scan.errors.add(newSubjectFinding(ruleName, "error", report,
                        "not checked: larger than max_file_size (" & $settings.maxFileSize &
                        " bytes)", report))
      return
    let data = readFile(full)
    if not data.looksLikeCert():
      return
    let parsed = data.parseCertFile(report)
    scan.parsed += len(parsed.certs)
    if bundle:
      for cert in parsed.certs:
        if cert.sha256 in pins:
          scan.issuers.add(cert)
    else:
      scan.certs.add(parsed.certs)
      scan.errors.add(parsed.errors)
  except CatchableError:
    if not bundle:
      scan.errors.add(newSubjectFinding(ruleName, "error", report,
                      "not checked: " & getCurrentExceptionMsg(), report))

proc scanContexts*(dirs: seq[string], settings: CertificatesConfig,
                   dockerfilePath = "", mainDir = ""): CertScan =
  ## Certificates in the build context directories. Paths are relative to
  ## the main context `mainDir`; certificates of other (named) contexts are
  ## reported with absolute paths. `dockerfilePath` only selects the
  ## ignore file of the main context, as BuildKit does.
  let pins = settings.pins()
  var visited = 0
  for dir in dirs:
    let isMain = mainDir != "" and dir == mainDir
    let ignore =
      if settings.honorDockerignore:
        try:
          readDockerignore(dir, if isMain: dockerfilePath else: "")
        except CatchableError:
          result.errors.add(newSubjectFinding(ruleName, "error", dir,
                            "could not read .dockerignore: " & getCurrentExceptionMsg()))
          continue
      else: @[]
    # (directory, inside a skipped CA bundle directory)
    var stack = @[("", false)]
    while len(stack) > 0:
      let (relDir, bundled) = stack.pop()
      for kind, entry in walkDir(dir / relDir, relative = true):
        inc(visited)
        if visited > settings.maxFiles:
          result.errors.add(newSubjectFinding(ruleName, "error", dir,
                            "build context has more than " & $settings.maxFiles &
                            " files, certificate scan is incomplete (see certificates.max_files)"))
          return
        let rel = (if relDir == "": entry else: relDir & "/" & entry)
        case kind
        of pcDir:
          if entry == ".git" or rel.prunes(ignore) or rel.prunes(settings.excludePaths):
            continue
          let bundle = bundled or (settings.skipCaBundles and rel.prunes(caBundleDirs))
          if bundle and len(pins) == 0:
            trace("policy: certificates: skipping CA bundle directory " & rel)
            continue
          stack.add((rel, bundle))
        of pcFile:
          if not entry.hasCertExtension(settings.extensions) or
             isExcluded(rel, ignore) or isExcluded(rel, settings.excludePaths):
            continue
          let bundle = bundled or (settings.skipCaBundles and isCaBundle(rel, relDir, entry))
          if bundle:
            trace("policy: certificates: skipping CA bundle " & rel)
            if len(pins) == 0:
              continue
          elif len(settings.includePaths) > 0 and not isExcluded(rel, settings.includePaths):
            continue
          let full = dir / rel
          result.scanFile(full, if isMain: rel else: full, entry, settings, pins, bundle)
          if result.parsed > maxCerts:
            result.errors.add(newSubjectFinding(ruleName, "error", dir,
                              "build context has more than " & $maxCerts &
                              " certificates, certificate scan is incomplete"))
            return
        of pcLinkToFile, pcLinkToDir:
          # docker sends symlinks as links: a target inside the context is
          # scanned on its own and one outside it never reaches the image
          continue

proc pinnedIssuers*(candidates: seq[CertInfo], settings: CertificatesConfig): PinnedIssuers =
  let pins = settings.pins()
  var seen: HashSet[string]
  for c in candidates:
    if c.sha256 in pins and not seen.containsOrIncl(c.sha256):
      result.mgetOrPut(c.subjectDn, @[]).add(c)

proc pinnedIssuer(cert: CertInfo, issuers: PinnedIssuers): bool =
  ## Candidate names and identifiers are untrusted; verify the issuing key
  ## before using the candidate's fingerprint as an issuer pin.
  for other in issuers.getOrDefault(cert.issuerDn):
    if (cert.aki == "" or cert.aki == other.ski) and cert.der.signedBy(other.der):
      return true
  false

proc pinned(cert: CertInfo, settings: CertificatesConfig): bool =
  cert.sha256 != "" and cert.sha256 in settings.pins()

proc issuerAllowed(cert: CertInfo, issuers: PinnedIssuers, settings: CertificatesConfig): bool =
  for (kind, value) in settings.allowedIssuers:
    case kind
    of "cn":
      if globMatch(value, cert.issuerCn):
        return true
    of "dn":
      if globMatch(value, cert.issuerDn):
        return true
    else:
      discard
  cert.pinnedIssuer(issuers)

proc formatDate(t: Time): string =
  t.utc().format("yyyy-MM-dd")

proc violations*(cert: CertInfo, issuers: PinnedIssuers, settings: CertificatesConfig,
                 now: Time): seq[string] =
  if cert.notAfter.isSome():
    let notAfter = cert.notAfter.get()
    if notAfter < now:
      if settings.denyExpired:
        result.add("expired on " & notAfter.formatDate())
    elif settings.expiresWithinDays > 0 and
         notAfter < now + initDuration(days = settings.expiresWithinDays):
      result.add("expires on " & notAfter.formatDate() & ", within " &
                 $settings.expiresWithinDays & " days")
  if settings.denyNotYetValid and cert.notBefore.isSome() and cert.notBefore.get() > now:
    result.add("not valid before " & cert.notBefore.get().formatDate())
  if settings.denySelfSigned and cert.selfSigned and not cert.pinned(settings):
    result.add("self-signed")
  if settings.denyCa and cert.isCa:
    result.add("CA certificate")
  if settings.denyWeakSignatures and cert.signature.isWeakSignature(cert.signatureDigest):
    let details = if cert.signature.isWeakSignature(): "" else: " (" & cert.signatureDigest & ")"
    result.add("weak signature algorithm " & cert.signature & details)
  if len(settings.allowedKeyTypes) > 0:
    var allowed = false
    for t in settings.allowedKeyTypes:
      if t.normalizeKeyType() == cert.keyType:
        allowed = true
    if not allowed:
      let keyType = if cert.keyType != "": cert.keyType else: "unknown"
      result.add("key type " & keyType & " is not allowed")
  if settings.minRsaKeySize > 0 and cert.keyType == "rsa" and cert.keyLoaded and
     cert.keySize < settings.minRsaKeySize:
    result.add("RSA key is " & $cert.keySize & " bits, minimum " & $settings.minRsaKeySize)
  if len(settings.allowedEcCurves) > 0 and cert.keyType == "ec":
    var allowed = false
    for c in settings.allowedEcCurves:
      if c.normalizeCurve() == cert.curve:
        allowed = true
    if not allowed:
      let curve = if cert.curve != "": cert.curve else: "unknown"
      result.add("EC curve " & curve & " is not allowed")
  if len(settings.allowedIssuers) > 0 and not cert.issuerAllowed(issuers, settings):
    result.add("issuer " & cert.issuerDn & " is not allowed")

proc unchecked*(cert: CertInfo, settings: CertificatesConfig): seq[string] =
  ## enabled checks that could not be decided for `cert`
  if cert.notAfter.isNone() and (settings.denyExpired or settings.expiresWithinDays > 0):
    result.add("expiry date could not be parsed")
  if cert.notBefore.isNone() and settings.denyNotYetValid:
    result.add("start date could not be parsed")
  if settings.minRsaKeySize > 0 and cert.keyType == "rsa" and not cert.keyLoaded:
    result.add("RSA key could not be loaded, its size is unknown")

proc subject*(cert: CertInfo): string =
  let name = if cert.subjectCn != "": cert.subjectCn else: cert.subjectDn
  if name == "":
    return cert.path
  cert.path & " (" & name & ")"

proc location*(cert: CertInfo): string =
  if cert.count > 1:
    return cert.path & "#" & $cert.index
  cert.path

proc check*(settings: CertificatesConfig, certs: seq[CertInfo], now: Time,
            issuers: seq[CertInfo] = @[]): seq[PolicyFinding] =
  ## `issuers` are additional `sha256` pin candidates, not checked themselves
  let pinned = pinnedIssuers(certs & issuers, settings)
  for cert in certs:
    let reasons = cert.violations(pinned, settings, now)
    if len(reasons) > 0:
      var reason = "certificate " & reasons.join("; ")
      if settings.message != "":
        reason &= ". " & settings.message
      result.add(newSubjectFinding(ruleName, "violation", cert.subject(), reason, cert.location()))
    let unchecked = cert.unchecked(settings)
    if len(unchecked) > 0:
      result.add(newSubjectFinding(ruleName, "error", cert.subject(),
                                   "certificate not fully checked: " & unchecked.join("; "),
                                   cert.location()))

proc capped*(findings: seq[PolicyFinding], limit = maxFindings): seq[PolicyFinding] =
  ## The first `limit` findings, violations first, and one finding counting
  ## the rest. It is a violation when a dropped finding is, so the policy
  ## result does not change.
  if len(findings) <= limit:
    return findings
  let sorted = findings.sorted(proc(a, b: PolicyFinding): int =
    cmp(a.kind != "violation", b.kind != "violation"))
  result = sorted[0 ..< limit]
  var violations = 0
  for f in sorted[limit .. ^1]:
    if f.kind == "violation":
      inc(violations)
  result.add(newSubjectFinding(ruleName, (if violations > 0: "violation" else: "error"),
                               ruleName, $(len(sorted) - limit) &
                               " more certificate findings not listed"))

proc check*(settings: CertificatesConfig, input: PolicyInput, now = getTime()): seq[PolicyFinding] =
  if len(input.contextDirs) == 0:
    # Push has no build context. For build, the engine reports contexts that
    # are not local directories (`contextErrors`); without any, nothing was
    # checked, which must not pass silently.
    if input.command == "build" and len(input.contextErrors) == 0:
      result.add(newSubjectFinding(ruleName, "error", "build context",
                                   "no local build context to check"))
    return
  let scan = input.contextDirs.scanContexts(settings, input.dockerfilePath,
                                            input.mainContextDir)
  var findings = scan.errors.sorted(proc(a, b: PolicyFinding): int = cmp(a.location, b.location))
  findings.add(settings.check(scan.certs.sorted(byLocation), now, scan.issuers))
  findings.capped()

proc nonNegative(path: openArray[string], default: int): int =
  result = policyIntSetting(path, default)
  if result < 0:
    raise newException(ValueError, "policy." & path.join(".") & " must not be negative")

proc positive(path: openArray[string], default: int): int =
  result = policyIntSetting(path, default)
  if result <= 0:
    raise newException(ValueError, "policy." & path.join(".") & " must be positive")

proc issuerPairs(path: openArray[string]): seq[(string, string)] =
  for (kind, value) in policyPairsSetting(path):
    let k = kind.toLowerAscii()
    if k notin issuerKinds:
      raise newException(ValueError, "unsupported kind in policy." & path.join(".") & ": " &
                         kind & " (expected cn, dn or sha256)")
    result.add((k, value))

proc patterns(path: openArray[string]): seq[string] =
  for p in policyStringsSetting(path):
    if not isValidPattern(p):
      raise newException(ValueError, "invalid pattern in policy." & path.join(".") & ": " & p)
    result.add(p)

proc loadCertificatesConfig*(): Option[CertificatesConfig] =
  if not policyBoolSetting([ruleName, "enabled"], false):
    return none(CertificatesConfig)
  let d = defaultCertificatesConfig()
  var settings = CertificatesConfig(
    denyExpired:        policyBoolSetting([ruleName, "deny_expired"], d.denyExpired),
    denyNotYetValid:    policyBoolSetting([ruleName, "deny_not_yet_valid"], d.denyNotYetValid),
    expiresWithinDays:  nonNegative([ruleName, "expires_within_days"], 0),
    denySelfSigned:     policyBoolSetting([ruleName, "deny_self_signed"], false),
    denyCa:             policyBoolSetting([ruleName, "deny_ca"], false),
    denyWeakSignatures: policyBoolSetting([ruleName, "deny_weak_signatures"], d.denyWeakSignatures),
    minRsaKeySize:      nonNegative([ruleName, "min_rsa_key_size"], d.minRsaKeySize),
    allowedKeyTypes:    policyStringsSetting([ruleName, "allowed_key_types"]),
    allowedEcCurves:    policyStringsSetting([ruleName, "allowed_ec_curves"]),
    allowedIssuers:     issuerPairs([ruleName, "allowed_issuers"]),
    includePaths:       patterns([ruleName, "include_paths"]),
    excludePaths:       patterns([ruleName, "exclude_paths"]),
    extensions:         policyStringsSetting([ruleName, "extensions"]),
    skipCaBundles:      policyBoolSetting([ruleName, "skip_ca_bundles"], d.skipCaBundles),
    honorDockerignore:  policyBoolSetting([ruleName, "honor_dockerignore"], d.honorDockerignore),
    maxFiles:           positive([ruleName, "max_files"], d.maxFiles),
    maxFileSize:        positive([ruleName, "max_file_size"], d.maxFileSize),
    message:            policyStringSetting([ruleName, "message"], ""),
  )
  if len(settings.extensions) == 0:
    settings.extensions = d.extensions
  return some(settings)

const certificatesJsonFields = [
  PolicyJsonField(name: "enabled",              kind: JBool),
  PolicyJsonField(name: "deny_expired",         kind: JBool),
  PolicyJsonField(name: "deny_not_yet_valid",   kind: JBool),
  PolicyJsonField(name: "expires_within_days",  kind: JInt),
  PolicyJsonField(name: "deny_self_signed",     kind: JBool),
  PolicyJsonField(name: "deny_ca",              kind: JBool),
  PolicyJsonField(name: "deny_weak_signatures", kind: JBool),
  PolicyJsonField(name: "min_rsa_key_size",     kind: JInt),
  PolicyJsonField(name: "allowed_key_types",    kind: JArray),
  PolicyJsonField(name: "allowed_ec_curves",    kind: JArray),
  PolicyJsonField(name: "allowed_issuers",      kind: JArray),
  PolicyJsonField(name: "include_paths",        kind: JArray),
  PolicyJsonField(name: "exclude_paths",        kind: JArray),
  PolicyJsonField(name: "extensions",           kind: JArray),
  PolicyJsonField(name: "skip_ca_bundles",      kind: JBool),
  PolicyJsonField(name: "honor_dockerignore",   kind: JBool),
  PolicyJsonField(name: "max_files",            kind: JInt),
  PolicyJsonField(name: "max_file_size",        kind: JInt),
  PolicyJsonField(name: "message",              kind: JString),
]

proc validateCertificatesJson(node: JsonNode, path: string) =
  node.validateFields(certificatesJsonFields, path)
  node{"allowed_issuers"}.validatePairs(path & "allowed_issuers")
  for pair in node{"allowed_issuers"}.getElems():
    let kind = pair[0].getStr()
    if kind.toLowerAscii() notin issuerKinds:
      raise newException(ValueError, path & "allowed_issuers has unsupported kind " &
                         kind & " (expected cn, dn or sha256)")
  for name in ["allowed_key_types", "allowed_ec_curves", "include_paths",
               "exclude_paths", "extensions"]:
    for entry in node{name}.getElems():
      if entry.kind != JString:
        raise newException(ValueError, path & name & " entries must be strings")
  for name in ["expires_within_days", "min_rsa_key_size"]:
    if node{name}.getInt() < 0:
      raise newException(ValueError, path & name & " must not be negative")
  for name in ["max_files", "max_file_size"]:
    if node{name} != nil and node{name}.getInt() <= 0:
      raise newException(ValueError, path & name & " must be positive")

registerPolicyJsonSection(ruleName, validateCertificatesJson)

var loaded: CertificatesConfig

proc loadCertificates(): bool =
  let settings = loadCertificatesConfig()
  if settings.isSome():
    loaded = settings.get()
  return settings.isSome()

proc checkCertificates(input: PolicyInput): seq[PolicyFinding] =
  loaded.check(input)

proc certificatesHint(): PolicyHint =
  result = PolicyHint(
    rule:    ruleName,
    message: (if loaded.message != "": loaded.message
              else: "Replace or remove the reported certificates."),
  )
  for (kind, value) in loaded.allowedIssuers:
    result.allowed.add(kind & ":" & value)

proc loadCertificatesRule*() =
  newPolicyInputRule(ruleName, loadCertificates, checkCertificates,
                     requiresContext = true, hint = certificatesHint)
