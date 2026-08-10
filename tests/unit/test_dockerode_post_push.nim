import std/[
  os,
  sequtils,
  strutils,
  tempfiles,
]
import ../../src/docker/repo_digest
import ../../src/dockerode_post_push/payload
import ../../src/dockerode_post_push/runner

const
  Digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  OtherDigest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

proc main() =
  doAssert repoDigestMatches(
    "docker.io/library/alpine:latest",
    Digest,
    @["alpine@" & Digest],
  )
  doAssert repoDigestMatches(
    "index.docker.io/team/app:release",
    Digest,
    @["registry-1.docker.io/team/app@" & Digest],
  )
  doAssert repoDigestMatches(
    "registry.example:5000/team/app:release",
    Digest,
    @["registry.example:5000/team/app@" & Digest],
  )
  doAssert not repoDigestMatches("alpine:latest", Digest, @[])
  doAssert not repoDigestMatches("alpine:latest", Digest, @["busybox@" & Digest])
  doAssert not repoDigestMatches("alpine:latest", Digest, @["alpine@" & OtherDigest])

  let payloadFixture = createTempFile("chalk-dockerode-payload-", ".json")
  try:
    payloadFixture.cfile.write('x'.repeat(dockerPostPushMaxPayloadBytes + 1))
    payloadFixture.cfile.setFilePos(0)
    doAssert readDockerPostPushPayload(payloadFixture.cfile).len ==
      dockerPostPushMaxPayloadBytes + 1
  finally:
    payloadFixture.cfile.close()
    removeFile(payloadFixture.path)

  let
    tempRoot = createTempDir("chalk-dockerode-command-test-", "")
    priorTmpDir = getEnv("TMPDIR")
    hadTmpDir = existsEnv("TMPDIR")
    priorNodeOptions = getEnv("NODE_OPTIONS")
    priorChalk = getEnv("CHALK_DOCKERODE_CHALK")
    priorNoExternal = getEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG")
    hadNodeOptions = existsEnv("NODE_OPTIONS")
    hadChalk = existsEnv("CHALK_DOCKERODE_CHALK")
    hadNoExternal = existsEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG")
  putEnv("TMPDIR", tempRoot)
  putEnv("NODE_OPTIONS", "--trace-warnings")
  putEnv("CHALK_DOCKERODE_CHALK", "prior-chalk")
  putEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG", "prior-no-external")
  try:
    doAssert runDockerodeCommand(
      "/bin/sh",
      @["-c", "exit 0"],
      noExternalConfig = true,
    ) == 0
    doAssert toSeq(walkDir(tempRoot)).len == 0
    doAssert getEnv("NODE_OPTIONS") == "--trace-warnings"
    doAssert getEnv("CHALK_DOCKERODE_CHALK") == "prior-chalk"
    doAssert getEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG") == "prior-no-external"
    doAssert runDockerodeCommand(
      "/bin/sh",
      @["-c", "exit 7"],
      noExternalConfig = true,
    ) == 7
    doAssert toSeq(walkDir(tempRoot)).len == 0
    doAssert getEnv("NODE_OPTIONS") == "--trace-warnings"
    doAssert getEnv("CHALK_DOCKERODE_CHALK") == "prior-chalk"
    doAssert getEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG") == "prior-no-external"
  finally:
    if hadTmpDir:
      putEnv("TMPDIR", priorTmpDir)
    else:
      delEnv("TMPDIR")
    if hadNodeOptions:
      putEnv("NODE_OPTIONS", priorNodeOptions)
    else:
      delEnv("NODE_OPTIONS")
    if hadChalk:
      putEnv("CHALK_DOCKERODE_CHALK", priorChalk)
    else:
      delEnv("CHALK_DOCKERODE_CHALK")
    if hadNoExternal:
      putEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG", priorNoExternal)
    else:
      delEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG")
    removeDir(tempRoot)

main()
