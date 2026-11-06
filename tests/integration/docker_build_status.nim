import std/[os, options, strutils]
import ../../src/[commands, confload, types]
import ../../src/docker/base

loadAllConfigs()
let status = getEnv("STAGE_TERMINAL_STATUS", "unknown")
let ctx = DockerInvocation(
  cmd: DockerCmd.build,
  originalArgs: @["build", "stage01-original-must-not-run"],
  buildAttempted: getEnv("STAGE_PRELAUNCH") != "true",
  buildExitCode: if status == "unknown": none(int) else: some(parseInt(status)),
)
ctx.withDockerFailsafe():
  raise newException(IOError, "diagnostic post-launch exception")
