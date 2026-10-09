import std/[json, os, strutils, tempfiles, times]
import ../../src/types
import ../../src/policy/engine
import ../../src/policy/rules
import ../../src/policy/rules/certificates

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
  settings.check(PolicyInput(command: "build", contextDirs: dirs), now)

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

  # unknown kinds are errors unless another entry allows the issuer
  settings.allowedIssuers = @[("ski", "x"), ("cn", "Chalk Test Root CA")]
  let found = settings.findings(@[ctx])
  assertEq(found.locations(), newSeq[string]())
  assertEq(found.locations("error"), @["self.pem"])
  doAssert "unsupported allowed_issuers kind(s): ski" in found.reasonOf("self.pem")

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

proc testScanning() =
  let ctx = newContext({
    "a/expired.pem": "expired.pem",
    "ignored/expired.pem": "expired.pem",
    "ignored/keep.pem": "expired.pem",
    "excluded/expired.pem": "expired.pem",
    "notes/expired.txt": "expired.pem",
    "noext": "expired.pem",
    "ca-certificates.crt": "expired.pem",
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
  assertEq(settings.findings(@[ctx]).locations(), @["a/expired.pem", "ignored/keep.pem"])

  settings.honorDockerignore = false
  settings.skipCaBundles = false
  settings.extensions = @["*"]
  assertEq(settings.findings(@[ctx]).locations(),
           @["a/expired.pem", "ca-certificates.crt", "ignored/expired.pem", "ignored/keep.pem",
             "noext", "notes/expired.txt", "rootfs/etc/ssl/certs/expired.pem"])

  settings.includePaths = @["a", "notes/*.txt"]
  assertEq(settings.findings(@[ctx]).locations(), @["a/expired.pem", "notes/expired.txt"])

  # other contexts are reported with absolute paths
  settings = defaultCertificatesConfig()
  let found = settings.findings(@[outside, ctx])
  doAssert "expired.pem" in found.locations()
  doAssert ctx / "a/expired.pem" in found.locations()

  settings.maxFileSize = 100
  assertEq(settings.findings(@[ctx]).len, 0)

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
                                   dockerfilePath: dfDir / "Dockerfile")
  let dfFound = settings.check(withDockerfile, now).locations()
  assertEq(dfFound, @[outside / "expired.pem", "excluded/expired.pem",
                      "ignored/expired.pem", "ignored/keep.pem"])
  let noSpecific = PolicyInput(command: "build", contextDirs: @[ctx],
                               dockerfilePath: ctx / "Dockerfile")
  assertEq(settings.check(noSpecific, now).locations(), @["a/expired.pem", "excluded/expired.pem", "ignored/keep.pem"])

  # push has no build context
  assertEq(settings.check(PolicyInput(command: "push", pushTargets: @["app:1"]), now).len, 0)

proc rejects(text, reason: string) =
  try:
    discard parsePolicyJson(text)
    doAssert false, "accepted: " & text
  except ValueError:
    doAssert reason in getCurrentExceptionMsg(), getCurrentExceptionMsg()

proc testJson() =
  loadPolicyRules()
  rejects("""{"certificates": {"enabeld": true}}""", "unknown field policy.certificates.enabeld")
  rejects("""{"certificates": {"enabled": "yes"}}""", "policy.certificates.enabled must be a boolean")
  rejects("""{"certificates": []}""", "policy.certificates must be an object")
  rejects("""{"certificates": {"allowed_issuers": [["cn"]]}}""", "[kind, value] string pairs")
  rejects("""{"certificates": {"allowed_key_types": [1]}}""", "allowed_key_types entries must be strings")
  rejects("""{"certificates": {"min_rsa_key_size": -1}}""", "min_rsa_key_size must not be negative")
  rejects("""{"certificates": {"max_files": 0}}""", "max_files must be positive")
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
      "allowed_issuers": [["cn", "Acme *"], ["sha256", caSha256]],
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
  doAssert rules[0].load()
  let hint = rules[0].hint()
  assertEq(hint.rule, "certificates")
  assertEq(hint.message, "Use the Acme PKI")
  assertEq(hint.allowed, @["cn:Acme *", "sha256:" & caSha256])
  let res = evaluatePolicy(policy, rules, PolicyInput(command: "build", contextDirs: @[ctx]))
  assertEq(res.result, "blocked")
  assertEq(res.findings.locations(), @["expired.pem"])
  doAssert res.findings[0].reason.endsWith(". Use the Acme PKI")
  setPolicyJson("")

proc main() =
  testParsing()
  testHelpers()
  testDefaultChecks()
  testSelfSignedAndCa()
  testAllowedIssuers()
  testKeys()
  testScanning()
  testJson()

main()
