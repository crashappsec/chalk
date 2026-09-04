##
## Copyright (c) 2026, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  json,
  os,
  sets,
  strutils,
  tempfiles,
]
import ../utils/[
  file_string_stream,
  files,
]
import ./assets

const
  PolicyManifestSchema = "chalk-dockerode-policy/v1"
  PolicyBinaryName = "chalk"
  PolicyActivationName = "activate.sh"
  PolicyManifestName = "manifest.json"

type
  PolicyFile = object
    relativePath: string
    sha256: string
    permissions: string

proc sha256(data: string): string =
  newLoadedFileStringStream(data).sha256Hex()

proc requireUnsymLinked(path: string) =
  var current = path
  while current != "":
    if symlinkExists(current):
      raise newException(ValueError, "policy path must not contain symlinks: " & current)
    let parent = current.parentDir()
    if parent == current:
      break
    current = parent

proc requireDirectory(path, permissions: string, create: bool) =
  path.requireUnsymLinked()
  if fileExists(path) and not dirExists(path):
    raise newException(ValueError, "policy path is not a directory: " & path)
  if not dirExists(path):
    if not create:
      raise newException(ValueError, "policy directory is missing: " & path)
    createDir(path)
    setFilePermissions(path, chmodPermissions(permissions))
  if getFilePermissions(path) != chmodPermissions(permissions):
    raise newException(ValueError, "policy directory has invalid permissions: " & path)

proc shellQuote(value: string): string =
  "'" & value.replace("'", "'\"'\"'") & "'"

proc activation(root, release: string): string =
  let
    preload = release / "loader" / dockerodePreloadRelativePath
    binary = release / PolicyBinaryName
    diagnostics = root / "dockerode-diagnostics.jsonl"
  @[
    "#!/bin/sh",
    "chalk_dockerode_preload=" & preload.shellQuote(),
    "case \"${NODE_OPTIONS-}\" in",
    "  *\"--require=\\\"$chalk_dockerode_preload\\\"\"*) ;;",
    "  *) NODE_OPTIONS=\"${NODE_OPTIONS:+$NODE_OPTIONS }--require=\\\"$chalk_dockerode_preload\\\"\" ;;",
    "esac",
    "export NODE_OPTIONS",
    "export CHALK_DOCKERODE_CHALK=" & binary.shellQuote(),
    "export CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS=300000",
    "export CHALK_DOCKERODE_LOG=" & diagnostics.shellQuote(),
    "unset chalk_dockerode_preload",
    "",
  ].join("\n")

proc manifest(files: openArray[PolicyFile]): JsonNode =
  result = newJObject()
  result["schema"] = %PolicyManifestSchema
  result["files"] = newJArray()
  for file in files:
    result["files"].add(%*{
      "path": file.relativePath,
      "sha256": file.sha256,
      "permissions": file.permissions,
    })

proc expectedFiles(binaryPath, activationContents: string): seq[PolicyFile] =
  result.add(PolicyFile(
    relativePath: PolicyBinaryName,
    sha256: newFileStringStream(binaryPath).sha256Hex(),
    permissions: "0555",
  ))
  for asset in dockerodeAssets:
    result.add(PolicyFile(
      relativePath: "loader" / asset.relativePath,
      sha256: asset.contents.sha256(),
      permissions: "0444",
    ))
  result.add(PolicyFile(
    relativePath: PolicyActivationName,
    sha256: activationContents.sha256(),
    permissions: "0444",
  ))

proc verifyPolicyRelease(release: string, expected: openArray[PolicyFile]) =
  release.requireDirectory("0555", create = false)
  (release / "loader").requireDirectory("0555", create = false)
  var expectedPaths = initHashSet[string]()
  for file in expected:
    let path = release / file.relativePath
    expectedPaths.incl(path)
    path.requireUnsymLinked()
    if not fileExists(path) or dirExists(path):
      raise newException(ValueError, "policy file is missing: " & path)
    if getFilePermissions(path) != chmodPermissions(file.permissions):
      raise newException(ValueError, "policy file has invalid permissions: " & path)
    if newFileStringStream(path).sha256Hex() != file.sha256:
      raise newException(ValueError, "policy file hash mismatch: " & path)

  let manifestPath = release / PolicyManifestName
  expectedPaths.incl(manifestPath)
  manifestPath.requireUnsymLinked()
  if not fileExists(manifestPath) or
     getFilePermissions(manifestPath) != chmodPermissions("0444"):
    raise newException(ValueError, "policy manifest is missing or has invalid permissions")
  if parseJson(readFile(manifestPath)) != manifest(expected):
    raise newException(ValueError, "policy manifest does not match the installed files")

  var actualPaths = initHashSet[string]()
  for path in walkDirRec(release):
    path.requireUnsymLinked()
    actualPaths.incl(path)
  if actualPaths != expectedPaths:
    raise newException(ValueError, "policy release contains unexpected or incomplete assets")

proc ensureDiagnosticFile(root: string) =
  let path = root / "dockerode-diagnostics.jsonl"
  path.requireUnsymLinked()
  if not fileExists(path):
    writeFile(path, "")
    setFilePermissions(path, chmodPermissions("0600"))
  if dirExists(path) or getFilePermissions(path) != chmodPermissions("0600"):
    raise newException(ValueError, "policy diagnostic file has invalid permissions")

proc installDockerodePolicy*(root, binaryPath: string): string =
  if not root.isAbsolute():
    raise newException(ValueError, "policy root must be an absolute path")
  root.requireDirectory("0711", create = true)
  root.ensureDiagnosticFile()
  let releases = root / "releases"
  releases.requireDirectory("0711", create = true)

  let
    binaryHash = newFileStringStream(binaryPath).sha256Hex()
    release = releases / binaryHash
    activationContents = activation(root, release)
    files = expectedFiles(binaryPath, activationContents)
  if dirExists(release) or fileExists(release) or symlinkExists(release):
    release.verifyPolicyRelease(files)
    return release / PolicyActivationName

  let staging = createTempDir(".staging-", "", releases)
  try:
    setFilePermissions(staging, chmodPermissions("0700"))
    createDir(staging / "loader")
    setFilePermissions(staging / "loader", chmodPermissions("0700"))
    copyFile(binaryPath, staging / PolicyBinaryName)
    setFilePermissions(staging / PolicyBinaryName, chmodPermissions("0555"))
    discard writeDockerodeAssets(staging / "loader", "0444")
    writeFile(staging / PolicyActivationName, activationContents)
    setFilePermissions(staging / PolicyActivationName, chmodPermissions("0444"))
    writeFile(staging / PolicyManifestName, $manifest(files) & "\n")
    setFilePermissions(staging / PolicyManifestName, chmodPermissions("0444"))
    setFilePermissions(staging / "loader", chmodPermissions("0555"))
    setFilePermissions(staging, chmodPermissions("0555"))
    moveDir(staging, release)
  except:
    if dirExists(staging):
      removeDir(staging)
    raise

  release.verifyPolicyRelease(files)
  return release / PolicyActivationName
