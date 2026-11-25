import std/[
  os,
  options,
  strutils,
]
import ../../src/docker/dockerfile
import ../../src/docker/ids
import ../../src/podman/binding
import ../../src/podman/exec
import ../../src/utils/json

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc parseOk(contents: string, target = ""): FinalExecConfig =
  let parsed = getFinalExecConfig(contents, target)
  doAssert parsed.config.isSome(), contents & " -> " & $parsed.errors
  doAssert len(parsed.errors) == 0, contents & " -> " & $parsed.errors
  return parsed.config.get()

proc mustReject(contents: string) =
  let parsed = getFinalExecConfig(contents)
  doAssert parsed.config.isNone() or len(parsed.errors) > 0, contents

proc base(entrypoint: JsonNode = nil, cmd: JsonNode = nil): BaseExec =
  BaseExec(
    entrypoint: entrypoint,
    cmd:        cmd,
    platform:   DeclaredPlatform(kind: dpkKnown,
                                 platform: parseDockerPlatform("linux/amd64")),
    binding:    BaseBinding(kind: bbConfigId, configId: repeat('a', 64)),
  )

proc expectPlan(decision: StartupPlanResult): StartupPlan =
  doAssert decision.kind == sprPlan
  doAssert decision.plan.binding.kind == bbConfigId
  doAssert decision.plan.binding.configId == repeat('a', 64)
  doAssert decision.plan.platform.kind == dpkKnown
  doAssert decision.plan.platform.platform.os == "linux"
  doAssert decision.plan.platform.platform.architecture == "amd64"
  return decision.plan

# A CMD declared before ENTRYPOINT belongs to the same stage and survives.
# Referencing that stage makes the CMD inherited relative to the final stage,
# so the injected ENTRYPOINT must restate it.
block:
  let config = parseOk(
    "FROM example/base AS base\n" &
    "CMD [\"old\"]\n" &
    "ENTRYPOINT [\"/ok\"]\n" &
    "FROM base\n"
  )
  assertEq(config.rootImage, "example/base")
  assertEq(config.entrypoint.kind, svExec)
  assertEq(config.entrypoint.argv, %*["/ok"])
  assertEq(config.cmd.kind, svExec)
  assertEq(config.cmd.argv, %*["old"])
  doAssert not config.cmdInFinal
  let plan = expectPlan(planStartup(config, base()))
  assertEq(plan.entrypoint, %*["/ok"])
  assertEq(plan.cmd, %*["old"])
  doAssert plan.emitCmd

# CMD after ENTRYPOINT is also a current-stage command.
block:
  let config = parseOk(
    "FROM example/base\n" &
    "ENTRYPOINT [\"/ok\"]\n" &
    "CMD [\"after\"]\n"
  )
  doAssert config.cmdInFinal
  let plan = expectPlan(planStartup(config, base()))
  assertEq(plan.cmd, %*["after"])

# A new ENTRYPOINT clears a CMD inherited from an earlier stage.
block:
  let config = parseOk(
    "FROM example/base AS base\n" &
    "CMD [\"old\"]\n" &
    "FROM base\n" &
    "ENTRYPOINT [\"/new\"]\n"
  )
  assertEq(config.cmd.kind, svAbsent)
  doAssert not config.cmdInFinal
  let plan = expectPlan(planStartup(config, base()))
  assertEq(plan.entrypoint, %*["/new"])
  doAssert plan.cmd == nil
  doAssert not plan.emitCmd

block:
  let config = parseOk(
    "FROM example/root AS first\n" &
    "FROM first AS second\n" &
    "FROM second\n" &
    "CMD [\"serve\"]\n"
  )
  assertEq(config.rootImage, "example/root")
  assertEq(config.entrypoint.kind, svInherited)
  doAssert config.cmdInFinal
  let plan = expectPlan(planStartup(
    config,
    base(%*["/root-init"], %*["root-default"]),
  ))
  assertEq(plan.entrypoint, %*["/root-init"])
  assertEq(plan.cmd, %*["serve"])
  doAssert plan.emitCmd

# Podman/Buildah expands shell-form startup instructions with /bin/sh -c even
# when SHELL precedes or follows the declaration.
block:
  let config = parseOk(
    "FROM example/base\n" &
    "SHELL [\"/bin/bash\", \"-lc\"]\n" &
    "ENTRYPOINT echo entry\n" &
    "CMD echo command\n" &
    "SHELL [\"/bin/sh\", \"-x\", \"-c\"]\n"
  )
  assertEq(config.entrypoint.kind, svShell)
  assertEq(config.cmd.kind, svShell)
  let plan = expectPlan(planStartup(config, base()))
  assertEq(plan.entrypoint, %*["/bin/sh", "-c", "echo entry"])
  assertEq(plan.cmd, %*["/bin/sh", "-c", "echo command"])

block:
  let declared = parseOk("FROM example/base\nCMD [\"serve\"]\n")
  let declaredPlan = expectPlan(planStartup(
    declared,
    base(),
  ))
  doAssert declaredPlan.entrypoint == nil
  assertEq(declaredPlan.cmd, %*["serve"])
  doAssert not declaredPlan.emitCmd

  let inherited = parseOk("FROM example/base\n")
  let inheritedPlan = expectPlan(planStartup(
    inherited,
    base(cmd = %*["/bin/sh"]),
  ))
  doAssert inheritedPlan.entrypoint == nil
  assertEq(inheritedPlan.cmd, %*["/bin/sh"])
  doAssert inheritedPlan.emitCmd

block:
  let config = parseOk("FROM scratch\n")
  let result = planStartup(config, base())
  assertEq(result.kind, sprRefuse)

block:
  let config = parseOk("FROM example/chalked\n")
  let plan = expectPlan(planStartup(
    config,
    base(
      entrypoint = %*["/chalk", "exec", "--heartbeat", "--"],
      cmd = %*["default"],
    ),
  ))
  doAssert plan.alreadyWrapped
  doAssert not plan.emitCmd

# Final-stage FROM --platform is inherited through aliases and is not taken
# from an earlier unused stage.
block:
  let inherited = parseOk(
    "FROM --platform=linux/arm64 example/arm AS base\n" &
    "FROM base\n" &
    "ENTRYPOINT [\"/ok\"]\n" &
    "CMD [\"stage\"]\n"
  )
  assertEq(inherited.fromPlatform.kind, dpkKnown)
  assertEq(inherited.fromPlatform.platform.architecture, "arm64")
  assertEq(inherited.rootFromPlatform.kind, dpkKnown)
  assertEq(inherited.rootFromPlatform.platform.architecture, "arm64")
  assertEq(inherited.rootImage, "example/arm")

# A platform flag on a stage reference describes an expectation for an already
# built stage. It cannot change ARM contents into amd64 contents, so a conflict
# leaves the final platform unresolved.
block:
  let conflicting = parseOk(
    "FROM --platform=linux/arm64 example/base AS base\n" &
    "FROM --platform=linux/amd64 base\n" &
    "ENTRYPOINT [\"/ok\"]\n"
  )
  assertEq(conflicting.fromPlatform.kind, dpkUnresolved)
  assertEq(conflicting.rootImage, "example/base")

block:
  let matching = parseOk(
    "FROM --platform=linux/amd64 example/base AS base\n" &
    "FROM --platform=linux/x86_64 base\n" &
    "ENTRYPOINT [\"/ok\"]\n"
  )
  assertEq(matching.fromPlatform.kind, dpkKnown)
  assertEq(matching.fromPlatform.platform.architecture, "amd64")

block:
  let unresolved = parseOk(
    "FROM --platform=linux/amd64 example/base AS base\n" &
    "FROM --platform=$CHALK_PLATFORM base\n" &
    "ENTRYPOINT [\"/ok\"]\n"
  )
  assertEq(unresolved.fromPlatform.kind, dpkUnresolved)

# A literal flag on a reference to a stage with no declared platform remains a
# request, not a fact about the resulting image. Frozen Podman ignores this
# flag for both external and scratch-rooted stages.
block:
  let inherited = parseOk(
    "FROM example/base AS base\n" &
    "FROM --platform=linux/amd64 base\n" &
    "ENTRYPOINT [\"/ok\"]\n"
  )
  assertEq(inherited.fromPlatform.kind, dpkRequested)
  assertEq(inherited.fromPlatform.platform.architecture, "amd64")
  assertEq(inherited.rootImage, "example/base")

block:
  let externalArm = parseOk(
    "FROM example/base AS base\n" &
    "FROM --platform=linux/arm64 base\n" &
    "ENTRYPOINT [\"/ok\"]\n"
  )
  assertEq(externalArm.fromPlatform.kind, dpkRequested)
  assertEq(externalArm.fromPlatform.platform.architecture, "arm64")
  assertEq(externalArm.rootImage, "example/base")

block:
  let scratchArm = parseOk(
    "FROM scratch AS base\n" &
    "FROM --platform=linux/arm64 base\n" &
    "ENTRYPOINT [\"/app\"]\n"
  )
  assertEq(scratchArm.fromPlatform.kind, dpkRequested)
  assertEq(scratchArm.fromPlatform.platform.architecture, "arm64")
  assertEq(scratchArm.rootImage, "scratch")

# DockerParse evaluates substitutions after parsing the whole file and carries
# the caller environment plus stage-local ARG and ENV values. Podman resolves
# FROM with its global build arguments instead. A variable-dependent FROM chain
# therefore cannot establish a final platform fact here.
block:
  let laterEnv = parseOk(
    "ARG CHALK_TEST_PLATFORM=linux/arm64\n" &
    "FROM --platform=$CHALK_TEST_PLATFORM example/base\n" &
    "ENV CHALK_TEST_PLATFORM=linux/amd64\n" &
    "ENTRYPOINT [\"/ok\"]\n"
  )
  assertEq(laterEnv.fromPlatform.kind, dpkUnresolved)

block:
  let laterStageArg = parseOk(
    "ARG CHALK_TEST_PLATFORM=linux/arm64\n" &
    "FROM --platform=$CHALK_TEST_PLATFORM example/base\n" &
    "ARG CHALK_TEST_PLATFORM=linux/amd64\n" &
    "ENTRYPOINT [\"/ok\"]\n"
  )
  assertEq(laterStageArg.fromPlatform.kind, dpkUnresolved)

block:
  let name = "CHALK_TEST_CALLER_PLATFORM"
  let hadValue = existsEnv(name)
  let oldValue = getEnv(name)
  putEnv(name, "linux/amd64")
  let callerCollision = parseOk(
    "ARG CHALK_TEST_CALLER_PLATFORM=linux/arm64\n" &
    "FROM --platform=$CHALK_TEST_CALLER_PLATFORM example/base\n" &
    "ENTRYPOINT [\"/ok\"]\n"
  )
  if hadValue:
    putEnv(name, oldValue)
  else:
    delEnv(name)
  assertEq(callerCollision.fromPlatform.kind, dpkUnresolved)

block:
  let substitutedImage = parseOk(
    "ARG CHALK_TEST_BASE=example/arm\n" &
    "FROM $CHALK_TEST_BASE\n" &
    "ENV CHALK_TEST_BASE=example/amd\n" &
    "ENTRYPOINT [\"/ok\"]\n"
  )
  assertEq(substitutedImage.fromPlatform.kind, dpkUnresolved)

# Podman supplies these automatic names. The startup parser does not model
# their values, so it must leave both declarations unresolved even if the
# Chalk process happens to export colliding variables.
block:
  for name in ["TARGETPLATFORM", "BUILDPLATFORM"]:
    let hadValue = existsEnv(name)
    let oldValue = getEnv(name)
    putEnv(name, "linux/amd64")
    let automatic = parseOk(
      "FROM --platform=$" & name & " example/base\n" &
      "ENTRYPOINT [\"/ok\"]\n"
    )
    if hadValue:
      putEnv(name, oldValue)
    else:
      delEnv(name)
    assertEq(automatic.fromPlatform.kind, dpkUnresolved)

block:
  let finalAmd64 = parseOk(
    "FROM --platform=linux/arm64 example/arm AS builder\n" &
    "FROM --platform=linux/amd64 example/amd\n" &
    "ENTRYPOINT [\"/ok\"]\n" &
    "CMD [\"final\"]\n"
  )
  assertEq(finalAmd64.fromPlatform.kind, dpkKnown)
  assertEq(finalAmd64.fromPlatform.platform.os, "linux")
  assertEq(finalAmd64.fromPlatform.platform.architecture, "amd64")
  assertEq(finalAmd64.rootImage, "example/amd")

block:
  let digest = parseOk(
    "FROM example/arm@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n" &
    "ENTRYPOINT [\"/ok\"]\n" &
    "CMD [\"digest\"]\n"
  )
  assertEq(digest.fromPlatform.kind, dpkAbsent)
  doAssert digest.rootImage.find("sha256:") >= 0

block:
  let middle = parseOk(
    "FROM example/base AS builder\n" &
    "ENTRYPOINT [\"/ep-builder\"]\n" &
    "CMD [\"cmd-builder\"]\n" &
    "FROM example/base AS runtime\n" &
    "ENTRYPOINT [\"/ep-runtime\"]\n" &
    "CMD [\"cmd-runtime\"]\n",
    "builder",
  )
  assertEq(middle.stageAlias, "builder")
  doAssert middle.injectAt.isSome()
  doAssert middle.cmdInFinal
  let middlePlan = expectPlan(planStartup(middle, base()))
  assertEq(middlePlan.entrypoint, %*["/ep-builder"])
  assertEq(middlePlan.cmd, %*["cmd-builder"])

  let inheritedTarget = parseOk(
    "FROM example/base AS base\n" &
    "CMD [\"old\"]\n" &
    "ENTRYPOINT [\"/ok\"]\n" &
    "FROM base AS runtime\n",
    "runtime",
  )
  doAssert not inheritedTarget.cmdInFinal
  assertEq(inheritedTarget.rootImage, "example/base")
  let inheritedPlan = expectPlan(planStartup(inheritedTarget, base()))
  doAssert inheritedPlan.emitCmd

  let namedLast = parseOk(
    "FROM example/base AS builder\nENTRYPOINT [\"/ep-builder\"]\n" &
    "FROM example/base AS runtime\nENTRYPOINT [\"/ep-runtime\"]\nCMD [\"last\"]\n",
    "runtime",
  )
  doAssert namedLast.injectAt.isNone()
  assertEq(namedLast.stageAlias, "runtime")
  doAssert namedLast.cmdInFinal

  let armBuilder = parseOk(
    "FROM --platform=linux/arm64 example/arm AS builder\nENTRYPOINT [\"/arm\"]\n" &
    "FROM --platform=linux/amd64 example/amd AS runtime\nENTRYPOINT [\"/amd\"]\n",
    "builder",
  )
  assertEq(armBuilder.fromPlatform.kind, dpkKnown)
  assertEq(armBuilder.fromPlatform.platform.architecture, "arm64")
  assertEq(armBuilder.rootImage, "example/arm")

# Keep the existing empty-CMD policy. An empty CMD alone is rejected, while an
# immediately following ENTRYPOINT clears it because imagebuilder did not set
# CmdSet. A prior nonempty CMD leaves CmdSet true.
block:
  mustReject("FROM example/base\nCMD []\n")
  let cleared = parseOk(
    "FROM example/base\n" &
    "CMD []\n" &
    "ENTRYPOINT [\"/app\"]\n"
  )
  assertEq(cleared.cmd.kind, svAbsent)
  mustReject(
    "FROM example/base\n" &
    "CMD [\"old\"]\n" &
    "CMD []\n" &
    "ENTRYPOINT [\"/app\"]\n"
  )
