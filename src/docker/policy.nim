## Copyright (c) 2026, Crash Override, Inc.
## This file is part of Chalk (see https://crashoverride.com/docs/chalk).

## Collect images before a build or push, inside the policy error boundary.
import std/[os]
import ".."/[policy/engine, types, utils/git]
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
  # gitContext is a build-only case field: reading it on push raises
  # FieldDefect (https://github.com/crashappsec/chalk/issues/776)
  if ctx.cmd == DockerCmd.push:
    result = gitOriginRepo(getCurrentDir())
  elif ctx.gitContext != nil:
    result = normalizeRepo(ctx.gitContext.remoteUrl)
  elif isGitContext(ctx.foundContext):
    # a failure before the git context was processed
    result = normalizeRepo(ctx.foundContext)
  elif ctx.foundContext notin ["", "-"] and "://" notin ctx.foundContext:
    result = gitOriginRepo(ctx.foundContext.resolvePath())
  if result == "":
    result = repoFromEnv()

proc repoResolver(ctx: DockerInvocation): PolicyRepoResolver =
  return proc(): string = ctx.commandRepo()

proc evaluateBuildPolicies*(ctx: DockerInvocation) =
  if not policyEnabled():
    return
  let collect = proc(): PolicyInput =
    ctx.buildSubjects(allStages = not hasBuildX())
  evaluatePolicies(ctx.buildInfo(), collect, ctx.repoResolver())

proc evaluatePushPolicies*(ctx: DockerInvocation, chalk: ChalkObj) =
  if not policyEnabled():
    return
  let build = ctx.pushInfo()
  let collect = proc(): PolicyInput =
    if not ctx.foundAllTags:
      return pushInput(chalk, ctx.foundImage)
    let tags = repositoryImageTags(ctx.foundImage)
    build["tags"] = pack(tags)
    for tag in tags:
      try:
        let input = pushInput(scanLocalPolicyImage(tag).get(nil), tag)
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
  let build = if ctx.cmd == DockerCmd.push: ctx.pushInfo() else: ctx.buildInfo()
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
