##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Collects images referenced by docker build/push for policy evaluation.

import std/[
  strutils,
]
import ".."/[
  policy/engine,
  types,
]
import "."/[
  dockerfile,
  ids,
]

export engine

proc addDigest(digests: var seq[string], digest: string) =
  if digest != "" and digest notin digests:
    digests.add(digest)

proc isStageRef(ctx: DockerInvocation, name: string): bool =
  return (
    name in ctx.dfSectionAliases or
    (name.len > 0 and name.allCharsInSet(Digits) and parseInt(name) < len(ctx.dfSections))
  )

proc buildSubjects(ctx: DockerInvocation): seq[PolicySubject] =
  for base in ctx.getBasesDockerSections():
    if base.image.repo == "scratch":
      continue
    let image =
      if base.foundImage.exists():
        base.foundImage
      else:
        base.image
    var digests = newSeq[string]()
    digests.addDigest(base.foundImage.digest)
    digests.addDigest(base.image.digest)
    result.add(PolicySubject(
      image:   image,
      raw:     $image,
      digests: digests,
      stage:   base.alias,
      source:  "from",
    ))
  for section in ctx.dfSections:
    for copy in section.copies:
      if copy.frm == "" or copy.frm in ctx.foundExtraContexts or ctx.isStageRef(copy.frm):
        continue
      let image = parseImage(copy.frm, defaultTag = "")
      var digests = newSeq[string]()
      digests.addDigest(image.digest)
      result.add(PolicySubject(
        image:   image,
        raw:     copy.frm,
        digests: digests,
        stage:   section.alias,
        source:  "copy_from",
      ))

proc buildInfo(ctx: DockerInvocation): ChalkDict =
  var platforms = newSeq[string]()
  for p in ctx.platforms:
    platforms.add($p)
  result = ChalkDict()
  result["command"]         = pack("build")
  result["dockerfile_path"] = pack(ctx.dockerFileLoc)
  result["context"]         = pack(ctx.foundContext)
  result["tags"]            = pack(ctx.foundTags.asRepoTag())
  result["platforms"]       = pack(platforms)

proc evaluateBuildPolicies*(ctx: DockerInvocation) =
  if not policyEnabled():
    return
  evaluatePolicies(ctx.buildSubjects(), ctx.buildInfo())

proc pushSubjects(chalk: ChalkObj): seq[PolicySubject] =
  # pushes only know the images recorded in the chalk mark at build time
  var baseAliases = newSeq[string]()
  if "DOCKER_BASE_IMAGES" in chalk.extract:
    let bases = unpack[OrderedTableRef[string, Box]](chalk.extract["DOCKER_BASE_IMAGES"])
    for alias, info in bases:
      baseAliases.add(alias)
      let
        fields = unpack[OrderedTableRef[string, Box]](info)
        uri    = unpack[string](fields.getOrDefault("uri", pack("")))
      if uri == "":
        continue
      let image = parseImage(uri, defaultTag = "")
      if image.repo == "scratch":
        continue
      var digests = newSeq[string]()
      digests.addDigest(unpack[string](fields.getOrDefault("digest", pack(""))))
      digests.addDigest(image.digest)
      result.add(PolicySubject(
        image:   image,
        raw:     uri,
        digests: digests,
        stage:   alias,
        source:  "from",
      ))
  if "DOCKER_COPY_IMAGES" in chalk.extract:
    let copies = unpack[OrderedTableRef[string, Box]](chalk.extract["DOCKER_COPY_IMAGES"])
    for alias, items in copies:
      for item in unpack[seq[Box]](items):
        let
          fields = unpack[OrderedTableRef[string, Box]](item)
          frm    = unpack[string](fields.getOrDefault("from", pack("")))
          uri    = unpack[string](fields.getOrDefault("uri", pack("")))
        if frm == "" or uri == "" or frm in baseAliases or frm.allCharsInSet(Digits):
          continue
        let image = parseImage(uri, defaultTag = "")
        var digests = newSeq[string]()
        digests.addDigest(image.digest)
        result.add(PolicySubject(
          image:   image,
          raw:     frm,
          digests: digests,
          stage:   alias,
          source:  "copy_from",
        ))

proc evaluatePushPolicies*(ctx: DockerInvocation, chalk: ChalkObj) =
  if not policyEnabled():
    return
  let build = ChalkDict()
  build["command"] = pack("push")
  build["tags"]    = pack(@[ctx.foundImage])
  let known = chalk != nil and chalk.extract != nil and "DOCKER_BASE_IMAGES" in chalk.extract
  if not known:
    if not goldenImagesEnabled():
      return
    evaluatePolicies(@[], build, errors = @[PolicyFinding(
      rule:   "golden_images",
      kind:   "error",
      image:  ctx.foundImage,
      reason: "image is not chalked so its base images are unknown",
    )])
    return
  evaluatePolicies(chalk.pushSubjects(), build)
