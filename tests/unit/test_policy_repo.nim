import std/[os, strutils, tables]
import ../../src/types
import ../../src/policy/engine
import ../../src/policy/rules
import ../../src/docker/ids

proc testNormalizeRepo() =
  for url in [
    "git@github.com:crashappsec/chalk.git",
    "git@github.com:crashappsec/chalk",
    "ssh://git@github.com/crashappsec/chalk.git",
    "ssh://git@github.com:22/crashappsec/chalk.git",
    "git+ssh://git@github.com/crashappsec/chalk.git",
    "https://github.com/crashappsec/chalk",
    "https://github.com/crashappsec/chalk.git",
    "https://github.com/crashappsec/chalk.git/",
    "https://x-access-token:s3cr@t@github.com/crashappsec/chalk.git",
    "https://github.com:443/CrashAppSec/Chalk.git",
    "HTTPS://GitHub.com/crashappsec/chalk",
    "git://github.com/crashappsec/chalk.git",
    # docker git context with ref and subdirectory
    "https://github.com/crashappsec/chalk.git#main:docker",
    "git@github.com:crashappsec/chalk.git#v1",
    # a query is not part of a remote's identity
    "https://github.com/crashappsec/chalk.git?ref=main",
    "https://github.com/crashappsec/chalk?x=1#main",
  ]:
    doAssert normalizeRepo(url) == "github.com/crashappsec/chalk", url & " -> " & normalizeRepo(url)
  doAssert normalizeRepo("https://gitlab.com/group/sub/project.git") == "gitlab.com/group/sub/project"
  doAssert normalizeRepo("git@gitlab.example.com:group/sub/project.git") == "gitlab.example.com/group/sub/project"
  # not a remote repository
  for url in ["", "local", "/srv/git/repo.git", "./repo", "../repo", "~/repo",
              "file:///srv/git/repo.git", "https://github.com/", "https://github.com/org",
              "github.com", "git@github.com:repo.git", "s3://bucket/a/b",
              # relative paths are local to git, whatever they look like
              "mirrors/acme/app.git", "mirrors/acme/app", "github.com/crashappsec/chalk"]:
    doAssert normalizeRepo(url) == "", url & " -> " & normalizeRepo(url)

proc withEnv(vars: openArray[(string, string)], body: proc()) =
  const names = ["GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "CI_PROJECT_URL"]
  for name in names:
    delEnv(name)
  for (k, v) in vars:
    putEnv(k, v)
  try:
    body()
  finally:
    for name in names:
      delEnv(name)

proc testRepoFromEnv() =
  withEnv([], proc() = doAssert repoFromEnv() == "")
  withEnv([("GITHUB_REPOSITORY", "Acme/App")], proc() =
    doAssert repoFromEnv() == "github.com/acme/app")
  withEnv([("GITHUB_SERVER_URL", "https://ghe.example.com/"), ("GITHUB_REPOSITORY", "acme/app")], proc() =
    doAssert repoFromEnv() == "ghe.example.com/acme/app")
  withEnv([("CI_PROJECT_URL", "https://gitlab.com/acme/group/app")], proc() =
    doAssert repoFromEnv() == "gitlab.com/acme/group/app")
  # github takes precedence
  withEnv([("GITHUB_REPOSITORY", "acme/app"), ("CI_PROJECT_URL", "https://gitlab.com/acme/other")], proc() =
    doAssert repoFromEnv() == "github.com/acme/app")

proc testMatchesRepo() =
  let entries = @[("glob", "github.com/crashappsec/dummy-*"),
                  ("glob", "https://github.com/Acme/App.git"),
                  ("exact", "github.com/acme/other")]
  doAssert entries.matchesRepo("github.com/crashappsec/dummy-deployments")
  doAssert entries.matchesRepo("github.com/acme/app")
  doAssert not entries.matchesRepo("github.com/crashappsec/chalk")
  # only glob is supported, other kinds never match
  doAssert not entries.matchesRepo("github.com/acme/other")
  doAssert not entries.matchesRepo("")
  doAssert @[("glob", "*")].matchesRepo("gitlab.com/a/b")
  doAssert @[("glob", "github.com/*")].matchesRepo("github.com/a/b")

proc testLocalOriginFallsBackToCiRepo() =
  # a local origin is no repository, so the CI job's applies
  doAssert normalizeRepo("mirrors/acme/app.git") == ""
  doAssert normalizeRepoPattern("github.com/crashappsec/chalk") == "github.com/crashappsec/chalk"
  withEnv([("GITHUB_REPOSITORY", "acme/app")], proc() =
    var repo = normalizeRepo("mirrors/acme/app.git")
    if repo == "":
      repo = repoFromEnv()
    doAssert repo == "github.com/acme/app"
    doAssert @[("glob", "github.com/acme/app")].matchesRepo(repo))

proc testMatchesRepoKeepsGlobs() =
  doAssert normalizeRepoPattern("https://GitHub.com/Acme/App?.git") == "github.com/acme/app?"
  doAssert normalizeRepoPattern("git@github.com:acme/[ab]pp.git") == "github.com/acme/[ab]pp"
  doAssert normalizeRepoPattern("github.com/acme/app#main") == "github.com/acme/app"
  # only a numeric port is removed, see normalizeRepoPattern
  doAssert normalizeRepoPattern("https://github.com:443/acme/*") == "github.com/acme/*"
  doAssert normalizeRepoPattern("https://github.com:*/acme/app") == "github.com:*/acme/app"
  doAssert not @[("glob", "https://github.com:*/acme/app")].matchesRepo("github.com/acme/app")
  for pattern in ["github.com/acme/app?", "https://github.com/acme/app?",
                  "git@github.com:acme/app?.git", "HTTPS://github.com/Acme/App?.git"]:
    let entries = @[("glob", pattern)]
    doAssert entries.matchesRepo("github.com/acme/app1"), pattern
    doAssert not entries.matchesRepo("github.com/acme/app"), pattern
    doAssert not entries.matchesRepo("github.com/acme/app12"), pattern
  doAssert @[("glob", "https://github.com/acme/*.git")].matchesRepo("github.com/acme/app")
  doAssert @[("glob", "github.com/*/app")].matchesRepo("github.com/acme/app")

proc testResolveMode() =
  let repos = @[("glob", "github.com/crashappsec/dummy-deployments")]
  for mode in ["off", "audit", "enforce"]:
    let p = PolicyConfig(id: "p", mode: mode, onError: "allow", enforceRepos: repos)
    let listed = p.resolveMode("github.com/crashappsec/dummy-deployments")
    doAssert listed.activeMode() == "enforce" and listed.modeSource == "enforce_repos"
    doAssert listed.mode == mode and listed.isEvaluated()
    let other = p.resolveMode("github.com/crashappsec/chalk")
    doAssert other.activeMode() == mode and other.modeSource == "default"
    # an unknown repository never escalates
    let unknown = p.resolveMode("")
    doAssert unknown.activeMode() == mode and unknown.modeSource == "default"
    doAssert unknown.repo == ""
    doAssert p.mayBeEvaluated()
  doAssert not PolicyConfig(mode: "off").mayBeEvaluated()
  # without enforce_repos the repository does not matter
  let plain = PolicyConfig(mode: "audit").resolveMode("github.com/crashappsec/dummy-deployments")
  doAssert plain.activeMode() == "audit" and plain.modeSource == "default"
  # an invalid policy only reports, whatever it asks for
  let invalid = PolicyConfig(mode: "audit", configError: "broken", enforceRepos: repos)
  doAssert invalid.resolveMode("github.com/crashappsec/dummy-deployments").activeMode() == "audit"

proc testJsonValidation() =
  for doc in ["""{"enforce_repos": {}}""",
              """{"enforce_repos": ["github.com/a/b"]}""",
              """{"enforce_repos": [["glob"]]}""",
              """{"enforce_repos": [["glob", 1]]}"""]:
    try:
      discard parsePolicyJson(doc)
      doAssert false, "accepted: " & doc
    except ValueError:
      doAssert "policy.enforce_repos" in getCurrentExceptionMsg(), getCurrentExceptionMsg()
  let policies = parsePolicyJson("""{"policies": [
    {"id": "a", "mode": "audit", "enforce_repos": "github.com/a/b"},
    {"id": "b", "mode": "audit", "enforce_repos": [["glob", "github.com/a/*"]]}
  ]}""")
  doAssert "policy.policies[0].enforce_repos" in policies[0].configError
  doAssert policies[0].mode == "audit" and policies[0].enforceRepos.len == 0
  doAssert policies[1].configError == ""
  doAssert policies[1].enforceRepos == @[("glob", "github.com/a/*")]

proc build(): ChalkDict =
  result = ChalkDict()
  result["command"] = pack("build")

proc goldenImagesRule(): PolicyRule =
  loadPolicyRules()
  for rule in policyRules():
    if rule.name == "golden_images":
      return rule
  doAssert false, "golden_images is not registered"

proc evaluate(doc, repo: string, image = "busybox"): tuple[blocked: bool, resolved: int] =
  setPolicyJson(doc)
  policyOutcome = nil
  var resolved = 0
  let
    collect = proc(): PolicyInput =
      PolicyInput(subjects: @[PolicySubject(image: parseImage(image), raw: image, source: "from")])
    resolver = proc(): string =
      inc(resolved)
      repo
  try:
    evaluatePolicies(build(), collect, @[goldenImagesRule()], resolver)
  except PolicyViolation:
    result.blocked = true
  result.resolved = resolved

proc firstResult(): TableRef[string, string] =
  let dict = policyOutcome.asChalkDict()
  unpack[seq[TableRef[string, string]]](dict["_POLICY_RESULTS"])[0]

const
  single = """{"id": "golden@1", "mode": "audit",
    "enforce_repos": [["glob", "github.com/crashappsec/dummy-deployments"]],
    "golden_images": {"enabled": true, "allowed": [["glob", "alpine:*"]]}}"""
  listed = "github.com/crashappsec/dummy-deployments"

proc testEnforcedInListedRepo() =
  var (blocked, resolved) = evaluate(single, listed)
  doAssert blocked and resolved == 1
  doAssert policyOutcome.mode == "enforce" and policyOutcome.result == "blocked"
  var r = firstResult()
  doAssert r["mode"] == "audit" and r["effective_mode"] == "enforce"
  doAssert r["mode_source"] == "enforce_repos" and r["repo"] == listed
  doAssert r["result"] == "blocked"

  (blocked, resolved) = evaluate(single, "github.com/crashappsec/chalk")
  doAssert not blocked
  doAssert policyOutcome.mode == "audit" and policyOutcome.result == "violation"
  r = firstResult()
  doAssert r["effective_mode"] == "audit" and r["mode_source"] == "default"
  doAssert r["repo"] == "github.com/crashappsec/chalk"

  (blocked, resolved) = evaluate(single, "")
  doAssert not blocked
  r = firstResult()
  doAssert r["effective_mode"] == "audit" and r["mode_source"] == "default" and r["repo"] == ""

proc testResolverFailureIsUnknownRepo() =
  setPolicyJson(single)
  policyOutcome = nil
  var blocked = false
  try:
    evaluatePolicies(build(),
                     proc(): PolicyInput =
                       PolicyInput(subjects: @[PolicySubject(image: parseImage("busybox"),
                                                             raw: "busybox", source: "from")]),
                     @[goldenImagesRule()],
                     proc(): string = raise newException(ValueError, "boom"))
  except PolicyViolation:
    blocked = true
  doAssert not blocked
  doAssert firstResult()["mode_source"] == "default"

proc testOffEnforcesOnlyListedRepos() =
  let doc = """{"policies": [
    {"id": "rollout@1", "mode": "off",
     "enforce_repos": [["glob", "github.com/crashappsec/dummy-*"]],
     "golden_images": {"enabled": true, "allowed": [["glob", "alpine:*"]]}},
    {"id": "audit@1", "mode": "audit",
     "golden_images": {"enabled": true, "allowed": [["glob", "alpine:*"]]}}
  ]}"""
  var (blocked, resolved) = evaluate(doc, listed)
  doAssert blocked and resolved == 1
  doAssert policyOutcome.policies.len == 2
  doAssert policyOutcome.policies[0].mode == "off"
  doAssert policyOutcome.policies[0].effectiveMode == "enforce"
  doAssert policyOutcome.policies[0].result == "blocked"
  # the policy without enforce_repos is unaffected
  doAssert policyOutcome.policies[1].effectiveMode == "audit"
  doAssert policyOutcome.policies[1].modeSource == "default"
  doAssert policyOutcome.policies[1].repo == ""

  (blocked, resolved) = evaluate(doc, "github.com/crashappsec/chalk")
  doAssert not blocked
  doAssert policyOutcome.policies.len == 1
  doAssert policyOutcome.policies[0].id == "audit@1"

  # off everywhere else: nothing evaluated, nothing reported
  let offOnly = """{"id": "rollout@1", "mode": "off",
    "enforce_repos": [["glob", "github.com/crashappsec/dummy-*"]],
    "golden_images": {"enabled": true}}"""
  setPolicyJson(offOnly)
  doAssert policyEnabled()
  (blocked, resolved) = evaluate(offOnly, "github.com/crashappsec/chalk")
  doAssert not blocked and resolved == 1 and policyOutcome == nil
  (blocked, resolved) = evaluate(offOnly, "")
  doAssert not blocked and policyOutcome == nil

proc testRepoNotResolvedWithoutEnforceRepos() =
  let doc = """{"mode": "audit", "golden_images": {"enabled": true}}"""
  let (blocked, resolved) = evaluate(doc, listed)
  doAssert not blocked and resolved == 0
  let r = firstResult()
  doAssert r["effective_mode"] == "audit" and r["mode_source"] == "default" and r["repo"] == ""

proc testInvalidEnforceReposNeverBlocks() =
  let doc = """{"mode": "enforce", "on_error": "block",
    "enforce_repos": [["glob"]], "golden_images": {"enabled": true}}"""
  let (blocked, resolved) = evaluate(doc, listed)
  doAssert not blocked and resolved == 0
  doAssert policyOutcome.result == "error"
  doAssert policyOutcome.findings[0].rule == "config"
  doAssert "policy.enforce_repos" in policyOutcome.findings[0].reason

testNormalizeRepo()
testRepoFromEnv()
testMatchesRepo()
testMatchesRepoKeepsGlobs()
testLocalOriginFallsBackToCiRepo()
testResolveMode()
testJsonValidation()
testEnforcedInListedRepo()
testResolverFailureIsUnknownRepo()
testOffEnforcesOnlyListedRepos()
testRepoNotResolvedWithoutEnforceRepos()
testInvalidEnforceReposNeverBlocks()
