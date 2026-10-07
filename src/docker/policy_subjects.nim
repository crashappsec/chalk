## Copyright (c) 2026, Crash Override, Inc.
## This file is part of Chalk (see https://crashoverride.com/docs/chalk).

## Pure subject collection from parsed Dockerfiles and extracted chalk marks.
## Docker I/O lives in policy.nim so metadata decoding can be tested directly.
import std/[sequtils, strutils]
import ".."/[policy/engine, types]
import "."/[dockerfile, ids]

proc addDigest(digests: var seq[string], digest: string) =
  if digest != "" and digest notin digests:
    digests.add(digest)

proc addContext(input: var PolicyInput, context: NamedContext, stage, source: string) =
  case context.kind
  of nckLocal:
    discard # not a container image
  of nckUnresolved:
    input.errors.add(collectionError("cannot determine image identity for named context: " &
                                     context.name & "=" & context.value))
  of nckImage:
    var digests: seq[string]
    digests.addDigest(context.image.digest)
    input.subjects.add(PolicySubject(image: context.image, raw: $context.image,
                                     digests: digests, stage: stage, source: source))

proc buildSubjects*(ctx: DockerInvocation, allStages = false): PolicyInput =
  ## stages the build never reaches pull nothing, so they are not checked
  let sections = ctx.builtDockerSections(allStages)
  for section in sections:
    let context = ctx.stageContext(section)
    if context.isSome():
      result.addContext(context.get(), section.alias, "from")
      continue
    if section.parent != nil:
      continue # built on an earlier stage, which is checked itself
    let original =
      if section.foundImage.exists(): section.foundImage
      else: section.image
    if original.repo == "scratch":
      continue
    var digests: seq[string]
    digests.addDigest(section.image.digest)
    digests.addDigest(original.digest)
    result.subjects.add(PolicySubject(image: original, raw: $original, digests: digests,
                                      stage: section.alias, source: "from"))
  for section in sections:
    if section.unknownMount:
      result.errors.add(collectionError("cannot determine the source of a RUN --mount in stage: " &
                                        section.alias))
    for (frm, source) in section.copies.mapIt((it.frm, "copy_from")) &
                         section.mounts.mapIt((it, "mount_from")):
      if frm == "" or ctx.copyStage(frm) != nil:
        continue # stages are checked through their own FROM
      let context = ctx.namedContext(frm)
      if context.isSome():
        result.addContext(context.get(), section.alias, source)
        continue
      let image = parseImage(frm, defaultTag = "")
      var digests: seq[string]
      digests.addDigest(image.digest)
      result.subjects.add(PolicySubject(image: image, raw: $image, digests: digests,
                                        stage: section.alias, source: source))

proc metadataTable(value: Box): OrderedTableRef[string, Box] =
  if value.isNil() or value.kind != MkTable:
    raise newException(ValueError, "expected a policy metadata object")
  unpack[OrderedTableRef[string, Box]](value)

proc metadataList(value: Box): seq[Box] =
  if value.isNil() or value.kind != MkSeq:
    raise newException(ValueError, "expected a policy metadata list")
  unpack[seq[Box]](value)

proc metadataString(value: Box): string =
  if value.isNil() or value.kind != MkStr:
    raise newException(ValueError, "expected a policy metadata string")
  unpack[string](value)

proc metadataBool(value: Box): bool =
  if value.isNil() or value.kind != MkBool:
    raise newException(ValueError, "expected a policy metadata boolean")
  unpack[bool](value)

proc unresolvedContext(fields: OrderedTableRef[string, Box], uri: string): string =
  ## a context recorded without an image identity, e.g. oci-layout://
  if uri != "" or "named_context" notin fields:
    return ""
  return metadataString(fields["named_context"])

proc pushSubjects*(chalk: ChalkObj): PolicyInput =
  let bases = metadataTable(chalk.extract["DOCKER_BASE_IMAGES"])
  if bases.len == 0:
    raise newException(ValueError, "base image metadata is empty")
  var baseAliases, baseUris, unbuilt: seq[string]
  for alias, info in bases:
    baseAliases.add(alias)
    let fields = metadataTable(info)
    # marks predating "built" are checked in full
    if metadataString(fields.getOrDefault("built", pack("true"))) == "false":
      unbuilt.add(alias)
      continue
    let uri = metadataString(fields.getOrDefault("uri", pack("")))
    let unresolved = fields.unresolvedContext(uri)
    if unresolved != "":
      result.errors.add(collectionError("cannot determine image identity for named context: " &
                                        unresolved))
      continue
    if uri == "":
      raise newException(ValueError, "base image metadata is missing its uri")
    baseUris.add(uri)
    let image = parseImage(uri, defaultTag = "")
    if image.repo == "scratch":
      continue
    var digests: seq[string]
    digests.addDigest(metadataString(fields.getOrDefault("digest", pack(""))))
    digests.addDigest(image.digest)
    result.subjects.add(PolicySubject(image: image, raw: uri, digests: digests,
                                      stage: alias, source: "from"))
  if "DOCKER_COPY_IMAGES" in chalk.extract:
    let copies = metadataTable(chalk.extract["DOCKER_COPY_IMAGES"])
    for alias, items in copies:
      if alias in unbuilt:
        continue
      for item in metadataList(items):
        let fields = metadataTable(item)
        let frm = metadataString(fields.getOrDefault("from", pack("")))
        let uri = metadataString(fields.getOrDefault("uri", pack("")))
        if frm == "":
          raise newException(ValueError, "COPY image metadata is missing its from")
        if metadataBool(fields.getOrDefault("from_stage", pack(false))):
          continue # stages are checked through DOCKER_BASE_IMAGES
        let unresolved = fields.unresolvedContext(uri)
        if unresolved != "":
          result.errors.add(collectionError("cannot determine image identity for named context: " &
                                            unresolved))
          continue
        if uri == "":
          raise newException(ValueError, "COPY image metadata is missing its uri")
        # marks without from_stage identify stage copies by name or index
        if "named_context" notin fields and (frm in baseAliases or
            (frm.allCharsInSet(Digits) and uri in baseUris)):
          continue
        let image = parseImage(uri, defaultTag = "")
        var digests: seq[string]
        digests.addDigest(image.digest)
        let source =
          if metadataBool(fields.getOrDefault("mount", pack(false))): "mount_from"
          else: "copy_from"
        result.subjects.add(PolicySubject(image: image, raw: uri, digests: digests,
                                          stage: alias, source: source))

proc pushInput*(chalk: ChalkObj, name: string): PolicyInput =
  let known = chalk != nil and chalk.extract != nil and "DOCKER_BASE_IMAGES" in chalk.extract
  if not known:
    result.errors.add(collectionError("image is not chalked so its base images are unknown", name))
    return
  try:
    result = chalk.pushSubjects()
    for e in result.errors.mitems():
      e.image = name
    # Older marks omitted COPY images supplied through named contexts. Do not
    # silently pass such an incomplete mark; new marks record these references.
    if "DOCKER_ADDITIONAL_CONTEXTS" in chalk.extract:
      let contexts = metadataTable(chalk.extract["DOCKER_ADDITIONAL_CONTEXTS"])
      let bases = metadataTable(chalk.extract["DOCKER_BASE_IMAGES"])
      var contextsRecorded = false
      for _, info in bases:
        let fields = metadataTable(info)
        if metadataString(fields.getOrDefault("named_contexts", pack(""))) == "resolved":
          contextsRecorded = true
      if not contextsRecorded:
        for _, value in contexts:
          if metadataString(value).startsWith("docker-image://"):
            result.errors.add(collectionError("image mark predates named context metadata", name))
            break
  except CatchableError:
    result = PolicyInput()
    result.errors.add(collectionError("could not read image policy metadata: " & getCurrentExceptionMsg(), name))
