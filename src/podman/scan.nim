##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Recovering a chalk mark from an existing podman image.
##
## The docker path does this through scanImage (src/docker/scan.nim), which
## leans on collectImage/extractImage and ultimately on `docker create` +
## `docker cp`, plus registry manifest fetching. None of that is reusable, so
## this is the podman equivalent of the local-image half: create a container
## without starting it, copy /chalk.json out, discard the container.

import std/[
  sets,
]
import ".."/[
  chalkjson,
  plugin_api,
  run_management,
  types,
  utils/files,
  utils/json,
]
import "../docker"/[
  ids,
  manifest,
]
import "./run"
import "./types" as podman_types

proc imageId*(exe, image: string,
              cancellation: var Option[podman_types.ChildResult]): string =
  ## Config digest of a local image, or "" if it cannot be determined.
  let r = runCaptured(exe, @["image", "inspect", image, "--format", "json"])
  if isCancellation(r.child):
    cancellation = some(r.child)
    return ""
  if r.child.kind != podman_types.ceExited or r.child.exitCode != 0:
    return ""
  try:
    let parsed = parseJson(r.stdout)
    if parsed.kind != JArray or len(parsed) == 0:
      return ""
    return parsed[0]{"Id"}.getStr()
  except:
    return ""

proc extractImageMark*(exe, image: string,
                       cancellation: var Option[podman_types.ChildResult]):
                      Option[string] =
  ## Text of /chalk.json inside an image, without running it.
  ##
  ## `podman create` makes a container but never starts it, so this works on
  ## images whose entrypoint could not run here -- including ones with no shell
  ## at all. none() means the image carries no mark, which is not an error.
  let created = runCaptured(exe, @["create", image])
  if isCancellation(created.child):
    cancellation = some(created.child)
    return none(string)
  if created.child.kind != podman_types.ceExited or created.child.exitCode != 0:
    trace("podman: could not create container from " & image &
          " to read its mark: " & created.stderr.strip())
    return none(string)
  let containerId = created.stdout.strip()
  if containerId == "":
    return none(string)

  try:
    let (markStream, markTmp) = getNewTempFile(suffix = "chalk.json")
    markStream.close()  # release the fd so podman can write to it
    let copied = runCaptured(exe, @["cp", containerId & ":/chalk.json", markTmp])
    if isCancellation(copied.child):
      cancellation = some(copied.child)
      return none(string)
    if copied.child.kind != podman_types.ceExited or copied.child.exitCode != 0:
      # An unmarked image is the common case here, not a failure.
      trace("podman: " & image & ": no /chalk.json (" &
            copied.stderr.strip() & ")")
      return none(string)
    let mark = tryToLoadFile(markTmp)
    if mark == "":
      return none(string)
    return some(mark)
  finally:
    let removed = runCaptured(exe, @["rm", "--force", containerId])
    if removed.child.kind != podman_types.ceExited or removed.child.exitCode != 0:
      trace("podman: could not remove scratch container " & containerId)

proc collectRepos*(exe, image: string, chalk: ChalkObj,
                   cancellation: var Option[podman_types.ChildResult]) =
  ## Populate chalk.repos from the image's registry references.
  ##
  ## This is what makes attestation reachable. canVerifyBySigStore requires
  ## len(chalk.repos) > 0, and signBySigStore iterates chalk.repos.manifests to
  ## decide what to sign -- with repos empty the attestation plugin skips
  ## signing silently and a pushed image carries no signature.
  ##
  ## Digests come from the REGISTRY, not from podman's local RepoDigests, for
  ## the same reason docker/collect.nim fetches manifests: the two disagree.
  ## Verified against a local registry -- podman recorded
  ## sha256:3735273c... for an image the registry serves as sha256:c4e96fce...,
  ## and signing the locally recorded digest fails with "not found" because no
  ## such manifest exists there. Only the registry can say what was actually
  ## stored.
  ##
  ## podman's RepoTags is still the right way to learn WHICH references exist;
  ## it is only the digests that cannot be trusted.
  let r = runCaptured(exe, @["image", "inspect", image, "--format", "json"])
  if isCancellation(r.child):
    cancellation = some(r.child)
    return
  if r.child.kind != podman_types.ceExited or r.child.exitCode != 0:
    return

  var refs: seq[string]
  try:
    let parsed = parseJson(r.stdout)
    if parsed.kind != JArray or len(parsed) == 0:
      return
    for item in parsed[0]{"RepoTags"}.getElems():
      let name = item.getStr()
      if name != "" and name notin refs:
        refs.add(name)
  except:
    trace("podman: could not read registry references for " & image & ": " &
          getCurrentExceptionMsg())
    return

  for name in refs:
    let parsedRef = parseImage(name, defaultTag = "")
    if parsedRef.repo == "" or parsedRef.tag == "":
      continue
    try:
      let
        # asImageRepo needs only the manifest digest, so the config blob is
        # not fetched -- it is a separate round trip and an extra failure mode.
        fetched   = fetchImageManifest(parsedRef, DockerPlatform(nil),
                                       ifManySystemPlatform = true,
                                       fetchConfig          = false)
        imageRepo = fetched.asImageRepo(tags = @[parsedRef.tag])
      chalk.repos[parsedRef.repo] =
        imageRepo + chalk.repos.getOrDefault(parsedRef.repo)
    except:
      # Not published yet, unreachable registry, or auth we do not have. Not
      # an error: there is simply nothing there to attest against.
      trace("podman: could not fetch manifest for " & name & ": " &
            getCurrentExceptionMsg())

  if len(chalk.repos) == 0:
    trace("podman: " & image &
          " has no reachable registry manifests; nothing to attest")

proc scanPodmanImage*(exe, image: string,
                      cancellation: var Option[podman_types.ChildResult]):
                     Option[ChalkObj] =
  ## Build a ChalkObj for a local image, carrying its mark when it has one.
  ##
  ## No chalkId is supplied: the podman codec derives it from the extracted
  ## mark, so scanning must not mint a new identity for an existing artifact.
  let id = imageId(exe, image, cancellation)
  if cancellation.isSome():
    return none(ChalkObj)
  if id == "":
    return none(ChalkObj)

  let chalk = newChalk(
    name         = image,
    resourceType = {ResourceImage},
    codec        = getPluginByName("podman"),
    imageId      = id,
  )
  chalk.cachedEndingHash = id

  let mark = extractImageMark(exe, image, cancellation)
  if cancellation.isSome():
    return none(ChalkObj)
  if mark.isSome():
    try:
      let extracted = extractOneChalkJson(mark.get(), image)
      chalk.collectedData.update(extracted)
      chalk.extract    = extracted
      chalk.cachedMark = mark.get()
      chalk.marked     = true
    except:
      warn("podman: could not parse chalk mark from " & image & ": " &
           getCurrentExceptionMsg())
      addUnmarked(image)
  else:
    addUnmarked(image)

  return some(chalk)
