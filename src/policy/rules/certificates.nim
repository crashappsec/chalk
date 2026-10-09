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
  strutils,
  tables,
  times,
]
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
  ## well-known CA bundles that would otherwise flood findings
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
  caBundleDirs = @[
    "**/etc/ssl/certs",
    "**/etc/pki/ca-trust",
    "**/etc/pki/tls/certs",
    "**/usr/share/ca-certificates",
    "**/usr/local/share/ca-certificates",
  ]
  maxCertsPerFile = 1000
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
  else: name

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

proc parseCertInfos*(data: string, path = ""): seq[CertInfo] =
  let certs = parseX509(data, limit = maxCertsPerFile)
  for i, cert in certs:
    result.add(cert.toCertInfo(path, i + 1, len(certs)))

proc looksLikeCert(data: string): bool =
  # PEM anywhere in the file, or DER (an ASN.1 SEQUENCE)
  "-----BEGIN CERTIFICATE-----" in data or
    "-----BEGIN X509 CERTIFICATE-----" in data or
    (len(data) > 0 and data[0] == '\x30')

proc hasCertExtension(name: string, extensions: seq[string]): bool =
  if "*" in extensions:
    return true
  let lower = name.toLowerAscii()
  for ext in extensions:
    if lower.endsWith("." & ext.strip(chars = {'.'}).toLowerAscii()):
      return true
  false

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

proc readDockerignore(dir: string, dockerfilePath = ""): seq[string] =
  let path = dir.dockerignorePath(dockerfilePath)
  if path == "":
    return
  for line in readFile(path).splitLines():
    let p = line.strip()
    if p.len == 0 or p.startsWith('#'):
      continue
    let negate = p.startsWith('!')
    var pattern = (if negate: p[1 .. ^1] else: p).strip()
    while pattern.startsWith('/'):
      pattern = pattern[1 .. ^1]
    if not isValidPattern(pattern):
      warn("policy: certificates: ignoring invalid .dockerignore pattern: " & p)
      continue
    result.add((if negate: "!" else: "") & pattern)

proc prunes(rel: string, patterns: seq[string]): bool =
  isExcluded(rel, patterns) and not hasNegationForDir(rel, patterns)

proc byLocation(a, b: CertInfo): int =
  result = cmp(a.path, b.path)
  if result == 0:
    result = cmp(a.index, b.index)

proc scanContexts*(dirs: seq[string], settings: CertificatesConfig,
                   dockerfilePath = ""): CertScan =
  ## Certificates in the build context directories. Paths are relative to
  ## the first (main) context; certificates of other (named) contexts are
  ## reported with absolute paths. `dockerfilePath` only selects the
  ## ignore file of the main context, as BuildKit does.
  var visited = 0
  for n, dir in dirs:
    let ignore =
      if settings.honorDockerignore:
        try:
          readDockerignore(dir, if n == 0: dockerfilePath else: "")
        except CatchableError:
          result.errors.add(newSubjectFinding(ruleName, "error", dir,
                            "could not read .dockerignore: " & getCurrentExceptionMsg()))
          continue
      else: @[]
    var stack = @[""]
    while len(stack) > 0:
      let relDir = stack.pop()
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
          if settings.skipCaBundles and rel.prunes(caBundleDirs):
            continue
          stack.add(rel)
        of pcFile:
          if not entry.hasCertExtension(settings.extensions) or
             isExcluded(rel, ignore) or isExcluded(rel, settings.excludePaths):
            continue
          if len(settings.includePaths) > 0 and not isExcluded(rel, settings.includePaths):
            continue
          if settings.skipCaBundles and (entry.toLowerAscii() in caBundleNames or
                                         isExcluded(rel, caBundleDirs)):
            trace("policy: certificates: skipping CA bundle " & rel)
            continue
          let
            full   = dir / rel
            report = if n == 0: rel else: full
          var data: string
          try:
            if getFileSize(full) > settings.maxFileSize:
              trace("policy: certificates: skipping large file " & full)
              continue
            data = readFile(full)
          except CatchableError:
            trace("policy: certificates: could not read " & full & ": " & getCurrentExceptionMsg())
            continue
          if not data.looksLikeCert():
            continue
          result.certs.add(data.parseCertInfos(report))
        of pcLinkToFile, pcLinkToDir:
          # docker sends symlinks as links: a target inside the context is
          # scanned on its own and one outside it never reaches the image
          continue

proc unknownIssuerKinds(settings: CertificatesConfig): seq[string] =
  for (kind, _) in settings.allowedIssuers:
    if kind notin ["cn", "dn", "sha256"] and kind notin result:
      result.add(kind)

proc issuerCerts(cert: CertInfo, all: seq[CertInfo]): seq[CertInfo] =
  ## Candidate names and identifiers are untrusted; verify the issuing key
  ## before using the candidate's fingerprint as an issuer pin.
  for other in all:
    if other.subjectDn == cert.issuerDn and (cert.aki == "" or cert.aki == other.ski) and
       cert.der.signedBy(other.der):
      result.add(other)

proc pinned(certs: seq[CertInfo], settings: CertificatesConfig): bool =
  for (kind, value) in settings.allowedIssuers:
    if kind != "sha256":
      continue
    for c in certs:
      if c.sha256 != "" and c.sha256 == value.normalizeHex():
        return true
  false

proc issuerAllowed(cert: CertInfo, all: seq[CertInfo], settings: CertificatesConfig): bool =
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
  cert.issuerCerts(all).pinned(settings)

proc formatDate(t: Time): string =
  t.utc().format("yyyy-MM-dd")

proc violations*(cert: CertInfo, all: seq[CertInfo], settings: CertificatesConfig,
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
  if settings.denySelfSigned and cert.selfSigned and not @[cert].pinned(settings):
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
      result.add("key type " & cert.keyType & " is not allowed")
  if settings.minRsaKeySize > 0 and cert.keyType == "rsa" and cert.keySize < settings.minRsaKeySize:
    result.add("RSA key is " & $cert.keySize & " bits, minimum " & $settings.minRsaKeySize)
  if len(settings.allowedEcCurves) > 0 and cert.keyType == "ec":
    var allowed = false
    for c in settings.allowedEcCurves:
      if c.normalizeCurve() == cert.curve:
        allowed = true
    if not allowed:
      let curve = if cert.curve != "": cert.curve else: "unknown"
      result.add("EC curve " & curve & " is not allowed")
  if len(settings.allowedIssuers) > 0 and len(settings.unknownIssuerKinds()) == 0 and
     not cert.issuerAllowed(all, settings):
    result.add("issuer " & cert.issuerDn & " is not allowed")

proc subject*(cert: CertInfo): string =
  let name = if cert.subjectCn != "": cert.subjectCn else: cert.subjectDn
  if name == "":
    return cert.path
  cert.path & " (" & name & ")"

proc location*(cert: CertInfo): string =
  if cert.count > 1:
    return cert.path & "#" & $cert.index
  cert.path

proc check*(settings: CertificatesConfig, certs: seq[CertInfo], now: Time): seq[PolicyFinding] =
  let unknownKinds = settings.unknownIssuerKinds()
  for cert in certs:
    let reasons = cert.violations(certs, settings, now)
    if len(reasons) > 0:
      var reason = "certificate " & reasons.join("; ")
      if settings.message != "":
        reason &= ". " & settings.message
      result.add(newSubjectFinding(ruleName, "violation", cert.subject(), reason, cert.location()))
    # like golden_images, an unknown kind can only be decided by another entry
    if len(unknownKinds) > 0 and not cert.issuerAllowed(certs, settings):
      result.add(newSubjectFinding(ruleName, "error", cert.subject(),
                                   "unsupported allowed_issuers kind(s): " & unknownKinds.join(", "),
                                   cert.location()))

proc check*(settings: CertificatesConfig, input: PolicyInput, now = getTime()): seq[PolicyFinding] =
  if len(input.contextDirs) == 0:
    trace("policy: certificates: no local build context to check (" & input.command & ")")
    return
  let scan = input.contextDirs.scanContexts(settings, input.dockerfilePath)
  result.add(scan.errors)
  result.add(settings.check(scan.certs.sorted(byLocation), now))

proc nonNegative(path: openArray[string], default: int): int =
  result = policyIntSetting(path, default)
  if result < 0:
    raise newException(ValueError, "policy." & path.join(".") & " must not be negative")

proc positive(path: openArray[string], default: int): int =
  result = policyIntSetting(path, default)
  if result <= 0:
    raise newException(ValueError, "policy." & path.join(".") & " must be positive")

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
    allowedIssuers:     policyPairsSetting([ruleName, "allowed_issuers"]),
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
  newPolicyInputRule(ruleName, loadCertificates, checkCertificates, hint = certificatesHint)
