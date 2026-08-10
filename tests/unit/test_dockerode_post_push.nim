import std/[
  json,
  os,
  posix,
  sequtils,
  strutils,
  tempfiles,
]
import ../../src/docker/exe
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

  let mergedAuth = mergeDockerAuthConfig(
    %*{
      "auths": {
        "ambient.example": {"auth": "ambient"},
        "sdk.example": {"auth": "old"},
      },
      "credsStore": "desktop",
    },
    %*{"auths": {"sdk.example": {"auth": "sdk"}}},
  )
  doAssert mergedAuth{"credsStore"}.getStr() == "desktop"
  doAssert mergedAuth{"auths"}{"ambient.example"}{"auth"}.getStr() == "ambient"
  doAssert mergedAuth{"auths"}{"sdk.example"}{"auth"}.getStr() == "sdk"
  setDockerAuthConfig(%*{"auths": {"sdk.example": {"auth": "sdk"}}})
  doAssert getDockerAuthConfig(){"auths"}{"sdk.example"}{"auth"}.getStr() == "sdk"
  resetDockerAuthConfig()
  doAssert getDockerAuthConfig(){"auths"}{"sdk.example"}{"auth"}.getStr() == "sdk"

  let
    priorHome = getEnv("HOME")
    hadHome = existsEnv("HOME")
    passwd = getpwuid(getuid())
  putEnv("HOME", "/tmp/chalk-dockerode-home")
  doAssert dockerPostPushSocketSupported(
    "/tmp/chalk-dockerode-home/.docker/run/docker.sock",
  )
  delEnv("HOME")
  if passwd != nil and passwd.pw_dir != nil:
    doAssert dockerPostPushSocketSupported(
      $passwd.pw_dir / ".docker/run/docker.sock",
    )
  if hadHome:
    putEnv("HOME", priorHome)
  else:
    delEnv("HOME")

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
    priorTimeout = getEnv("CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS")
    hadNodeOptions = existsEnv("NODE_OPTIONS")
    hadChalk = existsEnv("CHALK_DOCKERODE_CHALK")
    hadNoExternal = existsEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG")
    hadTimeout = existsEnv("CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS")
  putEnv("TMPDIR", tempRoot)
  putEnv("NODE_OPTIONS", "--trace-warnings")
  putEnv("CHALK_DOCKERODE_CHALK", "prior-chalk")
  putEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG", "prior-no-external")
  delEnv("CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS")
  try:
    doAssert runDockerodeCommand(
      "/bin/sh",
      @["-c", "test \"$CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS\" = 300000"],
      noExternalConfig = true,
    ) == 0
    doAssert toSeq(walkDir(tempRoot)).len == 0
    doAssert getEnv("NODE_OPTIONS") == "--trace-warnings"
    doAssert getEnv("CHALK_DOCKERODE_CHALK") == "prior-chalk"
    doAssert getEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG") == "prior-no-external"
    doAssert not existsEnv("CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS")
    putEnv("CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS", "1234")
    doAssert runDockerodeCommand(
      "/bin/sh",
      @["-c", "test \"$CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS\" = 1234 && exit 7"],
      noExternalConfig = true,
    ) == 7
    doAssert toSeq(walkDir(tempRoot)).len == 0
    doAssert getEnv("NODE_OPTIONS") == "--trace-warnings"
    doAssert getEnv("CHALK_DOCKERODE_CHALK") == "prior-chalk"
    doAssert getEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG") == "prior-no-external"
    doAssert getEnv("CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS") == "1234"
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
    if hadTimeout:
      putEnv("CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS", priorTimeout)
    else:
      delEnv("CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS")
    removeDir(tempRoot)

main()
