import std/[
  os,
  sequtils,
  tempfiles,
]
import ../../src/docker/repo_digest
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

  let
    tempRoot = createTempDir("chalk-dockerode-command-test-", "")
    priorTmpDir = getEnv("TMPDIR")
    hadTmpDir = existsEnv("TMPDIR")
  putEnv("TMPDIR", tempRoot)
  try:
    doAssert runDockerodeCommand(
      "/bin/sh",
      @["-c", "exit 0"],
      noExternalConfig = true,
    ) == 0
    doAssert toSeq(walkDir(tempRoot)).len == 0
    doAssert runDockerodeCommand(
      "/bin/sh",
      @["-c", "exit 7"],
      noExternalConfig = true,
    ) == 7
    doAssert toSeq(walkDir(tempRoot)).len == 0
  finally:
    if hadTmpDir:
      putEnv("TMPDIR", priorTmpDir)
    else:
      delEnv("TMPDIR")
    removeDir(tempRoot)

main()
