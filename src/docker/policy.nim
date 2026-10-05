## Copyright (c) 2026, Crash Override, Inc.
## This file is part of Chalk (see https://crashoverride.com/docs/chalk).

## Collect images before a build or push, inside the policy error boundary.
import ".."/[policy/engine, types]
import "."/[ids, inspect, policy_subjects, scan]

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

proc evaluateBuildPolicies*(ctx: DockerInvocation) =
  if not policyEnabled():
    return
  evaluatePolicies(ctx.buildInfo(), proc(): PolicyInput =
    ctx.buildSubjects()
  )

proc evaluatePushPolicies*(ctx: DockerInvocation, chalk: ChalkObj) =
  if not policyEnabled():
    return
  let build = ChalkDict()
  build["command"] = pack("push")
  build["tags"] = pack(@[ctx.foundImage])
  evaluatePolicies(build, proc(): PolicyInput =
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
  )
