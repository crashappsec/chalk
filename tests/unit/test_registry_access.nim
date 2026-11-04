import std/[
  httpclient,
  httpcore,
  options,
  os,
  tables,
  tempfiles,
  uri,
]
import ../../src/docker/ids
import ../../src/docker/registry {.all.}
import ../../src/types
import ../../src/utils/json

proc linkInsertCommand(path: seq[string])
    {.exportc: "runCmdInsert", cdecl.} =
  discard

proc linkExtractCommand(path: seq[string])
    {.exportc: "runCmdExtract", cdecl.} =
  discard

proc linkDeleteCommand(path: seq[string])
    {.exportc: "runCmdDelete", cdecl.} =
  discard

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc writeAuth(path, registry, token: string) =
  writeFile(path, $(%*{
    "auths": {
      registry: {"auth": token},
    },
  }))

proc tokenFor(access: RegistryAccess, image: DockerImage): string =
  result = ""
  withRegistryAccess(access):
    for config in image.getConfigs(RegistryUseCase.ReadOnly):
      for _, value in config.auth:
        return value

proc main() =
  let dir = createTempDir("chalk-reg-access-", "")
  try:
    let
      fileA = dir / "a.json"
      fileB = dir / "b.json"
      image = parseImage("localhost:5000/demo@sha256:" & "a".repeat(64),
                         defaultTag = "")
    writeAuth(fileA, "localhost:5000", "YTph")
    writeAuth(fileB, "localhost:5000", "Yjpi")
    let
      accessA = newAuthFileRegistryAccess(fileA)
      accessB = newAuthFileRegistryAccess(fileB)
    doAssert not accessA.discoverDocker
    doAssert not accessB.discoverDocker
    assertEq(accessA.authFile, fileA)
    assertEq(tokenFor(accessA, image), "YTph")
    assertEq(tokenFor(accessB, image), "Yjpi")
    doAssert tokenFor(accessA, image) != tokenFor(accessB, image)

    var sources: seq[string]
    withRegistryAccess(accessA):
      for config in image.getConfigs(RegistryUseCase.ReadOnly):
        sources.add(config.source)
    doAssert "daemon" notin sources
    doAssert "buildx" notin sources
    doAssert "authfile" in sources

    let key = (image, HttpGet, "/manifests/x\t", RegistryUseCase.ReadOnly)
    accessA.jsonCache[key] = ("a", Response())
    doAssert key notin accessB.jsonCache
    doAssert key notin dockerRegistryAccess.jsonCache
    doAssert dockerRegistryAccess.discoverDocker
    doAssert accessA.strictReferrerLinks
    doAssert not dockerRegistryAccess.strictReferrerLinks

    let current = parseUri("https://registry.example/v2/demo/referrers/sha256:abc")
    let queryOnly = resolveReferrerNextLink(current, "?n=2")
    doAssert queryOnly.isSome()
    assertEq(queryOnly.get().path, current.path)
    assertEq(queryOnly.get().query, "n=2")
    assertEq(queryOnly.get().hostname, current.hostname)
    let relative = resolveReferrerNextLink(current, "next")
    doAssert relative.isSome()
    assertEq(relative.get().path, "/v2/demo/referrers/next")
    let absPath = resolveReferrerNextLink(current, "/v2/demo/referrers/sha256:abc?n=3")
    doAssert absPath.isSome()
    assertEq(absPath.get().path, "/v2/demo/referrers/sha256:abc")
    assertEq(absPath.get().query, "n=3")
    let sameOrigin = resolveReferrerNextLink(
      current, "https://registry.example/v2/demo/referrers/sha256:abc?n=4")
    doAssert sameOrigin.isSome()
    doAssert resolveReferrerNextLink(current, "//evil.example/v2/demo").isNone()
    doAssert resolveReferrerNextLink(
      current, "http://registry.example/v2/demo/referrers/sha256:abc").isNone()
    doAssert resolveReferrerNextLink(
      current, "https://registry.example:444/v2/demo/referrers/sha256:abc").isNone()
    doAssert resolveReferrerNextLink(
      current, "https://evil.example/v2/demo/referrers/sha256:abc").isNone()
  finally:
    removeDir(dir)

main()
