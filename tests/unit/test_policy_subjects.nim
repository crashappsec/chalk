import std/[strutils, tables]
import ../../src/types
import ../../src/chalkjson
import ../../src/policy/api
import ../../src/docker/policy_subjects
import ../../src/docker/dockerfile

proc invocation(dockerfile: string, contexts: openArray[(string, string)] = []): DockerInvocation =
  result = DockerInvocation(cmd: DockerCmd.build,
                            inDockerFile: dockerfile,
                            foundLabels: newOrderedTable[string, string](),
                            dfDirectives: newOrderedTable[string, string](),
                            foundExtraContexts: newOrderedTable[string, string]())
  for (k, v) in contexts:
    result.foundExtraContexts[k] = v
  result.evalAndExtractDockerfile(initTable[string, string]())

proc repos(input: PolicyInput): seq[string] =
  for s in input.subjects:
    result.add(s.source & ":" & s.image.repo)

proc testStageIndex() =
  doAssert isDockerStageIndex("0", 2)
  doAssert isDockerStageIndex("0001", 2)
  doAssert not isDockerStageIndex("2", 2)
  doAssert not isDockerStageIndex("999999999999999999999999999999", 2)
  doAssert not isDockerStageIndex("1a", 2)
  doAssert not isDockerStageIndex("", 2)
  doAssert not isDockerStageIndex("0", 0)

proc testContextKeysAreNormalized() =
  # BuildKit looks contexts up by familiar name without :latest, so every
  # spelling of alpine resolves to the "alpine" context
  for spelling in ["alpine", "alpine:latest", "docker.io/library/alpine",
                   "registry-1.docker.io/library/alpine:latest"]:
    let ctx = invocation("FROM " & spelling & "\nCOPY --from=" & spelling & " /a /a\n",
                         {"alpine": "docker-image://evil:1"})
    doAssert ctx.buildSubjects().repos() == @["from:evil", "copy_from:evil"], spelling
  # a :latest key is never looked up by BuildKit, so the registry image is used
  doAssert invocation("FROM alpine\n", {"alpine:latest": "docker-image://evil:1"})
    .buildSubjects().repos() == @["from:alpine"]
  # non-latest tags are part of the key
  doAssert invocation("FROM alpine:3\n", {"alpine": "docker-image://evil:1"})
    .buildSubjects().repos() == @["from:alpine"]
  doAssert invocation("FROM alpine:3\n", {"alpine:3": "docker-image://evil:1"})
    .buildSubjects().repos() == @["from:evil"]
  doAssert invocation("FROM alpine\n", {"alpine::linux/amd64": "docker-image://evil:1"})
    .buildSubjects().repos() == @["from:evil"]
  doAssert invocation("FROM scratch\n", {"scratch": "docker-image://evil:1"})
    .buildSubjects().repos().len == 0

proc testForwardStageNameIsExternal() =
  # Docker resolves FROM only against earlier stages
  let ctx = invocation("FROM evil\nRUN true\nFROM alpine AS evil\n")
  doAssert ctx.buildSubjects().repos() == @["from:evil", "from:alpine"]
  doAssert ctx.dfSections[0].parent == nil
  let chained = invocation("FROM alpine AS Base\nFROM base\n")
  doAssert chained.dfSections[1].parent == chained.dfSections[0]
  doAssert chained.buildSubjects().repos() == @["from:alpine"]
  let mixedCase = invocation("FROM alpine AS base\nFROM Base\n")
  doAssert mixedCase.dfSections[1].parent == mixedCase.dfSections[0]
  doAssert mixedCase.buildSubjects().repos() == @["from:alpine"]
  # used to loop forever following aliases
  let cyclic = invocation("FROM b AS a\nFROM a AS b\n")
  doAssert cyclic.getBaseDockerSection().image.repo == "b"

proc testStageOverriddenByContext() =
  let ctx = invocation("FROM alpine AS base\nFROM base\nCOPY --from=base /a /a\n",
                       {"base": "docker-image://evil:1"})
  doAssert ctx.buildSubjects().repos() == @["from:evil"]

proc testUnresolvedContextsDoNotRaise() =
  for value in ["oci-layout:///tmp/oci", "docker-image://"]:
    let ctx = invocation("FROM x\nCOPY --from=y /a /a\n", {"x": value, "y": value})
    doAssert ctx.namedContext("x").get().kind == nckUnresolved
    let input = ctx.buildSubjects()
    doAssert input.subjects.len == 0 and input.errors.len == 2
    # mark metadata is collected outside the policy error boundary
    let bases = ctx.formatBaseImages()
    let copies = ctx.formatCopyImages()
    doAssert unpack[TableRef[string, string]](bases[""])["uri"] == ""
    doAssert unpack[string](unpack[seq[ChalkDict]](copies[""])[0]["named_context"]) == value
  let local = invocation("FROM x\nCOPY --from=files /a /a\n",
                         {"x": "/tmp/dir", "files": "/tmp/files"})
  doAssert local.buildSubjects().subjects.len == 0
  doAssert local.buildSubjects().errors.len == 0
  doAssert local.formatCopyImages().len == 0

proc extracted(data: string): ChalkObj =
  ChalkObj(extract: unpack[ChalkDict](parseJson(data).nimJsonToBox()))

proc mark(ctx: DockerInvocation): ChalkObj =
  ## round trip through JSON like a mark read back on push
  let data = ChalkDict()
  data["DOCKER_BASE_IMAGES"] = pack(ctx.formatBaseImages())
  data["DOCKER_COPY_IMAGES"] = pack(ctx.formatCopyImages())
  var contexts = newTable[string, string]()
  for k, v in ctx.foundExtraContexts:
    contexts[k] = v
  data["DOCKER_ADDITIONAL_CONTEXTS"] = pack(contexts)
  extracted(pack(data).boxToJson())

proc testPushMatchesBuild() =
  # base stage replaced by a context, then copied from by index and by name
  let ctx = invocation("FROM base AS one\nFROM alpine\nCOPY --from=0 /a /a\nCOPY --from=one /b /b\n" &
                       "COPY --from=nginx /c /c\n",
                       {"base": "docker-image://allowed:1"})
  doAssert ctx.buildSubjects().repos() == @["from:allowed", "from:alpine", "copy_from:nginx"]
  let input = ctx.mark().pushInput("test")
  doAssert input.errors.len == 0, $input.errors
  doAssert input.repos() == @["from:allowed", "from:alpine", "copy_from:nginx"], $input.repos()

proc testPushUnresolvedContext() =
  let ctx = invocation("FROM x\n", {"x": "oci-layout:///tmp/oci"})
  let input = ctx.mark().pushInput("test")
  doAssert input.subjects.len == 0
  doAssert input.errors.len == 1 and "named context" in input.errors[0].reason
  doAssert input.errors[0].image == "test"

proc testPushMetadata() =
  # legacy marks: no from_stage, stage copies identified by name or index
  let legacy = extracted("""{
    "DOCKER_BASE_IMAGES":{"base":{"uri":"scratch","named_contexts":"resolved"}},
    "DOCKER_COPY_IMAGES":{"base":[
      {"from":"base","uri":"busybox:latest","named_context":"docker-image://busybox:latest"},
      {"from":"0","uri":"scratch"}
    ]},
    "DOCKER_ADDITIONAL_CONTEXTS":{"base":"docker-image://busybox:latest"}
  }""")
  let input = legacy.pushInput("test")
  doAssert input.errors.len == 0
  doAssert input.subjects.len == 1 and input.subjects[0].image.repo == "busybox"
  for data in [
    """{"DOCKER_BASE_IMAGES":[]} """,
    """{"DOCKER_BASE_IMAGES":{}}""",
    """{"DOCKER_BASE_IMAGES":{"base":"invalid"}}""",
    """{"DOCKER_BASE_IMAGES":{"base":{"uri":123}}}""",
    """{"DOCKER_BASE_IMAGES":{"base":{"uri":"alpine","digest":[]}}}""",
    """{"DOCKER_BASE_IMAGES":{"base":{"uri":"scratch"}},"DOCKER_COPY_IMAGES":{"base":"bad"}}""",
    """{"DOCKER_BASE_IMAGES":{"base":{"uri":"scratch"}},"DOCKER_COPY_IMAGES":{"base":[{"from":"x","uri":"busybox","from_stage":"true"}]}}""",
    """{"DOCKER_BASE_IMAGES":{"base":{"uri":"scratch"}},"DOCKER_ADDITIONAL_CONTEXTS":{"external":"docker-image://busybox"}}""",
  ]:
    let bad = extracted(data).pushInput("test")
    doAssert bad.errors.len == 1 and bad.errors[0].kind == "error", data
  doAssert pushInput(nil, "test").errors.len == 1

testStageIndex()
testContextKeysAreNormalized()
testForwardStageNameIsExternal()
testStageOverriddenByContext()
testUnresolvedContextsDoNotRaise()
testPushMatchesBuild()
testPushUnresolvedContext()
testPushMetadata()
