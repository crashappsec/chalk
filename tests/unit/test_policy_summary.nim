import std/[os, strutils, tempfiles]
import ../../src/types
import ../../src/policy/engine

const
  digest = "sha256:6784fb0834aa9b6f3f4e5d6c7b8a9f0e1d2c3b4a5968778695a4b3c2d1e0f9a8"
  golden = PolicyHint(rule: "golden_images", message: "Use an approved golden image",
                      allowed: @["docker.io/library/alpine:*", "cgr.dev/chainguard/*"])

proc runeLenAscii(s: string): int =
  # "…" is one rune of three bytes
  len(s.replace("…", "."))

proc build(command = "build", tags = @["app:latest"]): ChalkDict =
  result = ChalkDict()
  result["command"] = pack(command)
  result["tags"] = pack(tags)

proc finding(policyId: string, kind = "violation", image = "nginx:1.27",
             reason = "image is not in the list of allowed golden images. Use an approved golden image",
             source = "from", stage = ""): PolicyFinding =
  PolicyFinding(policyId: policyId, rule: "golden_images", kind: kind, image: image,
                digest: (if image == "": "" else: digest), source: source,
                stage: stage, reason: reason)

proc policy(id, effectiveMode, res: string, findings: seq[PolicyFinding] = @[],
            onError = "allow"): PolicyResult =
  PolicyResult(id: id, mode: effectiveMode, effectiveMode: effectiveMode, onError: onError,
               modeSource: "default", result: res, findings: findings, hints: @[golden])

proc testAuditViolation() =
  let md = renderPolicySummary(
    @[policy("golden-images@1", "audit", "violation", @[finding("golden-images@1")])],
    build(), version = "1.3.0")
  doAssert md.startsWith("> [!WARNING]\n> **Would be blocked under enforce** — " &
                         "1 image is not an approved golden image. Policy `golden-images@1` " &
                         "is in audit mode, so the build continued.\n\n")
  doAssert "#### Chalk build policy · docker build · `app:latest`\n" in md
  doAssert "| Image | Used as | Policy | Why |" in md
  doAssert "| `nginx:1.27@sha256:6784fb0834aa…` | FROM | golden-images@1 | " &
           "Use an approved golden image |" in md
  doAssert "**How to fix:** Use an approved golden image. Allowed: " &
           "`docker.io/library/alpine:*`, `cgr.dev/chainguard/*`" in md
  doAssert "<details><summary>Policy details</summary>\n\n| Policy | Mode | Why this mode | Result | Findings |" in md
  doAssert "| golden-images@1 | audit | default mode | violation | 1 |" in md
  doAssert "- Chalk version: `1.3.0`" in md
  doAssert "- Repository" notin md
  doAssert "Policy report" notin md
  doAssert md.endsWith("\n\n</details>\n")

proc testBlocked() =
  let md = renderPolicySummary(
    @[policy("golden-images@1", "enforce", "blocked", @[finding("golden-images@1")])], build())
  doAssert md.startsWith("> [!CAUTION]\n> **Blocked** — `docker build` stopped before building: " &
                         "1 image is not an approved golden image (policy `golden-images@1`, enforce).\n")
  doAssert "| golden-images@1 | enforce | default mode | blocked | 1 |" in md
  let push = renderPolicySummary(
    @[policy("", "enforce", "blocked", @[finding(""), finding("", image = "busybox")])],
    build("push", @["r/app:1", "r/app:2", "r/app:3"]))
  doAssert "`docker push` stopped before pushing: 2 images are not approved golden images (enforce)." in push
  doAssert "#### Chalk build policy · docker push · `r/app:1` (+2 more)" in push
  # blocked on errors alone
  let errors = renderPolicySummary(
    @[policy("p", "enforce", "blocked", @[finding("p", "error", reason = "digest unknown")], "block")],
    build())
  doAssert "stopped before building: 1 image could not be evaluated and on_error=block (policy `p`, enforce)." in errors
  doAssert "| p | digest unknown |" in errors
  doAssert "How to fix" notin errors

proc testErrorOnly() =
  let md = renderPolicySummary(
    @[policy("p", "enforce", "error", @[finding("p", "error", reason = "could not collect")])],
    build())
  doAssert md.startsWith("> [!NOTE]\n> Policy `p` could not evaluate 1 image; on_error=allow, " &
                         "so the build continued.\n")
  doAssert "| `nginx:1.27@sha256:6784fb0834aa…` | FROM | p | could not collect |" in md
  doAssert "How to fix" notin md
  let config = renderPolicySummary(
    @[policy("", "audit", "error", @[finding("", "error", image = "", source = "", reason = "bad json")])],
    build())
  doAssert config.startsWith("> [!NOTE]\n> The policy could not be evaluated; on_error=allow")
  doAssert "| - | - | (unnamed) | bad json |" in config

proc testPass() =
  let md = renderPolicySummary(@[policy("p", "enforce", "pass")], build())
  doAssert md.startsWith("> [!TIP]\n> All base images are approved golden images (1 policy checked).\n")
  doAssert "| Image |" notin md
  doAssert "How to fix" notin md
  doAssert "| p | enforce | default mode | pass | 0 |" in md
  var custom = policy("a", "audit", "pass")
  custom.hints = @[]
  doAssert "All images passed the build policy (2 policies checked)." in
           renderPolicySummary(@[custom, custom], build())

proc testMultiplePolicies() =
  let md = renderPolicySummary(@[
    policy("golden-images@3", "enforce", "blocked", @[finding("golden-images@3")]),
    policy("chainguard-only@1", "audit", "violation",
           @[finding("chainguard-only@1", source = "copy_from", stage = "build")]),
    policy("other", "audit", "pass"),
  ], build())
  doAssert md.startsWith("> [!CAUTION]\n")
  doAssert "(policy `golden-images@3`, enforce)" in md
  doAssert "| golden-images@3 | enforce | default mode | blocked | 1 |" in md
  doAssert "| chainguard-only@1 | audit | default mode | violation | 1 |" in md
  doAssert "| other | audit | default mode | pass | 0 |" in md
  doAssert "| COPY --from (stage build) | chainguard-only@1 |" in md
  doAssert "**How to fix:** (`golden-images@3`) Use an approved golden image." in md
  doAssert "**How to fix:** (`chainguard-only@1`) Use an approved golden image." in md
  let audits = renderPolicySummary(@[
    policy("a", "audit", "violation", @[finding("a")]),
    policy("b", "audit", "violation", @[finding("b")]),
  ], build())
  doAssert "Policies `a`, `b` are in audit mode" in audits

proc testUsedAs() =
  let md = renderPolicySummary(@[policy("p", "audit", "violation", @[
    finding("p", source = "mount_from", stage = "0"),
    finding("p", image = "alpine@" & digest),
  ])], build())
  doAssert "| RUN --mount from | p |" in md
  doAssert "`alpine@sha256:6784fb0834aa…`" in md
  var bare = finding("p", image = "busybox")
  bare.digest = digest.split(':')[1]
  doAssert "`busybox@sha256:6784fb0834aa…`" in
           renderPolicySummary(@[policy("p", "audit", "violation", @[bare])], build())

proc testEnforceRepos() =
  var settings = PolicyConfig(id: "p", mode: "audit", onError: "allow",
                              effectiveMode: "enforce", modeSource: "enforce_repos",
                              repo: "github.com/acme/app",
                              enforceRepos: @[("glob", "github.com/acme/*")])
  let res = evaluatePolicy(settings, @[], PolicyInput(), @[finding("")])
  doAssert res.effectiveMode == "enforce" and res.result == "blocked"
  let md = renderPolicySummary(@[res], build())
  doAssert "| p | enforce | enforce_repos match (`github.com/acme/app`) | blocked | 1 |" in md
  doAssert "- Repository: `github.com/acme/app`" in md
  settings.effectiveMode = "audit"
  settings.modeSource = "default"
  settings.repo = ""
  let unknown = renderPolicySummary(@[evaluatePolicy(settings, @[], PolicyInput())], build())
  doAssert "| p | audit | repo unknown → default mode | pass | 0 |" in unknown
  doAssert "- Repository: `unknown`" in unknown

proc testHintsFromRules() =
  let hinted = PolicyRule(name: "golden_images", load: proc(): bool = true,
                          check: proc(s: seq[PolicySubject]): seq[PolicyFinding] = discard,
                          hint: proc(): PolicyHint = golden)
  let res = evaluatePolicy(PolicyConfig(mode: "audit"), @[hinted], PolicyInput())
  doAssert res.hints == @[golden]

proc testEscaping() =
  doAssert mdText("a|b\nc\r\nd") == "a\\|b c d"
  doAssert mdText("<script>&") == "&lt;script&gt;&amp;"
  doAssert mdText("") == "-"
  doAssert mdCode("a`b|c") == "`a'b\\|c`"
  var p = policy("x|y", "audit", "violation",
                 @[finding("x|y", image = "img|`x`", reason = "line1\nline2 | <b>")])
  p.hints = @[]
  let md = renderPolicySummary(@[p], build())
  doAssert "| x\\|y | audit | default mode | violation | 1 |" in md
  doAssert "| `img\\|'x'@sha256:6784fb0834aa…` |" in md
  doAssert "line1 line2 \\| &lt;b&gt; |" in md
  for line in md.splitLines():
    if line.startsWith("|"):
      doAssert line.replace("\\|", "").count('|') in [5, 6]

proc testTruncation() =
  let cell = mdText(repeat("x", 1000))
  doAssert cell.runeLenAscii() == maxCellLen
  doAssert cell.endsWith("…")
  # escaping happens after truncation so an escape is never cut in half
  doAssert mdText(repeat("|", 300)).endsWith("\\|…")
  var p = policy("p", "audit", "violation", @[finding("p")])
  p.hints[0].message = repeat("m", 1000)
  for i in 0 ..< maxAllowed + 4:
    p.hints[0].allowed.add("img" & $i)
  let md = renderPolicySummary(@[p], build())
  doAssert "| " & repeat("m", maxCellLen - 1) & "… |" in md
  doAssert "`img" & $(maxAllowed - 3) & "`, +6 more" in md
  doAssert "`img" & $(maxAllowed - 2) & "`" notin md

proc testRowCaps() =
  var findings: seq[PolicyFinding]
  for i in 0 ..< maxFindingRows + 7:
    findings.add(finding("p", image = "img" & $i))
  var policies = @[policy("p", "audit", "violation", findings)]
  for i in 0 ..< maxPolicyRows + 2:
    policies.add(policy("q" & $i, "audit", "pass"))
  let md = renderPolicySummary(policies, build())
  doAssert $(maxFindingRows + 7) & " images are not approved golden images" in md
  doAssert "| p | audit | default mode | violation | " & $len(findings) & " |" in md
  doAssert "`img" & $(maxFindingRows - 1) & "@" in md
  doAssert "`img" & $maxFindingRows & "@" notin md
  doAssert "_7 more findings not shown, see the policy report._" in md
  doAssert "_3 more policies not shown._" in md
  doAssert len(md) < 64 * 1024

proc testReportLocation() =
  doAssert withoutQuery("https://b.s3.amazonaws.com/k/r.json?X-Amz-Signature=s#f") ==
           "https://b.s3.amazonaws.com/k/r.json"
  doAssert withoutQuery("https://u:p@b.s3.amazonaws.com/k?x=1") == "https://b.s3.amazonaws.com/k"
  let md = renderPolicySummary(@[policy("p", "audit", "violation", @[finding("p")])], build(),
                               @["https://b.s3.amazonaws.com/k/r.json?X-Amz-Credential=secret"])
  doAssert "- Policy report: `https://b.s3.amazonaws.com/k/r.json`\n\n</details>" in md
  doAssert "secret" notin md and "?" notin md

proc testNothingPendingLeavesFileUntouched() =
  let (f, path) = createTempFile("summary", ".md")
  f.write("existing\n")
  f.close()
  putEnv("GITHUB_STEP_SUMMARY", path)
  writePolicySummary(@["https://example.com/x"])
  delEnv("GITHUB_STEP_SUMMARY")
  doAssert readFile(path) == "existing\n"
  removeFile(path)

testAuditViolation()
testBlocked()
testErrorOnly()
testPass()
testMultiplePolicies()
testUsedAs()
testEnforceRepos()
testHintsFromRules()
testEscaping()
testTruncation()
testRowCaps()
testReportLocation()
testNothingPendingLeavesFileUntouched()
