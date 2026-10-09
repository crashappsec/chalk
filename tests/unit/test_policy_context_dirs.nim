import std/[os, osproc, strutils, tables, tempfiles]
import ../../src/types
import ../../src/docker/policy

proc git(dir: string, args: varargs[string]): string =
  var command = "git -C " & dir.quoteShell()
  for arg in args:
    command &= " " & arg.quoteShell()
  let (output, code) = execCmdEx(command)
  doAssert code == 0, output
  output.strip()

let root = createTempDir("chalk-policy-context-", "")
try:
  let repo = root / "source"
  createDir(repo)
  createDir(repo / "service")
  writeFile(repo / "service" / "included.pem", "build context certificate")
  writeFile(repo / "outside.pem", "unrelated sibling certificate")
  discard git(repo, "init")
  discard git(repo, "add", ".")
  discard git(repo, "-c", "user.name=Policy Test", "-c", "user.email=policy@example.invalid",
    "-c", "commit.gpgsign=false", "commit", "-m", "fixture")
  let sha = git(repo, "rev-parse", "HEAD")
  let bare = root / "objects.git"
  discard git(root, "clone", "--bare", repo, bare)
  let url = "https://example.invalid/repo.git#" & sha & ":service"
  let ctx = DockerInvocation(cmd: DockerCmd.build,
    foundContext: url, newCmdLine: @["buildx", "build", url],
    gitContext: DockerGitContext(context: url, tmpGitDir: bare, subdir: "service",
      head: GitHead(gitRef: sha)),
    foundExtraContexts: newOrderedTable[string, string]())
  # Modern Buildx has fetched Git objects but has not checked them out.
  doAssert ctx.gitContext.tmpWorkTree == ""
  let dirs = ctx.policyContextDirs()
  doAssert dirs == @[ctx.gitContext.tmpWorkTree / "service"]
  doAssert fileExists(dirs[0] / "included.pem")
  doAssert not fileExists(dirs[0] / "outside.pem")
  doAssert ctx.newCmdLine == @["buildx", "build", dirs[0]]
  doAssert ctx.policyDockerfilePath() == dirs[0] / "Dockerfile"
  ctx.foundFileArg = "Dockerfile.prod"
  doAssert ctx.policyDockerfilePath() == dirs[0] / "Dockerfile.prod"
  ctx.dockerFileLoc = stdinIndicator
  doAssert ctx.policyDockerfilePath() == ""
  # An existing checkout is reused with its selected subdirectory intact.
  let checkout = ctx.gitContext.tmpWorkTree
  doAssert ctx.policyContextDirs() == dirs
  doAssert ctx.gitContext.tmpWorkTree == checkout
  ctx.gitContext.subdir = "missing"
  doAssertRaises(ValueError):
    discard ctx.policyContextDirs()
  removeDir(checkout)
finally:
  removeDir(root)
