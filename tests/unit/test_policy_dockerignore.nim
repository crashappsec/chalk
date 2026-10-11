import std/os
import ../../src/policy/api
import ../../src/policy/dockerignore

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc testParse() =
  let ignore = parseDockerignore("""
# comment

/vendor
node_modules/
!vendor/keep
*.log
[unclosed
""")
  assertEq(ignore.patterns, @["vendor", "node_modules/", "!vendor/keep", "*.log"])
  assertEq(ignore.invalid, @["[unclosed"])
  doAssert ignore.isIgnored("vendor/x/package-lock.json")
  doAssert not ignore.isIgnored("vendor/keep")
  doAssert ignore.isIgnored("node_modules/a/package.json")
  doAssert ignore.isIgnored("debug.log")
  # `*` does not cross `/`, as in docker
  doAssert not ignore.isIgnored("sub/debug.log")
  doAssert not ignore.isIgnored("")
  doAssert not ignore.isIgnored("src/package.json")
  doAssert ignore.prunes("node_modules")
  # a negation may re-include something below it
  doAssert not ignore.prunes("vendor")
  doAssert not DockerIgnore().isIgnored("anything")

proc testLoad() =
  let dir = getTempDir() / "chalk_test_policy_dockerignore"
  removeDir(dir)
  createDir(dir / "ctx")
  defer: removeDir(dir)
  let ctx = dir / "ctx"
  let dockerfile = dir / "Dockerfile.app"
  assertEq(ctx.dockerignorePath(), "")
  assertEq(loadDockerignore(ctx).patterns.len, 0)
  writeFile(ctx / ".dockerignore", "vendor\n")
  assertEq(loadDockerignore(ctx, dockerfile).patterns, @["vendor"])
  # the Dockerfile's own ignore file takes precedence
  writeFile(dockerfile & ".dockerignore", "build\n")
  assertEq(ctx.dockerignorePath(dockerfile), dockerfile & ".dockerignore")
  let ignore = loadDockerignore(ctx, dockerfile)
  assertEq(ignore.patterns, @["build"])
  assertEq(ignore.path, dockerfile & ".dockerignore")
  assertEq(loadDockerignore(ctx).patterns, @["vendor"])

  # only the main context uses the Dockerfile's ignore file
  let input = PolicyInput(command: "build", contextDirs: @[ctx, dir],
                          dockerfilePath: dockerfile)
  assertEq(input.mainContextDockerfile(ctx), dockerfile)
  assertEq(input.mainContextDockerfile(dir), "")

testParse()
testLoad()
