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
  # `[...]` is not a glob: it matches literally and resolveMode warns
  doAssert not @[("glob", "github.com/acme/app[12]")].matchesRepo("github.com/acme/app1")
  doAssert "github.com/acme/app[12]".hasCharClass()
  doAssert not "https://[::1]/acme/app".hasCharClass()
  doAssert not "github.com/acme/*".hasCharClass()
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
  for mode in ["audit", "enforce"]:
    let p = PolicyConfig(id: "p", mode: mode, onError: "allow", targetRepos: repos,
                         onUnknownRepo: "skip")
    let listed = p.resolveMode("github.com/crashappsec/dummy-deployments")
    doAssert listed.activeMode() == mode and listed.isEvaluated()
    doAssert listed.repo == "github.com/crashappsec/dummy-deployments"
    let other = p.resolveMode("github.com/crashappsec/chalk")
    doAssert not other.isEvaluated()
    # an unknown repository is skipped by default
    let unknown = p.resolveMode("")
    doAssert not unknown.isEvaluated() and unknown.repo == ""
    var apply = p
    apply.onUnknownRepo = "apply"
    doAssert apply.resolveMode("").activeMode() == mode
    doAssert not apply.resolveMode("github.com/crashappsec/chalk").isEvaluated()
  # mode off is off everywhere
  let off = PolicyConfig(mode: "off", targetRepos: repos, onUnknownRepo: "apply")
  doAssert not off.isEvaluated()
  doAssert not off.resolveMode("github.com/crashappsec/dummy-deployments").isEvaluated()
  doAssert not off.resolveMode("").isEvaluated()
  # without target_repos the repository does not matter
  for repo in ["github.com/crashappsec/dummy-deployments", ""]:
    let plain = PolicyConfig(mode: "audit").resolveMode(repo)
    doAssert plain.activeMode() == "audit"
  # an invalid policy keeps its valid target_repos, so its configuration
  # error is only reported where the policy applies
  let invalid = PolicyConfig(mode: "enforce", configError: "broken", targetRepos: repos)
  doAssert invalid.resolveMode("github.com/crashappsec/dummy-deployments").activeMode() == "enforce"
  doAssert not invalid.resolveMode("github.com/crashappsec/chalk").isEvaluated()

proc testJsonValidation() =
  for doc in ["""{"target_repos": {}}""",
              """{"target_repos": ["github.com/a/b"]}""",
              """{"target_repos": [["glob"]]}""",
              """{"target_repos": [["glob", 1]]}"""]:
    let configs = parsePolicyJson(doc)
    doAssert "policy.target_repos" in configs[0].configError, configs[0].configError
    doAssert configs[0].targetRepos.len == 0
  let policies = parsePolicyJson("""{"policies": [
    {"id": "a", "mode": "audit", "target_repos": "github.com/a/b"},
    {"id": "b", "mode": "audit", "target_repos": [["glob", "github.com/a/*"]]},
    {"id": "c", "mode": "audit", "on_unknown_repo": "apply"},
    {"id": "d", "mode": "audit"}
  ]}""")
  doAssert "policy.policies[0].target_repos" in policies[0].configError
  doAssert policies[0].mode == "audit" and policies[0].targetRepos.len == 0
  doAssert policies[1].configError == ""
  doAssert policies[1].targetRepos == @[("glob", "github.com/a/*")]
  doAssert policies[2].configError == "" and policies[2].onUnknownRepo == "apply"
  doAssert policies[3].onUnknownRepo == "skip"
  for value in ["\"block\"", "\"Skip\"", "true"]:
    let configs = parsePolicyJson("""{"mode": "enforce", "on_unknown_repo": """ & value & "}")
    doAssert "policy.on_unknown_repo" in configs[0].configError, configs[0].configError
    doAssert configs[0].onUnknownRepo == "skip"

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
  ## the string fields of the first `_POLICY_RESULTS` entry
  result = newTable[string, string]()
  let dict = policyOutcome.asChalkDict()
  for k, v in unpack[seq[ChalkDict]](dict["_POLICY_RESULTS"])[0]:
    if v.kind == MkStr:
      result[k] = unpack[string](v)

const
  single = """{"id": "golden@1", "mode": "enforce",
    "target_repos": [["glob", "github.com/crashappsec/dummy-deployments"]],
    "golden_images": {"enabled": true, "allowed": [["glob", "alpine:*"]]}}"""
  listed = "github.com/crashappsec/dummy-deployments"

proc testAppliesInListedRepo() =
  for mode in ["enforce", "audit"]:
    let doc = single.replace("\"enforce\"", "\"" & mode & "\"")
    var (blocked, resolved) = evaluate(doc, listed)
    doAssert blocked == (mode == "enforce") and resolved == 1
    doAssert policyOutcome.mode == mode
    doAssert policyOutcome.result == (if mode == "enforce": "blocked" else: "violation")
    var r = firstResult()
    doAssert r["mode"] == mode and r["effective_mode"] == mode
    doAssert r["repo"] == listed and "mode_source" notin r
    doAssert policyOutcome.policies[0].rules == @["golden_images"]

    # not evaluated, so nothing is reported
    (blocked, resolved) = evaluate(doc, "github.com/crashappsec/chalk")
    doAssert not blocked and resolved == 1 and policyOutcome == nil

proc testUnknownRepo() =
  # skipped by default
  var (blocked, resolved) = evaluate(single, "")
  doAssert not blocked and resolved == 1 and policyOutcome == nil
  (blocked, resolved) = evaluate(single.replace("\"mode\"", "\"on_unknown_repo\": \"skip\", \"mode\""), "")
  doAssert not blocked and policyOutcome == nil
  # applied in mode
  (blocked, resolved) = evaluate(single.replace("\"mode\"", "\"on_unknown_repo\": \"apply\", \"mode\""), "")
  doAssert blocked and resolved == 1
  let r = firstResult()
  doAssert r["effective_mode"] == "enforce" and r["repo"] == ""

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
  doAssert not blocked and policyOutcome == nil

proc testOnlyTargetedPolicyIsScoped() =
  let doc = """{"policies": [
    {"id": "rollout@1", "mode": "enforce",
     "target_repos": [["glob", "github.com/crashappsec/dummy-*"]],
     "golden_images": {"enabled": true, "allowed": [["glob", "alpine:*"]]}},
    {"id": "audit@1", "mode": "audit",
     "golden_images": {"enabled": true, "allowed": [["glob", "alpine:*"]]}}
  ]}"""
  var (blocked, resolved) = evaluate(doc, listed)
  doAssert blocked and resolved == 1
  doAssert policyOutcome.policies.len == 2
  doAssert policyOutcome.policies[0].result == "blocked"
  # the policy without target_repos is unaffected
  doAssert policyOutcome.policies[1].effectiveMode == "audit"
  doAssert policyOutcome.policies[1].repo == ""

  (blocked, resolved) = evaluate(doc, "github.com/crashappsec/chalk")
  doAssert not blocked
  doAssert policyOutcome.policies.len == 1
  doAssert policyOutcome.policies[0].id == "audit@1"

proc testOffWithTargetReposIsOff() =
  let doc = """{"id": "rollout@1", "mode": "off", "on_unknown_repo": "apply",
    "target_repos": [["glob", "github.com/crashappsec/dummy-*"]],
    "golden_images": {"enabled": true}}"""
  setPolicyJson(doc)
  doAssert not policyEnabled()
  for repo in [listed, "github.com/crashappsec/chalk", ""]:
    let (blocked, resolved) = evaluate(doc, repo)
    doAssert not blocked and resolved == 0 and policyOutcome == nil

proc testRepoNotResolvedWithoutTargetRepos() =
  for doc in ["""{"mode": "audit", "golden_images": {"enabled": true}}""",
              """{"mode": "audit", "target_repos": [], "golden_images": {"enabled": true}}"""]:
    let (blocked, resolved) = evaluate(doc, listed)
    doAssert not blocked and resolved == 0
    let r = firstResult()
    doAssert r["effective_mode"] == "audit" and r["repo"] == ""

proc testInvalidTargetRepos() =
  # the policy is invalid and only reports, with its declared mode and
  # on_error, in every repository
  let doc = """{"mode": "enforce", "on_error": "block",
    "target_repos": [["glob"]], "golden_images": {"enabled": true}}"""
  var (blocked, resolved) = evaluate(doc, listed)
  doAssert blocked and resolved == 0
  doAssert policyOutcome.result == "blocked"
  doAssert policyOutcome.findings.len == 1
  doAssert policyOutcome.findings[0].rule == "config"
  doAssert "policy.target_repos" in policyOutcome.findings[0].reason
  (blocked, resolved) = evaluate(doc.replace("\"enforce\"", "\"audit\""), listed)
  doAssert not blocked and resolved == 0
  doAssert policyOutcome.result == "error"

proc testInvalidOnUnknownRepo() =
  # an invalid on_unknown_repo makes the policy invalid; its valid
  # target_repos still scopes the configuration error
  let doc = """{"mode": "enforce", "on_error": "block", "on_unknown_repo": "always",
    "target_repos": [["glob", "github.com/crashappsec/dummy-*"]],
    "golden_images": {"enabled": true, "allowed": [["glob", "alpine:*"]]}}"""
  var (blocked, resolved) = evaluate(doc, listed)
  doAssert blocked and resolved == 1
  doAssert policyOutcome.findings.len == 1
  doAssert policyOutcome.findings[0].rule == "config"
  doAssert "policy.on_unknown_repo" in policyOutcome.findings[0].reason
  (blocked, resolved) = evaluate(doc, "github.com/crashappsec/chalk")
  doAssert not blocked and policyOutcome == nil
  (blocked, resolved) = evaluate(doc, "")
  doAssert not blocked and policyOutcome == nil

testNormalizeRepo()
testRepoFromEnv()
testMatchesRepo()
testMatchesRepoKeepsGlobs()
testLocalOriginFallsBackToCiRepo()
testResolveMode()
testJsonValidation()
testAppliesInListedRepo()
testUnknownRepo()
testResolverFailureIsUnknownRepo()
testOnlyTargetedPolicyIsScoped()
testOffWithTargetReposIsOff()
testRepoNotResolvedWithoutTargetRepos()
testInvalidTargetRepos()
testInvalidOnUnknownRepo()
