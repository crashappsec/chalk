import std/[os, options]
import ../../src/[commands, confload, types]
import ../../src/docker/base
import ../../src/policy/state

const
  originalArgs = @[
    "build",
    "--diagnostic-original=kept",
    "context with spaces",
  ]
  originalStdIn = "FROM scratch\nRUN printf 'original stdin'\n"
  wrappedArgs = @[
    "build",
    "--diagnostic-wrapped=changed",
    "wrapped context",
  ]
  wrappedStdIn = "FROM scratch\nRUN printf 'wrapped stdin'\n"

template recordLaunchStateWhenAvailable(ctx: DockerInvocation, status: int) =
  ## Follow implementations that expose Docker build launch state while keeping
  ## this diagnostic compatible with implementations that always fall back.
  when compiles(ctx.buildAttempted):
    ctx.buildAttempted = true
    ctx.buildExitCode = some(status)

loadAllConfigs()
let
  scenario = getEnv("DOCKER_FALLBACK_SCENARIO")
  ctx = DockerInvocation(
    cmd: DockerCmd.build,
    originalArgs: originalArgs,
    originalStdIn: originalStdIn,
    newCmdLine: wrappedArgs,
    newStdIn: wrappedStdIn,
  )

ctx.withDockerFailsafe():
  case scenario
  of "preparation":
    raise newException(IOError, "diagnostic preparation exception")
  of "wrapped-nonzero":
    let status = ctx.runMungedDockerInvocation()
    ctx.recordLaunchStateWhenAvailable(status)
    if status != 0:
      raise newException(
        ValueError,
        "wrapped docker build exited with " & $status,
      )
    raise newException(AssertionDefect, "wrapped build unexpectedly succeeded")
  of "post-launch":
    let status = ctx.runMungedDockerInvocation()
    ctx.recordLaunchStateWhenAvailable(status)
    raise newException(IOError, "diagnostic post-launch exception")
  of "policy":
    raise newException(PolicyViolation, "diagnostic policy refusal")
  else:
    raise newException(ValueError, "unknown diagnostic scenario: " & scenario)
