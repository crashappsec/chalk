##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/tables
import ".."/[
  plugin_api,
  run_management,
  types,
]
import "../docker"/ids
import "../podman"/types as podman_types

type
  PodmanRepoDigests* =
    OrderedTableRef[string, OrderedTableRef[string, seq[string]]]
  PodmanRepoTags* = OrderedTableRef[
    string,
    OrderedTableRef[string, OrderedTableRef[string, string]],
  ]
  PodmanRepoProjection* = object
    digests*:     PodmanRepoDigests
    listDigests*: PodmanRepoDigests
    tags*:        PodmanRepoTags

proc addDigest(items: PodmanRepoDigests, registry, repository,
               digest: string) =
  if digest == "":
    return
  discard items.hasKeyOrPut(
    registry,
    newOrderedTable[string, seq[string]](),
  )
  discard items[registry].hasKeyOrPut(repository, @[])
  if digest notin items[registry][repository]:
    items[registry][repository].add(digest)

proc projectPodmanRepos*(publications: openArray[podman_types.PodmanPublication]):
                         PodmanRepoProjection =
  ## Project fetched Podman publications into the existing repository field
  ## shapes. Digests use the fields' algorithm-free convention.
  result = PodmanRepoProjection(
    digests:     newOrderedTable[string, OrderedTableRef[string, seq[string]]](),
    listDigests: newOrderedTable[string, OrderedTableRef[string, seq[string]]](),
    tags:        newOrderedTable[
      string,
      OrderedTableRef[string, OrderedTableRef[string, string]],
    ](),
  )
  for publication in publications:
    let
      reference   = publication.reference.normalize()
      registry    = reference.registry
      repository  = reference.name
      imageDigest = publication.imageDigest.extractDockerHash()
      listDigest  = publication.listDigest.extractDockerHash()
    if registry == "" or repository == "":
      continue

    result.digests.addDigest(registry, repository, imageDigest)
    result.listDigests.addDigest(registry, repository, listDigest)

    let tagDigest =
      if listDigest != "": listDigest
      else:                imageDigest
    if reference.tag == "" or tagDigest == "":
      continue
    discard result.tags.hasKeyOrPut(
      registry,
      newOrderedTable[string, OrderedTableRef[string, string]](),
    )
    discard result.tags[registry].hasKeyOrPut(
      repository,
      newOrderedTable[string, string](),
    )
    result.tags[registry][repository][reference.tag] = tagDigest

proc podmanGetChalkId(self: Plugin, chalk: ChalkObj): string {.cdecl.} =
  if chalk.extract != nil and "CHALK_ID" in chalk.extract:
    return unpack[string](chalk.extract["CHALK_ID"])
  var
    bytes  = secureRand[array[32, char]]()
    preRes = newStringOfCap(32)
  for ch in bytes:
    preRes.add(ch)
  return preRes.idFormat()

proc podmanGetRunTimeArtifactInfo(self: Plugin, chalk: ChalkObj, ins: bool):
                                 ChalkDict {.cdecl.} =
  result = ChalkDict()
  result.setIfNeeded("_OP_ARTIFACT_TYPE", artTypePodmanImage)
  if chalk.imageId != "":
    result.setIfNeeded("PODMAN_IMAGE_ID", chalk.imageId)
  if chalk.cache != nil:
    let projection = projectPodmanRepos(
      podman_types.PodmanArtifactCache(chalk.cache).publications,
    )
    result.setIfNeeded("_REPO_DIGESTS", projection.digests)
    result.setIfNeeded("_REPO_LIST_DIGESTS", projection.listDigests)
    result.setIfNeeded("_REPO_TAGS", projection.tags)

proc podmanWrite(self: Plugin, chalk: ChalkObj, enc: Option[string]) {.cdecl.} =
  discard

proc loadCodecPodman*() =
  newCodec("podman",
           rtArtCallback = RunTimeArtifactCb(podmanGetRunTimeArtifactInfo),
           getChalkId    = ChalkIdCb(podmanGetChalkId),
           handleWrite   = HandleWriteCb(podmanWrite),
           enabled       = true)
