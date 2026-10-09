## Copyright (c) 2026, Crash Override, Inc.
## This file is part of Chalk (see https://crashoverride.com/docs/chalk).

## Collect images before a build or push, inside the policy error boundary.
import std/[algorithm, os, strutils]
import ".."/[plugins/externalTool, policy/engine, policy/sbom, types, utils/git]
import "."/[exe, git as dockerGit, ids, inspect, policy_subjects, scan]

export engine

proc buildInfo(ctx: DockerInvocation): ChalkDict =
  var platforms: seq[string]
  for p in ctx.platforms:
    platforms.add($p)
  result = ChalkDict()
  result["command"] = pack("build")
  result["dockerfile_path"] = pack(ctx.dockerFileLoc)
  result["context"] = pack(ctx.foundContext)
  result["tags"] = pack(ctx.foundTags.asRepoTag())
  result["platforms"] = pack(platforms)

proc pushInfo(ctx: DockerInvocation): ChalkDict =
  result = ChalkDict()
  result["command"] = pack("push")
  result["tags"] = pack(@[ctx.foundImage])

proc gitOriginRepo(path: string): string =
  ## the same origin chalk reports as ORIGIN_URI for `path`
  try:
    let worktree = gitDiscoverWorkTree(path)
    if worktree != "":
      return normalizeRepo(gitCollect(worktree, collectTags = false).originUri)
  except CatchableError:
    warn("policy: could not read git origin of " & path & ": " & getCurrentExceptionMsg())
  return ""

proc commandRepo(ctx: DockerInvocation): string =
  ## Repository of the build context, or of the working directory for push,
  ## falling back to the CI job's repository.
  # build fields are case fields: reading them on push raises FieldDefect,
  # which the resolver's CatchableError handler does not catch
  # (https://github.com/crashappsec/chalk/issues/776)
  case ctx.cmd
  of DockerCmd.build:
    if ctx.gitContext != nil:
      result = normalizeRepo(ctx.gitContext.remoteUrl)
    elif isGitContext(ctx.foundContext):
      # a failure before the git context was processed
      result = normalizeRepo(ctx.foundContext)
    elif ctx.foundContext notin ["", "-"] and "://" notin ctx.foundContext:
      result = gitOriginRepo(ctx.foundContext.resolvePath())
  of DockerCmd.push:
    result = gitOriginRepo(getCurrentDir())
  else:
    discard
  if result == "":
    result = repoFromEnv()

proc repoResolver(ctx: DockerInvocation): PolicyRepoResolver =
  return proc(): string = ctx.commandRepo()

proc localDir(path: string): string =
  ## `path` when it is a local directory, as opposed to a URL or a stdin context
  if path in ["", "-"] or "://" in path or path.startsWith("target:") or isGitContext(path):
    return ""
  let resolved = path.resolvePath()
  if resolved.dirExists():
    return resolved
  return ""

proc contextDirs(ctx: DockerInvocation): seq[string] =
  ## local directories the build reads, for rules that scan the build context
  let main =
    if ctx.gitContext != nil and ctx.gitContext.tmpWorkTree != "":
      ctx.gitContext.tmpWorkTree
    else:
      ctx.foundContext.localDir()
  if main != "":
    result.add(main)
  if ctx.foundExtraContexts != nil:
    for _, value in ctx.foundExtraContexts:
      let dir = value.localDir()
      if dir != "" and dir notin result:
        result.add(dir)

proc addCommandInput(input: var PolicyInput, command: string, pushTargets: seq[string],
                     contextDirs: seq[string] = @[]) =
  input.command     = command
  input.pushTargets = pushTargets
  input.contextDirs = contextDirs
  input.host        = hostInfo

proc scanSbom(dir: string): Box =
  ## On demand, for rules that need an SBOM chalk did not collect
  ## (`run_sbom_tools` off, or a build context it does not cover): runs the
  ## enabled `sbom` tools by priority as `run_sbom_tools` would, stopping at
  ## the first that produces one.
  var tools: seq[(int, string)]
  for name in getChalkSubsections("tool"):
    let base = "tool." & name
    if attrGet[bool](base & ".enabled") and attrGet[string](base & ".kind") == "sbom":
      tools.add((attrGet[int](base & ".priority"), name))
  if len(tools) == 0:
    raise newException(ValueError, "no SBOM tool is enabled")
  tools.sort()
  var failures: seq[string]
  for (_, tool) in tools:
    try:
      let keys = runTool(tool, dir, force = true)
      if "SBOM" in keys:
        let sboms = ChalkDict()
        sboms[tool] = keys["SBOM"]
        return pack(sboms)
      failures.add(tool & " produced no SBOM")
    except CatchableError:
      failures.add(tool & ": " & getCurrentExceptionMsg())
  raise newException(ValueError, failures.join("; ") & " (see logs)")

setPolicySbomScanner(scanSbom)

proc evaluateBuildPolicies*(ctx: DockerInvocation) =
  if not policyEnabled():
    return
  let collect = proc(): PolicyInput =
    result = ctx.buildSubjects(allStages = not hasBuildX())
    let pushTargets = if ctx.foundPush: ctx.foundTags.asRepoTag() else: @[]
    result.addCommandInput("build", pushTargets, ctx.contextDirs())
    if ctx.dockerFileLoc notin ["", stdinIndicator]:
      result.dockerfilePath = ctx.dockerFileLoc.resolvePath()
  evaluatePolicies(ctx.buildInfo(), collect, ctx.repoResolver())

proc evaluatePushPolicies*(ctx: DockerInvocation, chalk: ChalkObj) =
  if not policyEnabled():
    return
  let build = ctx.pushInfo()
  let collect = proc(): PolicyInput =
    if not ctx.foundAllTags:
      result = pushInput(chalk, ctx.foundImage)
      result.addCommandInput("push", @[ctx.foundImage])
      if chalk != nil and chalk.extract != nil:
        result.pushMarks.add(chalk.extract)
      return
    let tags = repositoryImageTags(ctx.foundImage)
    build["tags"] = pack(tags)
    result.addCommandInput("push", tags)
    for tag in tags:
      try:
        let tagChalk = scanLocalPolicyImage(tag).get(nil)
        let input = pushInput(tagChalk, tag)
        if tagChalk != nil and tagChalk.extract != nil:
          result.pushMarks.add(tagChalk.extract)
        result.subjects.add(input.subjects)
        result.errors.add(input.errors)
      except CatchableError:
        result.errors.add(collectionError("could not inspect image: " & getCurrentExceptionMsg(), tag))
  evaluatePolicies(build, collect, ctx.repoResolver())

proc evaluateFailedPolicies(ctx: DockerInvocation, reason: string) =
  ## The command failed before its policies ran, e.g. on a FROM chalk cannot
  ## evaluate. Report that as a collection error so policy.on_error decides
  ## instead of the failsafe rerunning docker unchecked.
  if not policyEnabled() or policyEvaluated:
    return
  let build =
    case ctx.cmd
    of DockerCmd.build: ctx.buildInfo()
    of DockerCmd.push:  ctx.pushInfo()
    else: return
  let collect = proc(): PolicyInput =
    raise newException(ValueError, reason)
  evaluatePolicies(build, collect, ctx.repoResolver())

template withPolicyOnError*(ctx: DockerInvocation, code: untyped) =
  try:
    code
  except PolicyViolation:
    raise
  except CatchableError:
    let e = getCurrentException()
    ctx.evaluateFailedPolicies(e.msg)
    raise e
