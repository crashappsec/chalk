import std/[json, os, strutils, tables, tempfiles]
import ../../src/types
import ../../src/utils/http
import ../../src/policy/api
import ../../src/policy/configuration
import ../../src/policy/dockerignore
import ../../src/policy/engine
import ../../src/policy/github
import ../../src/policy/purl
import ../../src/policy/rules/dependency_review

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

const
  fixtures  = currentSourcePath().parentDir() / "fixtures"
  page1     = fixtures / "dependency_review_compare_1.json"
  page2     = fixtures / "dependency_review_compare_2.json"
  configFixture = fixtures / "policy_config_vulnerabilities.json"
  base      = "1111111111111111111111111111111111111111"
  head      = "2222222222222222222222222222222222222222"
  compareUrl = "https://api.github.com/repos/acme/app/dependency-graph/compare/" &
               base & "..." & head & "?per_page=100"
  nextUrl   = "https://api.github.com/repositories/1/dependency-graph/compare/" &
              base & "..." & head & "?per_page=100&page=2"
  lodash    = "pkg:npm/lodash@4.17.20"
  pyyaml    = "pkg:pypi/pyyaml@5.3"

var
  calls:     seq[tuple[url: string, headers: HttpHeaders]]
  responses: seq[GithubResponse]
  sleeps:    seq[int]

proc respond(code: int, body = "[]", headers: openArray[(string, string)] = []): GithubResponse =
  GithubResponse(code: code, body: body, headers: newHttpHeaders(headers))

proc pages(): seq[GithubResponse] =
  @[respond(200, readFile(page1), {"Link": "<" & nextUrl & ">; rel=\"next\", <" & nextUrl &
                                            ">; rel=\"last\""}),
    respond(200, readFile(page2))]

githubFetcher = proc(url: string, headers: HttpHeaders): GithubResponse =
  calls.add((url, headers))
  if len(responses) == 0:
    raise newException(IOError, "connection refused")
  result = responses[0]
  responses.delete(0)
reviewSleeper = proc(ms: int) = sleeps.add(ms)

proc reset() =
  calls     = @[]
  responses = @[]
  sleeps    = @[]
  clearDependencyReviewCache()
  discard takePolicyNotices()
  dependencyReviewMark = nil

const githubEnv = ["GITHUB_ACTIONS", "GITHUB_EVENT_NAME", "GITHUB_EVENT_PATH", "GITHUB_REPOSITORY",
                   "GITHUB_API_URL", "GITHUB_TOKEN", "GITHUB_SERVER_URL", "RUNNER_TEMP"]

proc clearEnv() =
  for name in githubEnv:
    delEnv(name)

proc prPayload(): JsonNode =
  %*{"pull_request": {"base": {"sha": base}, "head": {"sha": head}}}

proc github(event = "pull_request", payload = prPayload(), token = "t0ken") =
  ## a GitHub Actions job for `event`
  clearEnv()
  let dir = createTempDir("chalk-review-", "")
  writeFile(dir / "event.json", $payload)
  putEnv("GITHUB_ACTIONS", "true")
  putEnv("GITHUB_EVENT_NAME", event)
  putEnv("GITHUB_EVENT_PATH", dir / "event.json")
  putEnv("GITHUB_REPOSITORY", "acme/app")
  if token != "":
    putEnv("GITHUB_TOKEN", token)
  reset()

proc refs(): ReviewRefs =
  ReviewRefs(event: "pull_request", repo: "acme/app", api: "https://api.github.com",
             base: base, head: head)

proc reviewed(): DependencyReview =
  DependencyReview(status: rsReviewed,
                   changes: parseChanges(readFile(page1)) & parseChanges(readFile(page2)))

proc defaults(): VulnerabilitiesConfig =
  VulnerabilitiesConfig(source: "vulnerabilities", minSeverity: "high", scopes: @["runtime"],
                        events: @defaultReviewEvents, contextOnly: true)

proc subjects(findings: seq[PolicyFinding]): seq[string] =
  for f in findings:
    result.add(f.subject)

proc testNextLink() =
  assertEq(nextLink("<https://api.github.com/x?page=2>; rel=\"next\", " &
                    "<https://api.github.com/x?page=3>; rel=\"last\""),
           "https://api.github.com/x?page=2")
  assertEq(nextLink("<https://api.github.com/x?page=1>; rel=\"prev\", " &
                    "<https://api.github.com/x?page=1>; rel=\"first\""), "")
  assertEq(nextLink("<https://a/x?page=2>; title=\"t\"; rel=\"prev next\""), "https://a/x?page=2")
  assertEq(nextLink("<https://a/x?page=2>;rel=next"), "https://a/x?page=2")
  assertEq(nextLink(""), "")
  assertEq(nextLink("https://a/x; rel=\"next\""), "")
  # a target URL may contain commas, e.g. a branch name in the basehead
  assertEq(nextLink("<https://a/compare/x,y...z?page=2>; rel=\"next\""),
           "https://a/compare/x,y...z?page=2")
  assertEq(nextLink("<https://a/x?v=1,2>; rel=\"prev\", <https://a/x?v=2,3>; rel=\"next\""),
           "https://a/x?v=2,3")
  assertEq(nextLink("<https://a/x?v=1,2>; rel=\"next\", <https://a/x?v=2,3>; rel=\"last\""),
           "https://a/x?v=1,2")

proc testEventRefs() =
  assertEq(eventRefs("pull_request", prPayload()), (base, head))
  assertEq(eventRefs("pull_request_target", prPayload()), (base, head))
  assertEq(eventRefs("merge_group", %*{"merge_group": {"base_sha": base, "head_sha": head}}),
           (base, head))
  assertEq(eventRefs("push", %*{"before": base, "after": head}), (base, head))
  # a new branch has nothing to compare with, a deleted one nothing to review
  let zero = repeat('0', 40)
  assertEq(eventRefs("push", %*{"before": zero, "after": head}), ("", ""))
  assertEq(eventRefs("push", %*{"before": base, "after": zero, "deleted": true}), ("", ""))
  assertEq(eventRefs("push", %*{"before": base, "after": head, "created": true}), ("", ""))
  for (event, payload) in [("pull_request", %*{"pull_request": {"base": {"sha": base}}}),
                           ("merge_group", %*{}), ("push", %*{"after": head}),
                           ("workflow_dispatch", %*{})]:
    try:
      discard eventRefs(event, payload)
      doAssert false, "accepted " & event & " " & $payload
    except ValueError:
      discard

proc testReviewRefs() =
  clearEnv()
  doAssert reviewRefs(defaultReviewEvents).isNone()
  github()
  let r = reviewRefs(defaultReviewEvents).get()
  assertEq(r.repo, "acme/app")
  assertEq(r.api, "https://api.github.com")
  assertEq((r.base, r.head), (base, head))
  putEnv("GITHUB_API_URL", "https://ghe.example.com/api/v3/")
  assertEq(reviewRefs(defaultReviewEvents).get().api, "https://ghe.example.com/api/v3")
  # push is opt-in
  github("push", %*{"before": base, "after": head})
  doAssert reviewRefs(defaultReviewEvents).isNone()
  assertEq(reviewRefs(@reviewEvents).get().base, base)
  github("push", %*{"before": repeat('0', 40), "after": head})
  doAssert reviewRefs(@reviewEvents).isNone()
  github()
  delEnv("GITHUB_EVENT_PATH")
  try:
    discard reviewRefs(defaultReviewEvents)
    doAssert false
  except ValueError:
    doAssert "GITHUB_EVENT_PATH" in getCurrentExceptionMsg()
  clearEnv()

proc testParse() =
  let changes = parseChanges(readFile(page1))
  assertEq(len(changes), 4)
  assertEq(changes[0].changeType, "added")
  assertEq(changes[0].manifest, "services/api/package-lock.json")
  assertEq(changes[0].packageUrl, lodash)
  assertEq(changes[0].scope, "runtime")
  assertEq(len(changes[0].vulnerabilities), 2)
  assertEq(changes[0].vulnerabilities[1].severity, "moderate")
  assertEq(changes[0].vulnerabilities[0].ghsaId, "GHSA-35jh-r3h4-6jhm")
  # GHES may omit the scope; runtime, as actions/dependency-review-action assumes
  let unscoped = parseChanges("""[{"change_type": "added", "manifest": "go.mod",
                                   "ecosystem": "go", "name": "x", "vulnerabilities": []}]""")
  assertEq(unscoped[0].scope, "runtime")
  for bad in ["{}", "[1]", "not json"]:
    try:
      discard parseChanges(bad)
      doAssert false, "accepted " & bad
    except CatchableError:
      discard
  assertEq(snapshotWarnings("U29tZSBtYW5pZmVzdHMgd2VyZSBub3QgcHJvY2Vzc2Vk"),
           "Some manifests were not processed")
  assertEq(snapshotWarnings(" "), "")

proc testCompare() =
  github()
  responses = pages()
  var review = compareDependencies(refs())
  assertEq(review.status, rsReviewed)
  assertEq(len(review.changes), 7)
  assertEq(len(calls), 2)
  assertEq(calls[0].url, compareUrl)
  assertEq(calls[1].url, nextUrl)
  assertEq(calls[0].headers["Authorization"].toString(), "Bearer t0ken")
  assertEq(calls[0].headers["X-GitHub-Api-Version"].toString(), "2026-03-10")

  # GitHub Enterprise Server uses its default API version
  reset()
  responses = @[respond(200)]
  var ghes = refs()
  ghes.api = "https://ghe.example.com/api/v3"
  assertEq(compareDependencies(ghes).status, rsReviewed)
  doAssert not calls[0].headers.hasKey("X-GitHub-Api-Version")
  doAssert calls[0].url.startsWith("https://ghe.example.com/api/v3/repos/acme/app/")

  # an explicit scheme-default port and none are the same origin
  reset()
  ghes.api = "https://ghe.example.com:443/api/v3"
  responses = @[respond(200, "[]", {"Link": "<https://ghe.example.com/api/v3/x?page=2>; rel=\"next\""}),
                respond(200)]
  assertEq(compareDependencies(ghes).status, rsReviewed)
  assertEq(len(calls), 2)

  # no Code Security, dependency graph off or a token that cannot read it
  for code in [401, 403]:
    reset()
    responses = @[respond(code, """{"message": "Forbidden"}""")]
    review = compareDependencies(refs())
    assertEq(review.status, rsUnavailable)
    assertEq(len(calls), 1)
    doAssert "HTTP " & $code & " (Forbidden)" in review.reason, review.reason
    doAssert "https://github.com/acme/app/settings/security_analysis" in review.reason, review.reason

  reset()
  responses = @[respond(404, """{"message": "Not Found"}""")]
  review = compareDependencies(refs())
  assertEq(review.status, rsFailed)
  assertEq(len(calls), 1)
  doAssert "HTTP 404: Not Found" in review.reason, review.reason

  # transient failures are retried
  reset()
  responses = @[respond(502, "bad gateway")] & pages()
  review = compareDependencies(refs())
  assertEq(review.status, rsReviewed)
  assertEq(len(calls), 3)
  assertEq(sleeps, @[1000])

  reset()
  responses = @[respond(403, """{"message": "API rate limit exceeded"}""",
                        {"x-ratelimit-remaining": "0"})]
  responses.add(responses[0])
  responses.add(responses[0])
  review = compareDependencies(refs())
  assertEq(review.status, rsFailed)
  assertEq(len(calls), 3)
  doAssert "rate limit" in review.reason, review.reason

  reset()
  review = compareDependencies(refs())
  assertEq(review.status, rsFailed)
  assertEq(len(calls), 3)
  assertEq(sleeps, @[1000, 2000])
  doAssert "connection refused" in review.reason, review.reason

  reset()
  responses = @[respond(200, "{\"oops\": 1}")]
  assertEq(compareDependencies(refs()).status, rsFailed)

  # the token is not sent to another host
  reset()
  responses = @[respond(200, "[]", {"Link": "<https://evil.example.com/x>; rel=\"next\""})]
  review = compareDependencies(refs())
  assertEq(review.status, rsFailed)
  assertEq(len(calls), 1)

  github(token = "")
  review = compareDependencies(refs())
  assertEq(review.status, rsUnavailable)
  assertEq(len(calls), 0)
  doAssert "GITHUB_TOKEN" in review.reason

proc testSnapshotWarnings() =
  github()
  let warning = {"x-github-dependency-graph-snapshot-warnings": "UGVuZGluZyBzbmFwc2hvdA=="}
  responses = @[respond(200, "[]", warning)]
  var review = compareDependencies(refs())
  assertEq(review.status, rsReviewed)
  assertEq(review.snapshotWarnings, "Pending snapshot")
  assertEq(len(calls), 1)
  reset()
  responses = @[respond(200, "[]", warning), respond(200, readFile(page2))]
  review = compareDependencies(refs(), waitSeconds = 30)
  assertEq(review.snapshotWarnings, "")
  assertEq(len(review.changes), 3)
  assertEq(len(calls), 2)
  assertEq(sleeps, @[10_000])
  # a wait of one retry interval still retries once
  reset()
  responses = @[respond(200, "[]", warning), respond(200, readFile(page2))]
  review = compareDependencies(refs(), waitSeconds = 10)
  assertEq(review.snapshotWarnings, "")
  assertEq(sleeps, @[10_000])
  # persistent warnings stop at the deadline
  reset()
  responses = @[respond(200, "[]", warning), respond(200, "[]", warning),
                respond(200, "[]", warning)]
  review = compareDependencies(refs(), waitSeconds = 20)
  assertEq(review.snapshotWarnings, "Pending snapshot")
  assertEq(len(calls), 3)
  assertEq(sleeps, @[10_000, 10_000])

proc testCache() =
  github()
  responses = pages()
  discard dependencyReview(refs())
  assertEq(dependencyReview(refs()).changes.len, 7)
  assertEq(len(calls), 2)

  # other chalk commands of the job read it from RUNNER_TEMP
  let temp = createTempDir("chalk-runner-temp-", "")
  putEnv("RUNNER_TEMP", temp)
  reset()
  responses = pages()
  discard dependencyReview(refs())
  reset()
  let cached = dependencyReview(refs())
  assertEq(len(calls), 0)
  assertEq(cached.status, rsReviewed)
  assertEq(cached.changes, reviewed().changes)

  # a truncated or foreign cache file is ignored and the review re-fetched
  for file in walkFiles(temp / "chalk-dependency-review-*.json"):
    writeFile(file, """{"status": "reviewed"}""")
  reset()
  responses = pages()
  assertEq(dependencyReview(refs()).changes.len, 7)
  assertEq(len(calls), 2)

  # unavailable is kept too, failures only for the process
  var other = refs()
  other.head = "3333333333333333333333333333333333333333"
  reset()
  responses = @[respond(403)]
  discard dependencyReview(other)
  reset()
  assertEq(dependencyReview(other).status, rsUnavailable)
  assertEq(len(calls), 0)
  other.head = "4444444444444444444444444444444444444444"
  reset()
  responses = @[respond(404)]
  assertEq(dependencyReview(other).status, rsFailed)
  assertEq(dependencyReview(other).status, rsFailed)
  assertEq(len(calls), 1)
  reset()
  responses = @[respond(200)]
  assertEq(dependencyReview(other).status, rsReviewed)
  removeDir(temp)
  clearEnv()

proc testIncompleteCache() =
  # A later policy's wait must still run, including in the same process.
  for newProcess in [false, true]:
    github()
    let temp = createTempDir("chalk-incomplete-cache-", "")
    putEnv("RUNNER_TEMP", temp)
    let warning = {"x-github-dependency-graph-snapshot-warnings": "UGVuZGluZyBzbmFwc2hvdA=="}
    responses = @[respond(200, "[]", warning)]
    assertEq(dependencyReview(refs()).snapshotWarnings, "Pending snapshot")
    if newProcess:
      reset()
    else:
      # an equal or shorter wait reuses the incomplete review in-process
      assertEq(dependencyReview(refs()).snapshotWarnings, "Pending snapshot")
      assertEq(len(calls), 1)
    responses = @[respond(200, "[]", warning), respond(200, readFile(page2))]
    let complete = dependencyReview(refs(), waitSeconds = 30)
    assertEq(complete.snapshotWarnings, "")
    assertEq(complete.changes.len, 3)
    assertEq(len(calls), if newProcess: 2 else: 3)
    assertEq(sleeps, @[10_000])
    removeDir(temp)
  clearEnv()

proc testCacheCredentials() =
  # A missing or insufficient token in an earlier step must not disable
  # review after credentials change, in memory or on disk.
  for newProcess in [false, true]:
    for (token, code) in [("", 0), ("bad-token", 401), ("restricted-token", 403)]:
      github(token = token)
      let temp = createTempDir("chalk-auth-cache-", "")
      putEnv("RUNNER_TEMP", temp)
      if code != 0:
        responses = @[respond(code)]
      assertEq(dependencyReview(refs()).status, rsUnavailable)
      putEnv("GITHUB_TOKEN", "working-token")
      if newProcess:
        reset()
      let before = len(calls)
      responses = pages()
      let complete = dependencyReview(refs())
      assertEq(complete.status, rsReviewed)
      assertEq(complete.changes.len, 7)
      assertEq(len(calls) - before, 2)
      removeDir(temp)
  clearEnv()

proc rejects(json, reason: string) =
  let configs = parsePolicyJson("""{"policies": [{"id": "a", "vulnerabilities": """ & json & "}]}")
  doAssert reason in configs[0].configError, configs[0].configError

proc load(json: string): Option[VulnerabilitiesConfig] =
  setPolicyJson(json)
  let configs = policyConfigs()
  doAssert configs[0].configError == "", configs[0].configError
  selectPolicy(configs[0])
  result = loadVulnerabilitiesConfig()
  setPolicyJson("")

proc testConfig() =
  let path = "policy.policies[0].vulnerabilities."
  rejects("""{"enabeld": true}""", "unknown field " & path & "enabeld")
  rejects("""{"min_severity": "severe"}""", path & "min_severity must be one of")
  rejects("""{"scopes": ["test"]}""", path & "scopes entries must be one of")
  rejects("""{"scopes": [1]}""", path & "scopes entries must be strings")
  rejects("""{"ignore_advisories": [1]}""", path & "ignore_advisories entries must be strings")
  rejects("""{"ignore_packages": ["lodash"]}""",
          path & "ignore_packages: invalid entry \"lodash\": must start with pkg:")
  rejects("""{"ignore_packages": ["pkg:npm/lodash@^4"]}""", "unsupported version range")
  rejects("""{"max_findings": -1}""", path & "max_findings must not be negative")
  rejects("""{"dependency_review": true}""", path & "dependency_review must be a object")
  rejects("""{"dependency_review": {"event": []}}""", "unknown field " & path & "dependency_review.event")
  rejects("""{"dependency_review": {"events": ["release"]}}""",
          path & "dependency_review.events entries must be one of")
  rejects("""{"dependency_review": {"snapshot_wait_seconds": 601}}""",
          path & "dependency_review.snapshot_wait_seconds must be between 0 and 600")
  let sast = parsePolicyJson("""{"sast": {"dependency_review": "no"}}""")
  doAssert "policy.sast.dependency_review must be a boolean" in sast[0].configError, sast[0].configError

  doAssert load("""{"mode": "audit"}""").isNone()
  doAssert load("""{"mode": "audit", "vulnerabilities": {}}""").isNone()
  let d = load("""{"mode": "audit", "vulnerabilities": {"enabled": true}}""").get()
  assertEq(d.source, "vulnerabilities")
  assertEq(d.minSeverity, "high")
  assertEq(d.scopes, @["runtime"])
  assertEq(d.events, @defaultReviewEvents)
  doAssert d.contextOnly
  assertEq(d.snapshotWaitSeconds, 0)
  assertEq(d.maxFindings, 0)

  let full = load(readFile(configFixture)).get()
  assertEq(full.minSeverity, "medium")
  assertEq(full.scopes, @["runtime", "development"])
  assertEq(full.ignoreAdvisories, @["GHSA-29mw-*"])
  assertEq(full.ignorePackages[0].raw, "pkg:npm/axios@<0.21.1")
  assertEq(full.ignorePaths, @["test/*"])
  assertEq(full.message, "Upgrade vulnerable dependencies")
  assertEq(full.events, @["pull_request", "merge_group"])
  assertEq(full.snapshotWaitSeconds, 30)

  # sast enables it with its own threshold and message
  let s = load("""{"mode": "enforce", "sast": {"enabled": true, "min_severity": "info",
                                                "message": "see appsec"}}""").get()
  assertEq(s.source, "sast")
  assertEq(s.minSeverity, "low")
  assertEq(s.message, "see appsec")
  assertEq(s.scopes, @["runtime"])
  doAssert s.contextOnly
  doAssert load("""{"sast": {"enabled": true, "dependency_review": false}}""").isNone()
  doAssert load("""{"sast": {"enabled": false}}""").isNone()
  # vulnerabilities wins, including turning the review off
  assertEq(load("""{"sast": {"enabled": true, "min_severity": "low"},
                    "vulnerabilities": {"enabled": true, "min_severity": "critical"}}""").get().minSeverity,
           "critical")
  doAssert load("""{"sast": {"enabled": true},
                    "vulnerabilities": {"enabled": true, "dependency_review": {"enabled": false}}}""").isNone()

proc testCheck() =
  let review = reviewed()
  # added runtime dependencies at or above high, one per package and advisory
  var findings = defaults().check(review)
  assertEq(findings.subjects(), @[pyyaml, "pkg:npm/axios@0.21.0", lodash])
  assertEq(findings[0].severity, "critical")
  assertEq(findings[0].location, "services/api/requirements.txt")
  assertEq(findings[0].rule, "dependency_review")
  assertEq(findings[0].kind, "violation")
  assertEq(findings[2].reason,
           "high GHSA-35jh-r3h4-6jhm: Command Injection in lodash " &
           "(https://github.com/advisories/GHSA-35jh-r3h4-6jhm); also added in " &
           "services/web/package-lock.json")
  assertEq(findings[2].location, "services/api/package-lock.json")

  var settings = defaults()
  settings.minSeverity = "medium"
  settings.scopes = @["runtime", "development"]
  findings = settings.check(review)
  # the removed lodash 4.17.19 never counts
  assertEq(len(findings), 5)
  assertEq(findings[0].subject, "pkg:npm/minimist@1.2.5")
  assertEq(findings[^1].severity, "medium")
  doAssert "GHSA-29mw-wpgm-hmr9" in findings[^1].reason

  settings.ignoreAdvisories = @["GHSA-29mw-*", "GHSA-xvch-5gv4-984h"]
  settings.ignorePaths = @["test/*"]
  settings.ignorePackages = @[parsePurlPattern("pkg:pypi/pyyaml@<5.4")]
  settings.message = "Upgrade it"
  findings = settings.check(review)
  assertEq(findings.subjects(), @[lodash])
  doAssert findings[0].reason.endsWith(". Upgrade it"), findings[0].reason

  # a rating chalk does not know always counts rather than silently passing
  let added = DependencyChange(changeType: "added", scope: "runtime")
  for severity in ["ultra", ""]:
    doAssert defaults().counts(added, DependencyVulnerability(severity: severity,
                                                              ghsaId: "GHSA-new"))

  settings = defaults()
  settings.maxFindings = 3
  assertEq(len(settings.check(review)), 0)
  settings.maxFindings = 2
  assertEq(len(settings.check(review)), 3)

  # bounded
  var many = DependencyReview(status: rsReviewed)
  for i in 0 ..< 150:
    many.changes.add(DependencyChange(changeType: "added", manifest: "package.json",
                                      ecosystem: "npm", name: "p" & $i, version: "1.0.0",
                                      scope: "runtime",
                                      vulnerabilities: @[DependencyVulnerability(
                                        severity: "critical", ghsaId: "GHSA-" & $i)]))
  findings = defaults().check(many)
  assertEq(len(findings), 101)
  assertEq(findings[0].subject, "npm/p0@1.0.0")
  assertEq(findings[^1].reason, "50 more vulnerable dependencies not listed")
  assertEq(findings[^1].kind, "violation")

proc testContexts() =
  let review = reviewed()
  var findings = defaults().check(review, some(@[ReviewContext(path: "services/api")]))
  assertEq(findings.subjects(), @[pyyaml, lodash])
  # lodash is also added in services/web, outside the build context
  doAssert "also added" notin findings[1].reason
  findings = defaults().check(review, some(@[ReviewContext(path: "services/web")]))
  assertEq(findings.subjects(), @[lodash])
  # docker does not send ignored files
  let ignore = parseDockerignore("services/api/*.txt\ntest\n")
  findings = defaults().check(review, some(@[ReviewContext(path: "", ignore: ignore)]))
  assertEq(findings.subjects(), @[lodash])

  let dir = createTempDir("chalk-review-context-", "")
  writeFile(dir / ".dockerignore", "requirements.txt\n")
  var input = PolicyInput(command: "build", contextDirs: @[dir, "/elsewhere"])
  doAssert input.reviewContexts(refs()).isNone()
  input.repoPath = proc(d: string): Option[string] =
    if d == dir: some("services/api") else: none(string)
  let contexts = input.reviewContexts(refs()).get()
  assertEq(len(contexts), 1)
  assertEq(contexts[0].path, "services/api")
  assertEq(defaults().check(review, some(contexts)).subjects(), @[lodash])
  # no context in the repository reviews every manifest
  input.repoPath = proc(d: string): Option[string] = none(string)
  doAssert input.reviewContexts(refs()).isNone()
  removeDir(dir)

proc mark(review: JsonNode): ChalkDict =
  result = ChalkDict()
  result["CHALK_ID"] = pack("ABC")
  if review != nil:
    result["DEPENDENCY_REVIEW"] = pack(newTable({"repo": review{"repo"}.getStr(),
                                                 "base": review{"base"}.getStr(),
                                                 "head": review{"head"}.getStr(),
                                                 "result": review{"result"}.getStr()}))

proc testCheckReview() =
  clearEnv()
  reset()
  doAssert defaults().checkReview(PolicyInput(command: "build")).len == 0
  assertEq(len(calls), 0)
  doAssert dependencyReviewMark == nil

  github()
  responses = pages()
  var findings = defaults().checkReview(PolicyInput(command: "build"))
  assertEq(findings.subjects(), @[pyyaml, "pkg:npm/axios@0.21.0", lodash])
  assertEq(dependencyReviewMark["result"], "reviewed")
  assertEq(dependencyReviewMark["repo"], "acme/app")
  assertEq(dependencyReviewMark["base"], base)
  assertEq(dependencyReviewMark["head"], head)
  assertEq(dependencyReviewMark["event"], "pull_request")
  assertEq(len(takePolicyNotices()), 0)

  # unavailable is a notice, never a finding
  github()
  responses = @[respond(403, """{"message": "Forbidden"}""")]
  findings = defaults().checkReview(PolicyInput(command: "build"))
  assertEq(len(findings), 0)
  let notices = takePolicyNotices()
  assertEq(len(notices), 1)
  assertEq(notices[0].rule, "dependency_review")
  doAssert notices[0].message.startsWith("Dependency review of acme/app is unavailable, so " &
                                         "policy.vulnerabilities cannot check the dependencies " &
                                         "this pull request adds"), notices[0].message
  assertEq(dependencyReviewMark["result"], "unavailable")

  github()
  responses = @[respond(404, """{"message": "Not Found"}""")]
  findings = defaults().checkReview(PolicyInput(command: "build"))
  assertEq(len(findings), 1)
  assertEq(findings[0].kind, "error")
  doAssert findings[0].reason.startsWith("dependency review failed: "), findings[0].reason

  github(payload = %*{"pull_request": {}})
  findings = defaults().checkReview(PolicyInput(command: "build"))
  assertEq(findings[0].kind, "error")
  doAssert "could not determine the commits to review" in findings[0].reason

  # push skips images whose build reviewed the same commits
  let same = %*{"repo": "ACME/app", "base": base, "head": head, "result": "reviewed"}
  github()
  var push = PolicyInput(command: "push", pushTargets: @["app:1"], pushMarks: @[mark(same)])
  assertEq(len(defaults().checkReview(push)), 0)
  assertEq(len(calls), 0)
  doAssert dependencyReviewMark == nil
  for other in [%*{"repo": "acme/app", "base": base, "head": "3333", "result": "reviewed"},
                %*{"repo": "acme/app", "base": base, "head": head, "result": "unavailable"},
                %*{"repo": "acme/app", "base": base, "head": head, "result": "incomplete"},
                %*{"repo": "acme/app", "base": base, "head": head, "result": "failed"},
                nil]:
    github()
    responses = pages()
    push.pushMarks = @[mark(other)]
    assertEq(len(defaults().checkReview(push)), 3)
    assertEq(len(calls), 2)
  # unchalked: no mark, or fewer marks than pushed tags
  for (targets, marks) in [(@["app:1"], newSeq[ChalkDict]()),
                           (@["app:1", "app:2"], @[mark(same)])]:
    github()
    responses = pages()
    push = PolicyInput(command: "push", pushTargets: targets, pushMarks: marks)
    # push reviews the whole repository
    assertEq(len(defaults().checkReview(push)), 3)
    doAssert dependencyReviewMark == nil
  clearEnv()

proc testPushRetriesIncompleteBuild() =
  github()
  let temp = createTempDir("chalk-partial-build-", "")
  putEnv("RUNNER_TEMP", temp)
  responses = @[respond(200, "[]", {
    "x-github-dependency-graph-snapshot-warnings": "UGVuZGluZyBzbmFwc2hvdA=="})]
  assertEq(defaults().checkReview(PolicyInput(command: "build")).len, 0)
  assertEq(dependencyReviewMark["result"], "incomplete")
  let built = ChalkDict()
  built[markKey] = pack(dependencyReviewMark)
  reset() # a separate chalk push after the snapshots are complete
  responses = pages()
  let push = PolicyInput(command: "push", pushTargets: @["app:1"], pushMarks: @[built])
  assertEq(defaults().checkReview(push).len, 3)
  assertEq(len(calls), 2)
  removeDir(temp)
  clearEnv()

proc testPushRetriesUnavailableBuild() =
  github(token = "")
  let temp = createTempDir("chalk-unavailable-build-", "")
  putEnv("RUNNER_TEMP", temp)
  assertEq(defaults().checkReview(PolicyInput(command: "build")).len, 0)
  assertEq(dependencyReviewMark["result"], "unavailable")
  let built = ChalkDict()
  built[markKey] = pack(dependencyReviewMark)
  reset()
  putEnv("GITHUB_TOKEN", "working-token")
  responses = pages()
  let push = PolicyInput(command: "push", pushTargets: @["app:1"], pushMarks: @[built])
  assertEq(defaults().checkReview(push).len, 3)
  assertEq(len(calls), 2)
  removeDir(temp)
  clearEnv()

proc testEngine() =
  # notices reach the policy result and the step summary, once per message
  let rule = PolicyRule(name: "dependency_review",
                        load: proc(): bool = true,
                        checkInput: proc(input: PolicyInput): seq[PolicyFinding] =
                          addPolicyNotice("dependency_review", "Dependency review is unavailable"))
  let a = evaluatePolicy(PolicyConfig(id: "a", mode: "enforce"), @[rule], PolicyInput())
  let b = evaluatePolicy(PolicyConfig(id: "b", mode: "audit"), @[rule], PolicyInput())
  assertEq(a.result, "pass")
  assertEq(len(a.notices), 1)
  assertEq(a.notices[0].message, "Dependency review is unavailable")
  let build = ChalkDict()
  build["command"] = pack("build")
  let md = renderPolicySummary(@[a, b], build)
  assertEq(md.count("Dependency review is unavailable."), 1)
  doAssert "> [!WARNING]\n> Dependency review is unavailable." in md, md

proc testUsesContext() =
  loadDependencyReviewRule()
  var found = false
  for rule in policyRules():
    if rule.name == "dependency_review":
      found = true
      doAssert rule.usesContext
      doAssert not rule.requiresContext
      doAssert rule.checkInput != nil
  doAssert found

proc testContextFallback() =
  var rules: seq[PolicyRule]
  for rule in policyRules():
    if rule.name == "dependency_review":
      rules.add(rule)
  let build = ChalkDict()
  build["command"] = pack("build")
  let collect = proc(): PolicyInput = PolicyInput(command: "build")
  var contexts = 0
  let collectContext = proc(input: var PolicyInput) =
    inc(contexts)
    # Even a partially known context must fall back to the full repository.
    input.contextDirs = @["/known"]
    input.repoPath = proc(dir: string): Option[string] = some("services/web")
    input.contextErrors.add(newSubjectFinding("", "error", "-", "stdin context"))
  setPolicyJson("""{"mode":"enforce","on_error":"block",
                    "vulnerabilities":{"enabled":true}}""")
  # Ineligible events do not collect contexts or acquire context errors.
  for event in ["local", "push"]:
    github(event)
    if event == "local":
      delEnv("GITHUB_ACTIONS")
    policyOutcome = nil
    evaluatePolicies(build, collect, rules, collectContext = collectContext)
    doAssert policyOutcome.result == "pass" and policyOutcome.findings.len == 0
    assertEq(contexts, 0)
    assertEq(len(calls), 0)
  # Unavailable review is a notice, even when context collection fails.
  for token in ["", "restricted-token"]:
    github(token = token)
    responses = @[respond(403)]
    policyOutcome = nil
    evaluatePolicies(build, collect, rules, collectContext = collectContext)
    doAssert policyOutcome.result == "pass" and policyOutcome.findings.len == 0
    assertEq(takePolicyNotices().len, 0) # consumed by the engine
  # With an available review, uncertain contexts broaden the check and
  # still block real vulnerabilities, rather than creating context errors.
  github()
  responses = pages()
  policyOutcome = nil
  doAssertRaises(PolicyViolation):
    evaluatePolicies(build, collect, rules, collectContext = collectContext)
  assertEq(policyOutcome.findings.len, 3)
  for finding in policyOutcome.findings:
    assertEq(finding.kind, "violation")
  doAssert contexts > 0
  setPolicyJson("")
  clearEnv()

testNextLink()
testEventRefs()
testReviewRefs()
testParse()
testCompare()
testSnapshotWarnings()
testCache()
testIncompleteCache()
testCacheCredentials()
testConfig()
testCheck()
testContexts()
testCheckReview()
testPushRetriesIncompleteBuild()
testPushRetriesUnavailableBuild()
testEngine()
testUsesContext()
testContextFallback()
