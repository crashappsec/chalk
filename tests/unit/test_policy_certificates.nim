import std/[json, os, strutils, tempfiles, times]
from std/posix import mkfifo
import ../../src/types
import ../../src/policy/engine
import ../../src/policy/rules
import ../../src/policy/rules/certificates
import ../../src/utils/x509

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

const
  fixtures = currentSourcePath().parentDir() / "fixtures" / "certs"
  # openssl x509 -noout -fingerprint -sha256 -in tests/unit/fixtures/certs/ca.pem
  caSha256 = "B9:54:33:E9:6A:CB:55:E5:51:08:97:A2:F8:FC:B3:2A:5C:36:98:21:53:14:59:3F:92:4A:39:B8:B7:18:9F:72"
  selfSha256 = "3a62f94bf53b6a1e1feb4975c71a71fb811fa2edc90268db915f22f2aba9b2c2"

let now = dateTime(2026, mOct, 9, zone = utc()).toTime()

proc fixture(name: string): string =
  readFile(fixtures / name)

proc info(name: string): CertInfo =
  let certs = fixture(name).parseCertInfos(name)
  assertEq(len(certs), 1)
  certs[0]

proc newContext(files: openArray[(string, string)]): string =
  ## files as (context path, fixture name or literal content after `=`)
  result = createTempDir("chalk-policy-certs-", "")
  for (path, source) in files:
    createDir(parentDir(result / path))
    let content = if source.startsWith("="): source[1 .. ^1] else: fixture(source)
    writeFile(result / path, content)

proc findings(settings: CertificatesConfig, dirs: seq[string]): seq[PolicyFinding] =
  settings.check(PolicyInput(command: "build", contextDirs: dirs, mainContextDir: dirs[0]), now)

proc locations(findings: seq[PolicyFinding], kind = "violation"): seq[string] =
  for f in findings:
    if f.kind == kind:
      result.add(f.location)

proc reasonOf(findings: seq[PolicyFinding], location: string): string =
  for f in findings:
    if f.location == location:
      return f.reason

proc testParsing() =
  let ca = info("ca.pem")
  assertEq(ca.subjectDn, "CN=Chalk Test Root CA,O=Chalk Test,C=US")
  assertEq(ca.issuerDn, ca.subjectDn)
  assertEq(ca.subjectCn, "Chalk Test Root CA")
  doAssert ca.selfSigned and ca.isCa
  assertEq(ca.keyType, "rsa")
  assertEq(ca.keySize, 2048)
  assertEq(ca.signature, "sha256WithRSAEncryption")
  assertEq(ca.signatureDigest, "SHA256")
  assertEq(ca.sha256, caSha256.normalizeHex())
  assertEq(ca.notBefore.get(), dateTime(2020, mJan, 1, zone = utc()).toTime())
  assertEq(ca.notAfter.get(), dateTime(2120, mJan, 1, zone = utc()).toTime())

  let leaf = info("leaf.pem")
  assertEq(leaf.issuerCn, "Chalk Test Root CA")
  doAssert not leaf.selfSigned and not leaf.isCa
  assertEq(leaf.aki, ca.ski)
  assertEq(leaf.keyType, "ec")
  assertEq(leaf.curve, "P-256")
  assertEq(leaf.keySize, 256)

  let der = fixture("leaf.der").parseCertInfos("leaf.der")
  assertEq(len(der), 1)
  assertEq(der[0].sha256, leaf.sha256)
  assertEq(der[0].der, leaf.der)
  doAssert leaf.der.signedBy(ca.der)
  doAssert not leaf.der.signedBy("")
  doAssert not "not DER".signedBy(ca.der)

  let chain = fixture("chain.pem").parseCertInfos("chain.pem")
  assertEq(len(chain), 2)
  assertEq(chain[1].sha256, ca.sha256)
  assertEq(chain[1].location(), "chain.pem#2")
  assertEq(chain[1].subject(), "chain.pem (Chalk Test Root CA)")
  assertEq(leaf.location(), "leaf.pem")

  let self = info("self-signed.pem")
  doAssert self.selfSigned and not self.isCa
  assertEq(self.curve, "P-384")
  assertEq(self.sha256, selfSha256)
  assertEq(info("weak-rsa.pem").keySize, 1024)
  assertEq(info("sha1.pem").signature, "sha1WithRSAEncryption")

  assertEq(parseCertInfos("not a certificate").len, 0)
  assertEq(parseCertInfos("\x30\x03\x02\x01\x01").len, 0)

  # a malformed block neither hides the certificates after it nor passes
  let
    bad = "-----BEGIN CERTIFICATE-----\nnot base64!\n-----END CERTIFICATE-----\n"
    bundle = parseCertFile(fixture("leaf.pem") & bad & fixture("expired.pem"), "b.pem")
  assertEq(bundle.certs.len, 2)
  assertEq(bundle.certs[1].location(), "b.pem#2")
  assertEq(bundle.certs[1].subjectCn, "expired.example.com")
  assertEq(bundle.errors.len, 1)
  assertEq(bundle.errors[0].kind, "error")
  assertEq(bundle.errors[0].location, "b.pem")
  doAssert "1 of 3 certificates could not be parsed" in bundle.errors[0].reason
  assertEq(parseCertFile(fixture("chain.pem")).errors.len, 0)
  assertEq(parseCertFile(fixture("leaf.der")).errors.len, 0)
  doAssert fixture("leaf.der").looksLikeDerCert()
  doAssert not "\x30\x03\x02\x01\x01".looksLikeDerCert()
  let truncatedDer = fixture("leaf.der")[0 .. 40]
  assertEq(truncatedDer.expectedCerts(), 1)
  assertEq(parseCertFile(truncatedDer, "t.der").errors.len, 1)
  let trusted = parseCertFile("-----BEGIN TRUSTED CERTIFICATE-----\nAAAA\n" &
                              "-----END TRUSTED CERTIFICATE-----\n", "t.pem")
  assertEq(trusted.certs.len, 0)
  doAssert "1 TRUSTED CERTIFICATE block(s) are not supported" in trusted.errors[0].reason
  var many = ""
  for i in 0 .. maxCertsPerFile:
    many &= fixture("leaf.pem")
  let capped = parseCertFile(many, "many.pem")
  assertEq(capped.certs.len, maxCertsPerFile)
  assertEq(capped.certs[^1].count, maxCertsPerFile)
  doAssert "only the first 1000 certificates were checked" in capped.errors[0].reason

  # keys OpenSSL cannot load: the certificate is still checked
  doAssert ca.keyLoaded
  let unknownKey = info("unknown-key.pem")
  doAssert not unknownKey.keyLoaded
  assertEq(unknownKey.keyType, "1.2.840.113549.1.1.99")
  assertEq(unknownKey.keySize, 0)
  assertEq(unknownKey.subjectDn, ca.subjectDn)
  let unknownCurve = info("unknown-curve.pem")
  doAssert not unknownCurve.keyLoaded
  assertEq(unknownCurve.keyType, "ec")
  assertEq(unknownCurve.curve, "1.2.840.10045.3.1.99")
  # and does not end the bundle
  assertEq(parseCertInfos(fixture("unknown-key.pem") & fixture("leaf.pem")).len, 2)
  # artifact detection (the certs codec) stays strict, so a file such as an
  # ELF binary with embedded certificates is not claimed as a certificate
  assertEq(parseX509(fixture("unknown-key.pem") & fixture("leaf.pem")).len, 0)
  assertEq(parseX509(fixture("leaf.pem") & bad & fixture("expired.pem")).len, 1)
  assertEq(parseX509(bad & fixture("leaf.pem")).len, 0)
  assertEq(parseX509(bad & fixture("leaf.pem"), lenient = true).len, 1)

proc testHelpers() =
  for weak in ["sha1WithRSAEncryption", "ecdsa-with-SHA1", "md5WithRSAEncryption",
               "md2WithRSAEncryption", "dsaWithSHA1", "shaWithRSAEncryption"]:
    doAssert weak.isWeakSignature(), weak
  for strong in ["sha256WithRSAEncryption", "ecdsa-with-SHA384", "ED25519",
                 "sha512-224WithRSAEncryption", "RSASSA-PSS", ""]:
    doAssert not strong.isWeakSignature(), strong
  assertEq(parseCertTime("Feb 29 23:59:59 2024 GMT").get(),
           dateTime(2024, mFeb, 29, 23, 59, 59, zone = utc()).toTime())
  doAssert parseCertTime("Jan  1 00:00:00.5 2030 GMT").isSome()
  doAssert parseCertTime("").isNone()
  doAssert parseCertTime("Foo  1 00:00:00 2030 GMT").isNone()
  assertEq(normalizeCurve("secp256r1"), "P-256")
  assertEq(normalizeCurve("P-384"), "P-384")
  assertEq(normalizeCurve("brainpoolP256r1"), "brainpoolp256r1")
  assertEq(normalizeKeyType("RSA"), "rsa")
  assertEq(toDn(@[("C", "US"), ("O", "Acme, Inc."), ("CN", "x")]), "CN=x,O=Acme\\, Inc.,C=US")

proc testDefaultChecks() =
  let
    ctx = newContext({
      "certs/ca.pem": "ca.pem", "certs/leaf.pem": "leaf.pem", "certs/leaf.der": "leaf.der",
      "certs/chain.pem": "chain.pem", "certs/expired.pem": "expired.pem",
      "certs/future.pem": "future.pem", "certs/weak-rsa.pem": "weak-rsa.pem",
      "certs/sha1.pem": "sha1.pem", "self-signed.crt": "self-signed.pem",
    })
    settings = defaultCertificatesConfig()
    found = settings.findings(@[ctx])
  defer: removeDir(ctx)
  assertEq(len(found), 4)
  for f in found:
    assertEq(f.rule, "certificates")
    assertEq(f.image, "")
  assertEq(found.reasonOf("certs/expired.pem"), "certificate expired on 2020-01-01")
  assertEq(found.reasonOf("certs/future.pem"), "certificate not valid before 2100-01-01")
  assertEq(found.reasonOf("certs/weak-rsa.pem"), "certificate RSA key is 1024 bits, minimum 2048")
  assertEq(found.reasonOf("certs/sha1.pem"), "certificate weak signature algorithm sha1WithRSAEncryption")
  for f in found:
    if f.location == "certs/expired.pem":
      assertEq(f.subject, "certs/expired.pem (expired.example.com)")

  var off = settings
  off.denyExpired = false
  off.denyNotYetValid = false
  off.denyWeakSignatures = false
  off.minRsaKeySize = 0
  assertEq(off.findings(@[ctx]).len, 0)

  var soon = off
  soon.expiresWithinDays = 30
  let late = settings.check(@[info("leaf.pem")], dateTime(2119, mDec, 15, zone = utc()).toTime())
  assertEq(late.len, 0)
  let expiring = soon.check(@[info("leaf.pem")], dateTime(2119, mDec, 15, zone = utc()).toTime())
  assertEq(expiring.len, 1)
  assertEq(expiring[0].reason, "certificate expires on 2120-01-01, within 30 days")

  # undecidable checks are errors, not silent passes
  var noDates = info("leaf.pem")
  noDates.notAfter = none(Time)
  noDates.notBefore = none(Time)
  let undecided = settings.check(@[noDates], now)
  assertEq(undecided.locations("error"), @["leaf.pem"])
  assertEq(undecided[0].reason,
           "certificate not fully checked: expiry date could not be parsed; start date could not be parsed")
  assertEq(off.check(@[noDates], now).len, 0)

  var msg = settings
  msg.message = "See https://example.com/pki"
  assertEq(msg.check(@[info("expired.pem")], now)[0].reason,
           "certificate expired on 2020-01-01. See https://example.com/pki")

proc testSelfSignedAndCa() =
  let ctx = newContext({"ca.pem": "ca.pem", "leaf.pem": "leaf.pem",
                        "chain.pem": "chain.pem", "self.pem": "self-signed.pem"})
  defer: removeDir(ctx)
  var settings = defaultCertificatesConfig()
  settings.denySelfSigned = true
  assertEq(settings.findings(@[ctx]).locations(), @["ca.pem", "chain.pem#2", "self.pem"])
  # a pinned trust anchor is not reported as self-signed
  settings.allowedIssuers = @[("sha256", caSha256)]
  assertEq(settings.findings(@[ctx]).reasonOf("self.pem"),
           "certificate self-signed; issuer CN=self.example.com is not allowed")
  assertEq(settings.findings(@[ctx]).locations(), @["self.pem"])

  settings = defaultCertificatesConfig()
  settings.denyCa = true
  assertEq(settings.findings(@[ctx]).locations(), @["ca.pem", "chain.pem#2"])

proc testAllowedIssuers() =
  let ctx = newContext({"ca.pem": "ca.pem", "leaf.pem": "leaf.pem", "self.pem": "self-signed.pem"})
  defer: removeDir(ctx)
  var settings = defaultCertificatesConfig()
  settings.allowedIssuers = @[("cn", "Chalk Test *")]
  assertEq(settings.findings(@[ctx]).locations(), @["self.pem"])
  settings.allowedIssuers = @[("dn", "CN=Chalk Test Root CA,O=Chalk Test,C=US")]
  assertEq(settings.findings(@[ctx]).locations(), @["self.pem"])
  settings.allowedIssuers = @[("dn", "CN=Other*")]
  assertEq(settings.findings(@[ctx]).locations(), @["ca.pem", "leaf.pem", "self.pem"])
  settings.allowedIssuers = @[("sha256", caSha256.toLowerAscii())]
  assertEq(settings.findings(@[ctx]).locations(), @["self.pem"])
  settings.allowedIssuers = @[("sha256", selfSha256)]
  assertEq(settings.findings(@[ctx]).locations(), @["ca.pem", "leaf.pem"])

  # the issuing CA must be in the context to match its fingerprint
  let leafOnly = newContext({"leaf.pem": "leaf.pem"})
  defer: removeDir(leafOnly)
  settings.allowedIssuers = @[("sha256", caSha256)]
  assertEq(settings.findings(@[leafOnly]).locations(), @["leaf.pem"])

  # a pinned CA in a skipped CA bundle still resolves the pin
  let bundled = newContext({"leaf.pem": "leaf.pem", "rootfs/etc/ssl/certs/ca.pem": "ca.pem",
                            "venv/certifi/cacert.pem": "self-signed.pem",
                            "self.pem": "self-signed.pem"})
  defer: removeDir(bundled)
  settings.allowedIssuers = @[("sha256", caSha256)]
  assertEq(settings.findings(@[bundled]).locations(), @["self.pem"])
  settings.allowedIssuers = @[("cn", "Chalk Test Root CA")]
  assertEq(settings.findings(@[bundled]).locations(), @["self.pem"])

proc testKeys() =
  let ctx = newContext({"ca.pem": "ca.pem", "leaf.pem": "leaf.pem", "self.pem": "self-signed.pem"})
  defer: removeDir(ctx)
  var settings = defaultCertificatesConfig()
  settings.allowedKeyTypes = @["rsa"]
  assertEq(settings.findings(@[ctx]).locations(), @["leaf.pem", "self.pem"])
  assertEq(settings.findings(@[ctx]).reasonOf("leaf.pem"), "certificate key type ec is not allowed")
  settings.allowedKeyTypes = @["rsa", "ec"]
  settings.allowedEcCurves = @["prime256v1"]
  assertEq(settings.findings(@[ctx]).locations(), @["self.pem"])
  assertEq(settings.findings(@[ctx]).reasonOf("self.pem"), "certificate EC curve P-384 is not allowed")
  settings.allowedEcCurves = @["P-256", "secp384r1"]
  assertEq(settings.findings(@[ctx]).len, 0)
  settings.minRsaKeySize = 4096
  assertEq(settings.findings(@[ctx]).locations(), @["ca.pem"])

  settings = defaultCertificatesConfig()
  let unknown = newContext({"key.pem": "unknown-key.pem", "curve.pem": "unknown-curve.pem"})
  defer: removeDir(unknown)
  assertEq(settings.findings(@[unknown]).len, 0)
  settings.allowedEcCurves = @["P-256"]
  assertEq(settings.findings(@[unknown]).reasonOf("curve.pem"),
           "certificate EC curve 1.2.840.10045.3.1.99 is not allowed")
  settings.allowedKeyTypes = @["rsa", "ec"]
  assertEq(settings.findings(@[unknown]).reasonOf("key.pem"),
           "certificate key type 1.2.840.113549.1.1.99 is not allowed")
  # an RSA key that cannot be loaded has no size to compare
  var rsa = info("ca.pem")
  rsa.keyLoaded = false
  rsa.keySize = 0
  let unsized = defaultCertificatesConfig().check(@[rsa], now)
  assertEq(unsized.len, 1)
  assertEq(unsized[0].kind, "error")
  assertEq(unsized[0].reason,
           "certificate not fully checked: RSA key could not be loaded, its size is unknown")

proc testSignatureSecurity() =
  let weak = info("sha1-pss.pem")
  let strong = info("sha256-pss.pem")
  assertEq(weak.signature, "rsassaPss")
  assertEq(strong.signature, weak.signature)
  assertEq(weak.signatureDigest, "SHA1")
  assertEq(strong.signatureDigest, "SHA256")
  doAssert weak.signature.isWeakSignature(weak.signatureDigest)
  doAssert not strong.signature.isWeakSignature(strong.signatureDigest)
  var settings = defaultCertificatesConfig()
  let pss = newContext({"weak.pem": "sha1-pss.pem", "strong.pem": "sha256-pss.pem"})
  defer: removeDir(pss)
  assertEq(settings.findings(@[pss]).locations(), @["weak.pem"])
  assertEq(settings.findings(@[pss]).reasonOf("weak.pem"),
           "certificate weak signature algorithm rsassaPss (SHA1)")
  settings.denyWeakSignatures = false
  assertEq(settings.findings(@[pss]).len, 0)

  let trusted = info("ca.pem")
  let spoofed = info("spoofed-ca.pem")
  let leaf = info("spoofed-issuer.pem")
  assertEq(spoofed.subjectDn, trusted.subjectDn)
  assertEq(spoofed.ski, trusted.ski)
  assertEq(leaf.issuerDn, trusted.subjectDn)
  assertEq(leaf.aki, trusted.ski)
  doAssert leaf.der.signedBy(spoofed.der)
  doAssert not leaf.der.signedBy(trusted.der)
  settings = defaultCertificatesConfig()
  settings.allowedIssuers = @[("sha256", caSha256)]
  let ctx = newContext({"ca.pem": "ca.pem", "leaf.pem": "spoofed-issuer.pem"})
  defer: removeDir(ctx)
  assertEq(settings.findings(@[ctx]).locations(), @["leaf.pem"])
  settings.denySelfSigned = true
  assertEq(settings.findings(@[ctx]).locations(), @["leaf.pem"])
  # If several issuers share a DN/SKI, only the actual signer can satisfy a pin.
  settings.allowedIssuers = @[("sha256", spoofed.sha256)]
  assertEq(settings.check(@[trusted, spoofed, leaf], now).locations(), @["ca.pem"])
  # Name allowlists retain their documented, unauthenticated semantics.
  settings.denySelfSigned = false
  settings.allowedIssuers = @[("cn", "Chalk Test Root CA")]
  assertEq(settings.findings(@[ctx]).len, 0)

proc testScanning() =
  let ctx = newContext({
    "a/expired.pem": "expired.pem",
    "ignored/expired.pem": "expired.pem",
    "ignored/keep.pem": "expired.pem",
    "excluded/expired.pem": "expired.pem",
    "notes/expired.txt": "expired.pem",
    "noext": "expired.pem",
    # bundle names are only skipped where packages install bundles
    "ca-certificates.crt": "expired.pem",
    "lib/certifi/cacert.pem": "expired.pem",
    "rootfs/etc/ssl/certs/expired.pem": "expired.pem",
    ".git/expired.pem": "expired.pem",
    "key.pem": "=-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n",
    "empty.pem": "=",
    ".dockerignore": "=# comment\n/ignored\n!ignored/keep.pem\n",
  })
  defer: removeDir(ctx)
  let outside = newContext({"expired.pem": "expired.pem"})
  defer: removeDir(outside)
  createSymlink(outside / "expired.pem", ctx / "link.pem")
  createSymlink(outside, ctx / "linkdir")

  var settings = defaultCertificatesConfig()
  settings.excludePaths = @["excluded"]
  assertEq(settings.findings(@[ctx]).locations(),
           @["a/expired.pem", "ca-certificates.crt", "ignored/keep.pem"])

  settings.honorDockerignore = false
  settings.skipCaBundles = false
  settings.extensions = @["*"]
  assertEq(settings.findings(@[ctx]).locations(),
           @["a/expired.pem", "ca-certificates.crt", "ignored/expired.pem", "ignored/keep.pem",
             "lib/certifi/cacert.pem", "noext", "notes/expired.txt",
             "rootfs/etc/ssl/certs/expired.pem"])

  settings.includePaths = @["a", "notes/*.txt"]
  assertEq(settings.findings(@[ctx]).locations(), @["a/expired.pem", "notes/expired.txt"])

  # other contexts are reported with absolute paths
  settings = defaultCertificatesConfig()
  let found = settings.findings(@[outside, ctx])
  doAssert "expired.pem" in found.locations()
  doAssert ctx / "a/expired.pem" in found.locations()

  # files too large to check are errors when they look like certificates
  settings.maxFileSize = 100
  let large = settings.findings(@[ctx])
  assertEq(large.locations(), newSeq[string]())
  assertEq(large.locations("error").len, 4)
  doAssert "ca-certificates.crt" in large.locations("error")
  doAssert "not checked: larger than max_file_size (100 bytes)" in large.reasonOf("a/expired.pem")
  let big = newContext({"big.bin": "=" & repeat('x', 200), "big.txt": "expired.pem",
                        "small.pem": "=x"})
  defer: removeDir(big)
  settings.extensions = @["*"]
  assertEq(settings.findings(@[big]).locations("error"), @["big.txt"])
  settings.extensions = @["*", "bin"]
  assertEq(settings.findings(@[big]).locations("error"), @["big.bin", "big.txt"])

  # FIFOs are not read, which would block
  let special = newContext({"cert.pem": "expired.pem"})
  defer: removeDir(special)
  doAssert mkfifo(cstring(special / "fifo.pem"), 0o600) == 0
  settings = defaultCertificatesConfig()
  settings.extensions = @["*"]
  assertEq(settings.findings(@[special]).locations(), @["cert.pem"])

  settings = defaultCertificatesConfig()
  settings.maxFiles = 3
  let truncated = settings.findings(@[ctx])
  assertEq(truncated[0].kind, "error")
  doAssert "certificate scan is incomplete" in truncated[0].reason
  assertEq(truncated[0].subject, ctx)

  # <Dockerfile>.dockerignore takes precedence over the context's, main context only
  let dfDir = newContext({
    "Dockerfile": "=FROM scratch\n",
    # would hide the other context's expired.pem if it applied there
    "Dockerfile.dockerignore": "=a\nexpired.pem\n",
  })
  defer: removeDir(dfDir)
  settings = defaultCertificatesConfig()
  let withDockerfile = PolicyInput(command: "build", contextDirs: @[ctx, outside],
                                   mainContextDir: ctx, dockerfilePath: dfDir / "Dockerfile")
  let dfFound = settings.check(withDockerfile, now).locations()
  assertEq(dfFound, @[outside / "expired.pem", "ca-certificates.crt", "excluded/expired.pem",
                      "ignored/expired.pem", "ignored/keep.pem"])
  let noSpecific = PolicyInput(command: "build", contextDirs: @[ctx], mainContextDir: ctx,
                               dockerfilePath: ctx / "Dockerfile")
  assertEq(settings.check(noSpecific, now).locations(),
           @["a/expired.pem", "ca-certificates.crt", "excluded/expired.pem", "ignored/keep.pem"])
  # a named context never uses <Dockerfile>.dockerignore, even when the main
  # context is not local
  let namedOnly = PolicyInput(command: "build", contextDirs: @[ctx],
                              dockerfilePath: dfDir / "Dockerfile")
  let namedFound = settings.check(namedOnly, now).locations()
  doAssert ctx / "a/expired.pem" in namedFound
  doAssert "a/expired.pem" notin namedFound

  # push has no build context
  assertEq(settings.check(PolicyInput(command: "push", pushTargets: @["app:1"]), now).len, 0)
  # a build without a local context is an error, reported once
  let noContext = settings.check(PolicyInput(command: "build"), now)
  assertEq(noContext.len, 1)
  assertEq(noContext[0].kind, "error")
  assertEq(noContext[0].reason, "no local build context to check")
  let remote = PolicyInput(command: "build", contextErrors: @[PolicyFinding(
    kind: "error", subject: "-", reason: "the build context from stdin cannot be checked")])
  assertEq(settings.check(remote, now).len, 0)

proc rejects(text, reason: string) =
  ## the document is unusable as a whole, or as its only policy
  var message = ""
  try:
    let configs = parsePolicyJson(text)
    doAssert configs.len == 1, "accepted: " & text
    message = configs[0].configError
  except ValueError:
    message = getCurrentExceptionMsg()
  doAssert message != "", "accepted: " & text
  doAssert reason in message, message

proc testJson() =
  loadPolicyRules()
  rejects("""{"certificates": {"enabeld": true}}""", "unknown field policy.certificates.enabeld")
  rejects("""{"certificates": {"enabled": "yes"}}""", "policy.certificates.enabled must be a boolean")
  rejects("""{"certificates": []}""", "policy.certificates must be an object")
  rejects("""{"certificates": {"allowed_issuers": [["cn"]]}}""", "[kind, value] string pairs")
  rejects("""{"certificates": {"allowed_key_types": [1]}}""", "allowed_key_types entries must be strings")
  rejects("""{"certificates": {"min_rsa_key_size": -1}}""", "min_rsa_key_size must not be negative")
  rejects("""{"certificates": {"max_files": 0}}""", "max_files must be positive")
  rejects("""{"certificates": {"allowed_issuers": [["ski", "x"]]}}""",
          "allowed_issuers has unsupported kind ski")
  doAssert parsePolicyJson("""{"policies": [{"id": "a", "certificates": {"y": 1}}]}""")[0].configError != ""

  setPolicyJson("""{"mode": "audit", "certificates": {"enabled": false}}""")
  selectPolicy(policyConfigs()[0])
  doAssert loadCertificatesConfig().isNone()

  setPolicyJson($(%*{
    "id": "certs@1",
    "mode": "enforce",
    "certificates": {
      "enabled": true,
      "deny_self_signed": true,
      "expires_within_days": 30,
      "min_rsa_key_size": 3072,
      "allowed_key_types": ["rsa", "ec"],
      "allowed_ec_curves": ["P-256"],
      "allowed_issuers": [["CN", "Acme *"], ["sha256", caSha256]],
      "exclude_paths": ["test/**"],
      "message": "Use the Acme PKI",
    },
  }))
  let policy = policyConfigs()[0]
  assertEq(policy.configError, "")
  selectPolicy(policy)
  let settings = loadCertificatesConfig().get()
  doAssert settings.denySelfSigned and settings.denyExpired and settings.denyWeakSignatures
  assertEq(settings.expiresWithinDays, 30)
  assertEq(settings.minRsaKeySize, 3072)
  assertEq(settings.allowedEcCurves, @["P-256"])
  assertEq(settings.allowedIssuers, @[("cn", "Acme *"), ("sha256", caSha256)])
  assertEq(settings.extensions, defaultExtensions)
  assertEq(settings.maxFiles, defaultCertificatesConfig().maxFiles)
  assertEq(settings.message, "Use the Acme PKI")

  # the shape campaigns compiles (campaigns internal/services/policies/testdata)
  setPolicyJson(readFile(currentSourcePath().parentDir() / "fixtures" / "policy_config_certificates.json"))
  let compiled = policyConfigs()[0]
  assertEq(compiled.configError, "")
  selectPolicy(compiled)
  let full = loadCertificatesConfig().get()
  doAssert full.denyExpired and not full.denyNotYetValid and full.denySelfSigned and full.denyCa
  assertEq(full.allowedIssuers.len, 3)
  assertEq(full.includePaths, @["deploy"])
  assertEq(full.excludePaths, @["test", "**/testdata"])
  assertEq(full.extensions, @["pem", "crt"])
  doAssert not full.skipCaBundles and full.honorDockerignore
  assertEq(full.maxFiles, 50000)
  assertEq(full.maxFileSize, 262144)
  selectPolicy(policy)

  # through the engine: an enforced violation blocks
  let ctx = newContext({"expired.pem": "expired.pem"})
  defer: removeDir(ctx)
  var rules: seq[PolicyRule]
  for rule in policyRules():
    if rule.name == "certificates":
      rules.add(rule)
  doAssert rules[0].requiresContext
  doAssert rules[0].load()
  let hint = rules[0].hint()
  assertEq(hint.rule, "certificates")
  assertEq(hint.message, "Use the Acme PKI")
  assertEq(hint.allowed, @["cn:Acme *", "sha256:" & caSha256])
  let res = evaluatePolicy(policy, rules, PolicyInput(command: "build", contextDirs: @[ctx],
                                                          mainContextDir: ctx))
  assertEq(res.result, "blocked")
  assertEq(res.findings.locations(), @["expired.pem"])
  doAssert res.findings[0].reason.endsWith(". Use the Acme PKI")
  # an unscannable context is the engine's error only, not a second one
  let stdin = evaluatePolicy(policy, rules, PolicyInput(command: "build", contextErrors: @[
    PolicyFinding(kind: "error", subject: "-", reason: "the build context from stdin cannot be checked")]))
  assertEq(stdin.findings.len, 1)
  assertEq(stdin.findings[0].rule, "certificates")
  assertEq(stdin.findings[0].subject, "-")
  setPolicyJson("")

proc main() =
  testParsing()
  testHelpers()
  testDefaultChecks()
  testSelfSignedAndCa()
  testAllowedIssuers()
  testKeys()
  testSignatureSecurity()
  testScanning()
  testJson()

main()
