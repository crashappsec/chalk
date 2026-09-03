##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/os
import ../utils/files

when getEnv("CHALK_TYPESCRIPT_BUILT") != "1":
  {.fatal: "Dockerode TypeScript artifacts are unavailable or stale; run `make` (or `make transpile`) instead of `nimble build`.".}

type DockerodeAsset* = object
  relativePath*: string
  contents*: string

const
  dockerodePreloadRelativePath* = "register.cjs"
  dockerodeAssets*: array[4, DockerodeAsset] = [
    DockerodeAsset(
      relativePath: dockerodePreloadRelativePath,
      contents: staticRead("../../build/src/dockerode_post_push/register.cjs"),
    ),
    DockerodeAsset(
      relativePath: "register_impl.cjs",
      contents: staticRead("../../build/src/dockerode_post_push/register_impl.cjs"),
    ),
    DockerodeAsset(
      relativePath: "runtime.cjs",
      contents: staticRead("../../build/src/dockerode_post_push/runtime.cjs"),
    ),
    DockerodeAsset(
      relativePath: "node_support.cjs",
      contents: staticRead("../../build/src/dockerode_post_push/node_support.cjs"),
    ),
  ]

proc writeDockerodeAssets*(directory, fileMode: string): string =
  for asset in dockerodeAssets:
    let path = directory / asset.relativePath
    writeFile(path, asset.contents)
    discard chmodFilePermissions(path, fileMode)
  result = directory / dockerodePreloadRelativePath
