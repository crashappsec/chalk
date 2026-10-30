import ../../src/podman/types
include ../../src/plugins/codecPodman

template assertEq(a, b: untyped) =
  doAssert a == b, $a & " != " & $b

proc main() =
  let empty = projectPodmanRepos(@[])
  assertEq(len(empty.digests), 0)
  assertEq(len(empty.listDigests), 0)
  assertEq(len(empty.tags), 0)

  let single = projectPodmanRepos(@[
    PodmanPublication(
      reference:   parseImage("alpine:edge", defaultTag = ""),
      imageDigest: "sha256:image-one",
    ),
  ])
  assertEq(single.digests["registry-1.docker.io"]["library/alpine"],
           @["image-one"])
  assertEq(len(single.listDigests), 0)
  assertEq(single.tags["registry-1.docker.io"]["library/alpine"]["edge"],
           "image-one")

  let defaultTag = projectPodmanRepos(@[
    PodmanPublication(
      reference:   parseImage("busybox", defaultTag = "latest"),
      imageDigest: "sha256:image-latest",
    ),
  ])
  assertEq(defaultTag.tags["registry-1.docker.io"]["library/busybox"]["latest"],
           "image-latest")

  let digestOnly = projectPodmanRepos(@[
    PodmanPublication(
      reference: parseImage("registry.example/team/app@sha256:pinned",
                            defaultTag = ""),
      imageDigest: "sha256:pinned",
    ),
  ])
  assertEq(digestOnly.digests["registry.example"]["team/app"], @["pinned"])
  assertEq(len(digestOnly.tags), 0)

  let indexed = projectPodmanRepos(@[
    PodmanPublication(
      reference:   parseImage("docker.io/library/alpine:latest",
                              defaultTag = ""),
      imageDigest: "sha256:image-two",
      listDigest:  "sha256:index-two",
    ),
  ])
  assertEq(indexed.digests["registry-1.docker.io"]["library/alpine"],
           @["image-two"])
  assertEq(indexed.listDigests["registry-1.docker.io"]["library/alpine"],
           @["index-two"])
  assertEq(indexed.tags["registry-1.docker.io"]["library/alpine"]["latest"],
           "index-two")

  let distinctTags = projectPodmanRepos(@[
    PodmanPublication(
      reference:   parseImage("registry.example/team/app:first",
                              defaultTag = ""),
      imageDigest: "sha256:first-image",
    ),
    PodmanPublication(
      reference:   parseImage("registry.example/team/app:second",
                              defaultTag = ""),
      imageDigest: "sha256:second-image",
    ),
  ])
  assertEq(distinctTags.digests["registry.example"]["team/app"],
           @["first-image", "second-image"])
  assertEq(distinctTags.tags["registry.example"]["team/app"]["first"],
           "first-image")
  assertEq(distinctTags.tags["registry.example"]["team/app"]["second"],
           "second-image")

  subscribedKeys = Table[string, bool]()
  for key in [
    "_OP_ARTIFACT_TYPE",
    "PODMAN_IMAGE_ID",
    "_REPO_DIGESTS",
    "_REPO_LIST_DIGESTS",
    "_REPO_TAGS",
  ]:
    subscribedKeys[key] = true
  let
    chalk = ChalkObj(
      imageId: "sha256:local-image",
      cache: RootRef(PodmanArtifactCache(publications: @[
        PodmanPublication(
          reference:   parseImage("registry.example/team/app:published",
                                  defaultTag = ""),
          imageDigest: "sha256:published-image",
          listDigest:  "sha256:published-index",
        ),
      ])),
    )
    reported = podmanGetRunTimeArtifactInfo(Plugin(nil), chalk, false)
  assertEq(unpack[string](reported["_OP_ARTIFACT_TYPE"]), "Podman Image")
  assertEq(unpack[string](reported["PODMAN_IMAGE_ID"]), "sha256:local-image")
  for key in ["_REPO_DIGESTS", "_REPO_LIST_DIGESTS", "_REPO_TAGS"]:
    doAssert key in reported

  subscribedKeys = Table[string, bool]()
  subscribedKeys["PODMAN_IMAGE_ID"] = true
  let excluded = podmanGetRunTimeArtifactInfo(Plugin(nil), chalk, false)
  assertEq(unpack[string](excluded["PODMAN_IMAGE_ID"]), "sha256:local-image")
  for key in ["_REPO_DIGESTS", "_REPO_LIST_DIGESTS", "_REPO_TAGS"]:
    doAssert key notin excluded

  subscribedKeys = Table[string, bool]()
  for key in ["_REPO_DIGESTS", "_REPO_LIST_DIGESTS", "_REPO_TAGS"]:
    subscribedKeys[key] = true
  let emptyReported = podmanGetRunTimeArtifactInfo(
    Plugin(nil),
    ChalkObj(cache: RootRef(PodmanArtifactCache())),
    false,
  )
  for key in ["_REPO_DIGESTS", "_REPO_LIST_DIGESTS", "_REPO_TAGS"]:
    doAssert key notin emptyReported

main()
