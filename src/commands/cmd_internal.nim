##
## Copyright (c) 2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

import std/[
  base64,
  json,
  os,
  posix,
  sequtils,
  tempfiles,
]
import ".."/[
  attestation_api,
  config,
  docker/exe,
  docker/push,
  plugin_api,
  reporting,
  run_management,
  subscan,
  types,
  utils/exec,
  utils/files,
  utils/json,
  utils/sets,
  utils/strings,
  utils/subproc,
]

const
  dockerodeRegisterSource = staticRead("../dockerode_post_push/register.cjs")
  dockerodeRuntimeSource  = staticRead("../dockerode_post_push/runtime.cjs")

proc runCmdDockerodeRun*() =
  ## Scope instrumentation to one publish command and preserve its exit code.
  var args = getArgs()
  if len(args) > 0 and args[0] == "--":
    args = args[1 .. ^1]
  if len(args) == 0:
    error("dockerode_run: expected -- <command> [args...]")
    quitChalk(64)
  let commandArgs = if len(args) > 1: args[1 .. ^1] else: @[]

  let
    loaderDir  = createTempDir("chalk-dockerode-", "-loader")
    register   = loaderDir / "register.cjs"
    runtime    = loaderDir / "runtime.cjs"
    prior      = getEnv("NODE_OPTIONS")
  discard chmod(cstring(loaderDir), Mode(0o700))
  writeFile(register, dockerodeRegisterSource)
  writeFile(runtime, dockerodeRuntimeSource)
  discard chmod(cstring(register), Mode(0o600))
  discard chmod(cstring(runtime), Mode(0o600))
  putEnv("NODE_OPTIONS", (prior & " --require=\"" & register & "\"").strip())
  putEnv("CHALK_DOCKERODE_CHALK", getMyAppPath())
  if not attrGet[bool]("load_external_config"):
    putEnv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG", "1")

  try:
    quitChalk(runCmdNoOutputCapture(args[0], commandArgs))
  finally:
    try:
      removeDir(loaderDir)
    except:
      warn("dockerode_run: could not remove temporary loader directory")

proc postPushResult(status, operationId: string) =
  stdout.writeLine($( %*{
    "schema":      "chalk-docker-post-push-result/v1",
    "status":      status,
    "operationId": operationId,
  }))

proc runCmdDockerPostPush*() =
  ## Versioned stdin contract for a push already completed by dockerode.
  ## Exit 0: collected; 1: post-processing failed; 2: unsupported input.
  var operationId = ""
  try:
    let payload = parseJson(stdin.readAll())
    if payload.kind != JObject or
       payload{"schema"}.getStr() != "chalk-docker-post-push/v1":
      postPushResult("unsupported_schema", operationId)
      quitChalk(2)

    operationId = payload{"operationId"}.getStr()
    let
      repository = payload{"repository"}.getStr()
      tag         = payload{"tag"}.getStr()
      digest      = payload{"digest"}.getStr()
      socketPath  = payload{"socketPath"}.getStr()
    if operationId == "" or repository == "" or tag == "" or
       not digest.startsWith("sha256:") or digest.len != 71 or
       not digest[7 .. ^1].allCharsInSet({'0' .. '9', 'a' .. 'f'}) or
       '\n' in repository or '\r' in repository or
       '\n' in tag or '\r' in tag or
       socketPath notin ["/var/run/docker.sock", getHomeDir() / ".docker/run/docker.sock"]:
      postPushResult("unsupported_input", operationId)
      quitChalk(2)

    putEnv("DOCKER_HOST", "unix://" & socketPath)
    delEnv("DOCKER_CONTEXT")

    let auth = payload{"authconfig"}
    if auth != nil and auth.kind != JNull:
      let
        username = auth{"username"}.getStr()
        password = auth{"password"}.getStr()
        server   = auth{"serveraddress"}.getStr()
      if username == "" or password == "" or server == "":
        postPushResult("unsupported_auth", operationId)
        quitChalk(2)
      var dockerConfig = %*{"auths": {}}
      dockerConfig["auths"][server] = %*{
        "auth": encode(username & ":" & password),
      }
      setDockerAuthConfig(dockerConfig)

    setFullCommandName("push", msg = "post-processing")
    loadAttestation(forceLoad = true, withPrivateKey = true)
    if not dockerPostPush(repository & ":" & tag, digest):
      postPushResult("digest_mismatch_or_collection_failed", operationId)
      quitChalk(1)
    reporting.doReporting("report")
    postPushResult("complete", operationId)
    quitChalk(0)
  except:
    error("docker post-push: " & getCurrentExceptionMsg())
    postPushResult("failed", operationId)
    quitChalk(1)

proc onbuild() =
  let data = readFile("/chalk.json")
  if not data.startsWith("{"):
    error("onbuild: not valid json in /chalk.json")
    return
  let
    existing = parseJson(data)
    updated  = newJObject()
  updated["EMBEDDED_CHALK"] = %(@[existing])
  if "METADATA_ID" in existing:
    updated["OLD_CHALK_METADATA_ID"]   = existing["METADATA_ID"]
  if "METADATA_HASH" in existing:
    updated["OLD_CHALK_METADATA_HASH"] = existing["METADATA_HASH"]
  writeFile("/chalk.json", $updated)

proc runCmdOnBuild*() =
  try:
    onbuild()
  except:
    error("onbuild: " & getCurrentExceptionMsg())

proc prepPostExec() =
  let
    toScan = attrGet[seq[string]]("exec.postexec.access_watch.scan_paths")
    codecs = attrGet[seq[string]]("exec.postexec.access_watch.scan_codecs")
    tmp    = attrGet[string]("exec.postexec.access_watch.prep_tmp_path")
  var paths = initHashSet[string]()
  withOnlyCodecs(getPluginsByName(codecs)):
    for chalk in runChalkSubScan(toScan, "extract").allChalks:
      paths.incl(chalk.fsRef)
  discard tryToWriteFile(
    tmp,
    paths.toSeq().join("\n"),
  )

proc runCmdPrepPostExec*() =
  try:
    prepPostExec()
  except:
    error("prep_postexec: " & getCurrentExceptionMsg())
