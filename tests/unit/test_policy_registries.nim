import std/[os, sequtils, strutils, tables]
import ../../src/types
import ../../src/docker/ids
import ../../src/docker/util
import ../../src/docker/policy_subjects
import ../../src/policy/engine
import ../../src/policy/rules
import ../../src/policy/rules/golden_images
import ../../src/policy/rules/registries

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

const
  fixture = currentSourcePath().parentDir() / "fixtures" / "policy_config_registries.json"
  digest  = "bb99ae95b8ce6a10d397d0b8998cfe12ac055baabd917be9e00cd095991b8630"

proc decide(image: string, allowed: seq[RegistryEntry],
            denied: seq[RegistryEntry] = @[]): MatchResult =
  parseImage(image, defaultTag = "").checkRegistry(allowed, denied, "pull").result

proc subject(image: string, source = "from", stage = ""): PolicySubject =
  let parsed = parseImage(image, defaultTag = "")
  PolicySubject(image: parsed, raw: image, source: source, stage: stage)

proc testPatterns() =
  assertEq(normalizeRegistryPattern("docker.io"), "registry-1.docker.io")
  assertEq(normalizeRegistryPattern("index.docker.io"), "registry-1.docker.io")
  assertEq(normalizeRegistryPattern("GHCR.io"), "ghcr.io")
  assertEq(normalizeRegistryPattern("localhost:5000"), "localhost:5000")
  assertEq(normalizeRegistryPattern("*.dkr.ecr.*.amazonaws.com"), "*.dkr.ecr.*.amazonaws.com")
  assertEq(normalizeRegistryPattern("ghcr.io/acme/*"), "ghcr.io/acme/*")
  assertEq(normalizeRegistryPattern("docker.io/alpine"), "registry-1.docker.io/library/alpine")
  assertEq(normalizeRegistryPattern("docker.io/*"), "registry-1.docker.io/*")
  # Docker Hub namespaces, as docker resolves `acme/app`
  assertEq(normalizeRegistryPattern("acme/*"), "registry-1.docker.io/acme/*")
  assertEq(normalizeRegistryPattern("*/acme/*"), "*/acme/*")
  # tags and digests do not select registries
  assertEq(normalizeRegistryPattern("localhost:5000/app:1"), "localhost:5000/app")
  assertEq(normalizeRegistryPattern("ghcr.io/acme/app@sha256:" & digest), "ghcr.io/acme/app")
  assertEq(parseImage("alpine").registryRef(),
           ("registry-1.docker.io", "registry-1.docker.io/library/alpine"))
  assertEq(parseImage("Localhost:5000/App").registryRef().host, "localhost:5000")
  # case and the default HTTPS port do not change the registry
  assertEq(normalizeRegistryPattern("GHCR.io:443"), "ghcr.io")
  assertEq(normalizeRegistryPattern("ghcr.io:443/acme/*"), "ghcr.io/acme/*")
  assertEq(normalizeRegistryPattern("Docker.io:443/alpine"), "registry-1.docker.io/library/alpine")
  assertEq(normalizeRegistryPattern("*.example.com:443"), "*.example.com")
  for (image, repo) in [
    ("ghcr.io:443/acme/app", "ghcr.io/acme/app"),
    ("GHCR.IO/acme/app", "ghcr.io/acme/app"),
    ("Docker.io/library/alpine", "registry-1.docker.io/library/alpine"),
    ("Docker.io/alpine", "registry-1.docker.io/library/alpine"),
    ("docker.io:443/alpine", "registry-1.docker.io/library/alpine"),
    ("index.docker.io:443/acme/app", "registry-1.docker.io/acme/app"),
    ("registry-1.docker.io:443/library/alpine", "registry-1.docker.io/library/alpine"),
    ("localhost:5000/app", "localhost:5000/app"),
    ("ghcr.io:8443/acme/app", "ghcr.io:8443/acme/app"),
  ]:
    assertEq(parseImage(image, defaultTag = "").registryRef().repo, repo)

proc testMatching() =
  let hub: seq[RegistryEntry] = @[("glob", "docker.io")]
  for image in ["alpine", "alpine:3", "library/alpine", "acme/app", "docker.io/acme/app",
                "index.docker.io/library/alpine", "registry-1.docker.io/x/y",
                "alpine@sha256:" & digest]:
    assertEq(decide(image, hub), mrAllowed)
  for image in ["ghcr.io/acme/app", "localhost:5000/alpine", "docker.io.evil.com/alpine"]:
    assertEq(decide(image, hub), mrDenied)

  let official: seq[RegistryEntry] = @[("glob", "docker.io/library/*")]
  assertEq(decide("alpine", official), mrAllowed)
  assertEq(decide("acme/app", official), mrDenied)

  let namespace: seq[RegistryEntry] = @[("glob", "ghcr.io/acme/*")]
  assertEq(decide("ghcr.io/acme/app:1", namespace), mrAllowed)
  assertEq(decide("ghcr.io/acme/team/app", namespace), mrAllowed)
  assertEq(decide("ghcr.io/acmecorp/app", namespace), mrDenied)
  assertEq(decide("ghcr.io/acme", namespace), mrDenied)

  let ecr: seq[RegistryEntry] = @[("glob", "*.dkr.ecr.*.amazonaws.com")]
  assertEq(decide("123.dkr.ecr.us-east-1.amazonaws.com/app", ecr), mrAllowed)
  assertEq(decide("public.ecr.aws/app", ecr), mrDenied)

  # denylists cannot be bypassed by spelling the host differently
  let ghcr: seq[RegistryEntry] = @[("glob", "ghcr.io")]
  for image in ["ghcr.io:443/acme/app", "GHCR.io/acme/app", "Ghcr.IO:443/acme/app"]:
    assertEq(decide(image, @[], ghcr), mrDenied)
  for image in ["Docker.io/library/alpine", "registry-1.docker.io:443/library/alpine",
                "docker.io:443/alpine", "INDEX.docker.io/alpine"]:
    assertEq(decide(image, @[], hub), mrDenied)
    assertEq(decide(image, official), mrAllowed)
  assertEq(decide("ghcr.io:8443/acme/app", @[], ghcr), mrAllowed)

  let ports: seq[RegistryEntry] = @[("glob", "localhost:*")]
  assertEq(decide("localhost:5000/app", ports), mrAllowed)
  assertEq(decide("localhost/app", ports), mrDenied)

  # empty allowlist: everything not denied
  assertEq(decide("ghcr.io/acme/app", @[]), mrAllowed)
  # denied wins over allowed
  let denied: seq[RegistryEntry] = @[("glob", "ghcr.io/acme/untrusted/*")]
  assertEq(decide("ghcr.io/acme/untrusted/x", namespace, denied), mrDenied)
  assertEq(decide("ghcr.io/acme/app", namespace, denied), mrAllowed)
  let (_, reason) = parseImage("busybox").checkRegistry(@[], hub, "push")
  assertEq(reason, "docker.io/library/busybox is in a registry denied for push (docker.io)")

  # unknown kinds fail safe: in a denylist they could have denied the image
  let future: seq[RegistryEntry] = @[("signed_by", "acme")]
  assertEq(decide("alpine", hub, future), mrUnknown)
  assertEq(decide("alpine", future & hub), mrAllowed)
  assertEq(decide("ghcr.io/x", future & hub), mrUnknown)
  assertEq(decide("ghcr.io/x", hub, hub & future), mrUnknown)
  assertEq(decide("alpine", hub, hub & future), mrDenied)
  assertEq(decide("sha256:" & digest, hub), mrUnknown)

proc testCheck() =
  let settings = RegistriesConfig(
    pullAllowed: @[("glob", "docker.io/library/*")],
    pushAllowed: @[("glob", "ghcr.io/acme/*")],
    message:     "see wiki",
  )
  let input = PolicyInput(
    command:     "build",
    subjects:    @[subject("alpine"), subject("ghcr.io/x/tools", "copy_from", "build"),
                   subject("scratch")],
    pushTargets: @["ghcr.io/acme/app:1", "app:1"],
  )
  let findings = settings.check(input)
  assertEq(findings.len, 2)
  doAssert findings[0].image == "ghcr.io/x/tools" and findings[0].source == "copy_from"
  doAssert findings[0].stage == "build" and findings[0].kind == "violation"
  assertEq(findings[0].reason, "ghcr.io/x/tools is not in a registry allowed for pull. see wiki")
  doAssert findings[1].image == "app:1" and findings[1].source == "push"
  assertEq(findings[1].reason, "docker.io/library/app is not in a registry allowed for push. see wiki")
  doAssert findings[1].rule == "registries" and findings[1].subject == ""

  # push-only policies ignore pulled images
  let pushOnly = RegistriesConfig(pushDenied: @[("glob", "docker.io")])
  doAssert not pushOnly.checksPull() and pushOnly.checksPush()
  assertEq(pushOnly.check(input).len, 1)
  assertEq(pushOnly.check(PolicyInput(command: "build", subjects: input.subjects)).len, 0)
  # push targets could not be collected
  let failed = PolicyInput(errors: @[collectionError("could not list tags")])
  let errors = pushOnly.check(failed)
  doAssert errors.len == 1 and errors[0].kind == "error" and errors[0].rule == "registries"
  assertEq(pushOnly.check(PolicyInput())[0].reason, "could not determine push targets")
  # with pull checks the engine reports collection errors itself
  assertEq(settings.check(failed).len, 0)

proc testRequireDigest() =
  let settings = RegistriesConfig(requireDigest: true)
  doAssert settings.checksPull() and not settings.checksPush()
  let input = PolicyInput(command: "build", subjects: @[
    subject("alpine:3"),
    subject("alpine@sha256:" & digest),
    subject("ghcr.io/acme/tools:1@sha256:" & digest, "mount_from"),
  ])
  let findings = settings.check(input)
  assertEq(findings.len, 1)
  doAssert findings[0].image == "alpine:3" and findings[0].reason == "image is not pinned by digest"
  # a denied image is reported once, for its registry
  let both = RegistriesConfig(requireDigest: true, pullDenied: @[("glob", "docker.io")])
  assertEq(both.check(PolicyInput(subjects: @[subject("alpine")])).len, 1)

proc invocation(outputs: openArray[string], tags: seq[string] = @[],
                push = false, cacheFrom: seq[string] = @[],
                cacheTo: seq[string] = @[]): DockerInvocation =
  ## outputs as parsed by cmdline.nim, with fields separated by `;` so that
  ## names can contain the commas of a quoted CSV field
  result = DockerInvocation(cmd: DockerCmd.build, foundPush: push,
                            foundTags: parseImages(tags),
                            foundCacheFrom: cacheFrom, foundCacheTo: cacheTo,
                            foundBuildArgs: newTable[string, string](),
                            dfDirectives: newOrderedTable[string, string]())
  for spec in outputs:
    var kv = newOrderedTable[string, string]()
    for field in spec.split(";"):
      let parts = field.split("=", maxsplit = 1)
      kv[parts[0]] = parts[1]
    kv.normalizeExporterPush(push)
    if kv.getOrDefault("type") in ["image", "registry"] and kv.exporterBool("push"):
      result.foundPush = true
    result.foundOutputs.add(kv)

proc testBuildPushTargets() =
  assertEq(invocation([], @["app:1"]).buildPushTargets(), newSeq[string]())
  assertEq(invocation([], @["app:1", "ghcr.io/acme/app"], push = true).buildPushTargets(),
           @["app:1", "ghcr.io/acme/app:latest"])
  # buildx replaces exporter names with --tag
  assertEq(invocation(["type=registry;name=ghcr.io/x/y"], @["ghcr.io/acme/app:1"],
                      push = true).buildPushTargets(), @["ghcr.io/acme/app:1"])
  assertEq(invocation(["type=registry;name=ghcr.io/x/y,quay.io/x/y:2"],
                      push = true).buildPushTargets(), @["ghcr.io/x/y", "quay.io/x/y:2"])
  assertEq(invocation(["type=image;name=ghcr.io/x/y;push=true",
                       "type=image;name=local/only",
                       "type=local;dest=out"]).buildPushTargets(), @["ghcr.io/x/y"])
  assertEq(invocation(["type=image;name=ghcr.io/x/y;push-by-digest=true"],
                      push = true).buildPushTargets(), @["ghcr.io/x/y"])
  # --push overrides an explicit exporter push=false, including with no tags.
  let overridden = invocation(["type=image;name=denied.example/app;push=false"], push = true)
  assertEq(overridden.foundOutputs[0]["push"], "true")
  assertEq(overridden.buildPushTargets(), @["denied.example/app"])
  # A pushing exporter must not make a separate local exporter push.
  for outputs in [
    @["type=image;name=denied.example/local;push=false;push-by-digest=true",
      "type=registry;name=ghcr.io/acme/app"],
    @["type=registry;name=ghcr.io/acme/app",
      "type=image;name=denied.example/local;push=false;push-by-digest=true"],
  ]:
    assertEq(invocation(outputs).buildPushTargets(), @["ghcr.io/acme/app"])
  for value in ["", "1", "t", "T", "true", "TRUE", "True"]:
    let ctx = invocation(["type=image;name=ghcr.io/acme/app;push=true;push-by-digest=" & value])
    doAssert ctx.foundOutputs[0].exporterBool("push-by-digest")
  for value in ["", "1", "t", "T", "true", "TRUE", "True"]:
    let ctx = invocation(["type=image;name=denied.example/app;push=" & value])
    assertEq(ctx.buildPushTargets(), @["denied.example/app"])
    assertEq(invocation(["type=image;name=ignored.example/app;push=" & value],
      @["ghcr.io/acme/app:1"]).buildPushTargets(), @["ghcr.io/acme/app:1"])
  for value in ["0", "f", "F", "false", "FALSE", "False"]:
    assertEq(invocation(["type=image;name=denied.example/app;push=" & value])
      .buildPushTargets(), newSeq[string]())
  assertEq(invocation(["type=image;name=ghcr.io/acme/app:1;push=true;" &
    "dangling-name-prefix=denied.example/app"]).buildPushTargets(),
    @["ghcr.io/acme/app:1", "denied.example/app"])
  assertEq(invocation(["type=registry;name=ignored.example/app;" &
    "dangling-name-prefix=denied.example/app"], @["ghcr.io/acme/app:1"], push = true)
    .buildPushTargets(), @["ghcr.io/acme/app:1", "denied.example/app"])
  # BuildKit's own (misspelled) key
  assertEq(invocation(["type=registry;name=ghcr.io/acme/app:1;" &
    "dangling-name-prefix=denied.example/app;danging-name-empty-only=true"])
    .buildPushTargets(), @["ghcr.io/acme/app:1"])
  assertEq(invocation(["type=registry;dangling-name-prefix=denied.example/app;" &
    "danging-name-empty-only=true"]).buildPushTargets(), @["denied.example/app"])
  # BuildKit ignores other spellings, so they do not suppress the prefix push
  for key in ["dangling-name-only", "dangling-name-empty-only"]:
    assertEq(invocation(["type=registry;name=ghcr.io/acme/app:1;" &
      "dangling-name-prefix=denied.example/app;" & key & "=true"])
      .buildPushTargets(), @["ghcr.io/acme/app:1", "denied.example/app"])
  assertEq(invocation(["type=image;name=local/app;push=false;" &
    "dangling-name-prefix=denied.example/app"]).buildPushTargets(), newSeq[string]())
  assertEq(invocation(["type=image;name=local/app;push-by-digest=true"])
    .buildPushTargets(), newSeq[string]())
  doAssertRaises(ValueError):
    discard invocation(["type=image;name=denied.example/app;push=invalid"]).buildPushTargets()

proc testJson() =
  setPolicyJson(readFile(fixture))
  let policy = policyConfigs()[0]
  doAssert policy.configError == "", policy.configError
  selectPolicy(policy)
  let settings = loadRegistriesConfig().get()
  assertEq(settings.pullAllowed.len, 3)
  assertEq(settings.pullDenied, @[("glob", "ghcr.io/acme/untrusted/*")])
  assertEq(settings.pushAllowed.len, 2)
  assertEq(settings.pushDenied, @[("glob", "docker.io")])
  doAssert not settings.requireDigest
  doAssert settings.message.startsWith("Use approved registries")

  for (text, reason) in [
    ("""{"registries": {"enabeld": true}}""", "unknown field policy.registries.enabeld"),
    ("""{"registries": {"pull_allowed": ["docker.io"]}}""",
     "policy.registries.pull_allowed entries must be [kind, value] string pairs"),
    ("""{"registries": {"push_denied": [["glob"]]}}""",
     "policy.registries.push_denied entries must be [kind, value] string pairs"),
    ("""{"registries": {"require_digest": "yes"}}""",
     "policy.registries.require_digest must be a boolean"),
    ("""{"registries": []}""", "policy.registries must be an object"),
  ]:
    try:
      discard parsePolicyJson(text)
      doAssert false, "accepted: " & text
    except ValueError:
      doAssert reason in getCurrentExceptionMsg(), getCurrentExceptionMsg()

  setPolicyJson("""{"mode": "audit", "registries": {"enabled": false, "pull_allowed": [["glob", "x"]]}}""")
  selectPolicy(policyConfigs()[0])
  doAssert loadRegistriesConfig().isNone()
  setPolicyJson("")

proc registriesRule(): PolicyRule =
  loadPolicyRules()
  for rule in policyRules():
    if rule.name == "registries":
      return rule
  doAssert false, "registries is not registered"

proc evaluateJson(text: string, input: PolicyInput): bool =
  ## true when blocked; custom_check cannot load without a con4m runtime
  setPolicyJson(text)
  policyOutcome = nil
  let build = ChalkDict()
  build["command"] = pack(input.command)
  try:
    evaluatePolicies(build, proc(): PolicyInput = input, @[registriesRule()])
  except PolicyViolation:
    return true
  finally:
    setPolicyJson("")

proc testEngine() =
  let unchalked = PolicyInput(command: "push", pushTargets: @["ghcr.io/acme/app:1"],
                              errors: @[collectionError("image is not chalked", "ghcr.io/acme/app:1")])
  # a push-only policy does not need the pulled images
  doAssert not evaluateJson("""{"mode": "enforce", "on_error": "block", "registries":
    {"enabled": true, "push_allowed": [["glob", "ghcr.io/acme/*"]]}}""", unchalked)
  doAssert policyOutcome == nil

  for output in ["type=image;name=denied.example/app;push=1",
                 "type=image;name=ghcr.io/acme/app:1;push=true;" &
                 "dangling-name-prefix=denied.example/app"]:
    let targets = invocation([output]).buildPushTargets()
    doAssert evaluateJson("""{"mode":"enforce","on_error":"block","registries":
      {"enabled":true,"push_allowed":[["glob","ghcr.io/acme/*"]]}}""",
      PolicyInput(command: "build", pushTargets: targets))
    doAssert policyOutcome.findings[0].kind == "violation"
  let overrideTargets = invocation(["type=image;name=denied.example/app;push=false"],
                                   push = true).buildPushTargets()
  doAssert evaluateJson("""{"mode":"enforce","on_error":"block","registries":
    {"enabled":true,"push_allowed":[["glob","ghcr.io/acme/*"]]}}""",
    PolicyInput(command: "build", pushTargets: overrideTargets))
  doAssert policyOutcome.findings[0].kind == "violation"
  # pull checks do, and on_error decides
  doAssert evaluateJson("""{"mode": "enforce", "on_error": "block", "registries":
    {"enabled": true, "pull_allowed": [["glob", "docker.io"]]}}""", unchalked)
  doAssert policyOutcome.findings[0].rule == "registries"
  doAssert policyOutcome.findings[0].kind == "error"

  doAssert evaluateJson(readFile(fixture), PolicyInput(command: "push",
                                                       pushTargets: @["acme/app:1"]))
  let f = policyOutcome.findings[0]
  doAssert f.policyId == "registries@1" and f.source == "push" and f.image == "acme/app:1"
  doAssert "docker.io/acme/app is in a registry denied for push (docker.io)" in f.reason
  let summary = renderPolicySummary(policyOutcome.policies, policyOutcome.build)
  doAssert "| `acme/app:1` | push target |" in summary, summary
  doAssert "`push: ghcr.io/acme/*`" in summary, summary

  doAssert not evaluateJson(readFile(fixture), PolicyInput(command: "build",
    subjects: @[subject("alpine"), subject("cgr.dev/chainguard/static")],
    pushTargets: @["123.dkr.ecr.eu-west-1.amazonaws.com/app:1"]))
  doAssert policyOutcome == nil

proc testCache() =
  assertEq(parseCacheEntry("ghcr.io/acme/cache")["ref"], "ghcr.io/acme/cache")
  assertEq(parseCacheEntry("ghcr.io/acme/cache")["type"], "registry")
  let entry = parseCacheEntry("type=registry,\"REF=ghcr.io/acme/cache:1\",mode=max")
  doAssert entry["type"] == "registry" and entry["ref"] == "ghcr.io/acme/cache:1"
  doAssertRaises(ValueError): discard parseCacheEntry("ref=ghcr.io/acme/cache")
  doAssertRaises(ValueError): discard parseCacheEntry("type=registry,ref")

  # registry cache exports push; inline, local and gha caches do not
  assertEq(invocation([], @["ghcr.io/acme/app:1"], push = true, cacheTo = @[
    "type=registry,ref=denied.example/cache,mode=max", "type=inline",
    "type=local,dest=/tmp/cache", "type=gha", "quay.io/acme/cache"]).buildPushTargets(),
    @["ghcr.io/acme/app:1", "denied.example/cache", "quay.io/acme/cache"])
  assertEq(invocation([], cacheTo = @["type=registry,ref=denied.example/cache"])
    .buildPushTargets(), @["denied.example/cache"])
  doAssertRaises(ValueError):
    discard invocation([], cacheTo = @["type=registry"]).buildPushTargets()

  var ctx = invocation([], cacheFrom = @["ghcr.io/acme/cache:1",
    "type=registry,ref=denied.example/cache", "type=local,src=/tmp/cache",
    "type=gha", "type=registry", "nonsense"])
  ctx.dfDirectives["syntax"] = "docker/dockerfile:1"
  ctx.foundBuildArgs["BUILDKIT_SYNTAX"] = "denied.example/frontend:1 --flag"
  var input = PolicyInput(command: "build")
  input.addPullRefs(ctx)
  # a bare value is a registry cache reference
  let refs = input.pullRefs.mapIt((it.raw, it.source))
  let wantRefs = @[
    ("denied.example/frontend:1", "syntax"), ("docker/dockerfile:1", "syntax"),
    ("ghcr.io/acme/cache:1", "cache_from"), ("denied.example/cache", "cache_from"),
    ("nonsense", "cache_from")]
  doAssert refs == wantRefs, $refs
  assertEq(input.pullRefErrors.len, 1)
  doAssert "type=registry" in input.pullRefErrors[0].reason
  doAssert input.pullRefErrors[0].kind == "error"

  # pull refs are not build inputs, so image rules do not see them
  doAssert input.subjects.len == 0

  let settings = RegistriesConfig(pullAllowed: @[("glob", "docker.io"), ("glob", "ghcr.io")],
                                  requireDigest: true)
  let findings = settings.check(input)
  let got = findings.mapIt((it.image, it.source, it.kind))
  let wantGot = @[
    ("", "", "error"),
    ("denied.example/frontend:1", "syntax", "violation"),
    ("docker/dockerfile:1", "syntax", "violation"),
    ("denied.example/cache", "cache_from", "violation")]
  doAssert got == wantGot
  assertEq(findings[2].reason, "image is not pinned by digest")
  doAssert findings.allIt(it.rule == "registries")
  # push-only policies ignore pulled images, including pull refs
  assertEq(RegistriesConfig(pushDenied: @[("glob", "docker.io")]).check(input).len, 0)
  doAssert evaluateJson("""{"mode":"enforce","on_error":"block","registries":
    {"enabled":true,"pull_allowed":[["glob","docker.io"],["glob","ghcr.io"]]}}""",
    PolicyInput(command: "build", pullRefErrors: input.pullRefErrors))
  doAssert policyOutcome.findings[0].kind == "error"
  doAssert not evaluateJson("""{"mode":"enforce","on_error":"allow","registries":
    {"enabled":true,"pull_allowed":[["glob","docker.io"],["glob","ghcr.io"]]}}""",
    PolicyInput(command: "build", pullRefErrors: input.pullRefErrors))

testPatterns()
testMatching()
testCheck()
testRequireDigest()
testBuildPushTargets()
testJson()
testEngine()
testCache()
