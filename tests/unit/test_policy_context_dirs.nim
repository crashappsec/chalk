import std/[os, osproc, strutils, tables, tempfiles]
import ../../src/types
import ../../src/docker/policy
from ../../src/docker/git import checkout, contextPath

# docker/policy reaches subscan, whose commands only the chalk binary defines
proc runCmdInsert(path: seq[string]) {.exportc.} = discard
proc runCmdExtract(path: seq[string]) {.exportc.} = discard
proc runCmdDelete(path: seq[string]) {.exportc.} = discard

proc git(dir: string, args: varargs[string]): string =
  var command = "git -C " & dir.quoteShell()
  for arg in args:
    command &= " " & arg.quoteShell()
  let (output, code) = execCmdEx(command)
  doAssert code == 0, output
  output.strip()

let root = createTempDir("chalk-policy-context-", "")

proc fixture(name: string, files: openArray[(string, string)]): (string, string) =
  ## a repository and its commit
  let repo = root / name
  for (path, content) in files:
    createDir(parentDir(repo / path))
    writeFile(repo / path, content)
  discard git(repo, "init")
  discard git(repo, "add", ".")
  discard git(repo, "-c", "user.name=Policy Test", "-c", "user.email=policy@example.invalid",
    "-c", "commit.gpgsign=false", "commit", "-m", "fixture")
  (repo, git(repo, "rev-parse", "HEAD"))

proc gitInvocation(repo, sha: string, buildArgs: openArray[(string, string)] = []): DockerInvocation =
  # a bare clone of its own, as buildx fetches it: checkouts share its index
  let bare = createTempDir("fetched-", ".git", root)
  discard git(root, "clone", "--bare", repo, bare)
  let url = "https://example.invalid/repo.git#" & sha & ":service"
  result = DockerInvocation(cmd: DockerCmd.build,
    foundContext: url, newCmdLine: @["buildx", "build", url],
    gitContext: DockerGitContext(context: url, tmpGitDir: bare, subdir: "service",
      head: GitHead(gitRef: sha)),
    foundExtraContexts: newOrderedTable[string, string](),
    foundBuildArgs: newTable[string, string]())
  for (name, value) in buildArgs:
    result.foundBuildArgs[name] = value

try:
  let (repo, sha) = fixture("source", {
    "service" / "included.pem": "build context certificate",
    "outside.pem": "unrelated sibling certificate"})
  let ctx = gitInvocation(repo, sha)
  let url = ctx.foundContext
  # Modern Buildx has fetched Git objects but has not checked them out.
  doAssert ctx.gitContext.tmpWorkTree == ""
  var input: PolicyInput
  input.addPolicyContexts(ctx)
  let dirs = input.contextDirs
  doAssert input.contextErrors.len == 0
  doAssert dirs == @[ctx.gitContext.tmpWorkTree / "service"]
  doAssert input.mainContextDir == dirs[0]
  doAssert fileExists(dirs[0] / "included.pem")
  doAssert not fileExists(dirs[0] / "outside.pem")
  doAssert ctx.newCmdLine == @["buildx", "build", dirs[0]]
  doAssert ctx.policyDockerfilePath() == dirs[0] / "Dockerfile"
  ctx.foundFileArg = "Dockerfile.prod"
  doAssert ctx.policyDockerfilePath() == dirs[0] / "Dockerfile.prod"
  var fromFile: PolicyInput
  fromFile.addPolicyDockerfile(ctx)
  doAssert fromFile.stdinDockerfile == ""
  ctx.dockerFileLoc = stdinIndicator
  ctx.inDockerFile = "FROM alpine\n"
  doAssert ctx.policyDockerfilePath() == ""
  var fromStdin: PolicyInput
  fromStdin.addPolicyDockerfile(ctx)
  doAssert fromStdin.dockerfilePath == ""
  doAssert fromStdin.stdinDockerfile == "FROM alpine\n"
  # An existing checkout is reused with its selected subdirectory intact.
  let worktree = ctx.gitContext.tmpWorkTree
  var again: PolicyInput
  again.addPolicyContexts(ctx)
  doAssert again.contextDirs == dirs
  doAssert ctx.gitContext.tmpWorkTree == worktree
  ctx.gitContext.subdir = "missing"
  doAssertRaises(ValueError):
    var missing: PolicyInput
    missing.addPolicyContexts(ctx)
  removeDir(worktree)

  # A checkout made before policies ran (no build context flag support) was
  # already built from by command-line processing, so it is left alone.
  let legacy = gitInvocation(repo, sha)
  discard legacy.gitContext.checkout()
  var legacyInput: PolicyInput
  legacyInput.addPolicyContexts(legacy)
  doAssert legacyInput.contextDirs == @[legacy.gitContext.contextPath()]
  doAssert legacy.newCmdLine == @["buildx", "build", url]
  removeDir(legacy.gitContext.tmpWorkTree)

  # BuildKit keeps .git in the context only when it fetches the URL itself.
  for (value, rewritten) in [("1", false), ("true", false), ("0", true), ("false", true)]:
    let keep = gitInvocation(repo, sha, {"BUILDKIT_CONTEXT_KEEP_GIT_DIR": value})
    var keepInput: PolicyInput
    keepInput.addPolicyContexts(keep)
    doAssert keepInput.contextErrors.len == 0
    doAssert keepInput.contextDirs == @[keep.gitContext.contextPath()]
    let built = if rewritten: keepInput.contextDirs[0] else: url
    doAssert keep.newCmdLine == @["buildx", "build", built], value
    removeDir(keep.gitContext.tmpWorkTree)
  putEnv("BUILDKIT_CONTEXT_KEEP_GIT_DIR", "1")
  let fromEnv = gitInvocation(repo, sha, {"BUILDKIT_CONTEXT_KEEP_GIT_DIR": ""})
  var envInput: PolicyInput
  envInput.addPolicyContexts(fromEnv)
  doAssert fromEnv.newCmdLine == @["buildx", "build", url]
  delEnv("BUILDKIT_CONTEXT_KEEP_GIT_DIR")
  removeDir(fromEnv.gitContext.tmpWorkTree)

  # The checkout has no submodules, which BuildKit's git source fetches, even
  # when they are outside the context's subdirectory: docker fetches the URL
  # and the submodules are reported as unchecked.
  let (subRepo, subSha) = fixture("submodules", {
    "service" / "included.pem": "build context certificate",
    ".gitmodules": "[submodule \"vendor\"]\n\tpath = vendor\n\turl = https://example.invalid/vendor.git\n"})
  let sub = gitInvocation(subRepo, subSha)
  var subInput: PolicyInput
  subInput.addPolicyContexts(sub)
  doAssert subInput.contextDirs == @[sub.gitContext.contextPath()]
  doAssert subInput.mainContextDir == subInput.contextDirs[0]
  doAssert fileExists(subInput.contextDirs[0] / "included.pem")
  doAssert sub.newCmdLine == @["buildx", "build", sub.foundContext]
  doAssert subInput.contextErrors.len == 1
  doAssert subInput.contextErrors[0].kind == "error"
  doAssert subInput.contextErrors[0].subject == sub.foundContext
  doAssert "submodules" in subInput.contextErrors[0].reason
  removeDir(sub.gitContext.tmpWorkTree)

  # Contexts rules cannot scan are reported rather than silently skipped;
  # image and stage contexts are left to the image rules.
  let local = root / "local"
  createDir(local)
  let extra = newOrderedTable[string, string]()
  extra["lib"]   = local
  extra["git"]   = "https://github.com/acme/lib.git#main"
  extra["tar"]   = "https://example.invalid/ctx.tar.gz"
  extra["base"]  = "docker-image://alpine:3"
  extra["stage"] = "target:builder"
  extra["oci"]   = "oci-layout://" & local
  let stdinCtx = DockerInvocation(cmd: DockerCmd.build, foundContext: "-",
                                  foundExtraContexts: extra)
  var skipped: PolicyInput
  skipped.addPolicyContexts(stdinCtx)
  doAssert skipped.contextDirs == @[local.resolvePath()]
  # a named context comes first when the main context is not local
  doAssert skipped.mainContextDir == ""
  var subjects: seq[string]
  for e in skipped.contextErrors:
    doAssert e.kind == "error"
    subjects.add(e.subject)
  doAssert subjects == @["-", extra["git"], extra["tar"]], $subjects
finally:
  removeDir(root)
