##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Common docker-specific utility bits used in various parts of the
## implementation.

import std/[httpclient, uri]
import "."/[config, dockerfile, util, reporting, semver, wwwAuthenticate]

var
  buildXVersion: Version = parseVersion("0")
  dockerVersion: Version = parseVersion("0")

const
  hashHeader* = "sha256:"

var dockerPathOpt: Option[string] = none(string)

template extractDockerHash*(value: string): string =
  if not value.startsWith(hashHeader):
    value
  else:
    value[len(hashHeader) .. ^1]

template extractBoxedDockerHash*(value: Box): Box =
  pack(extractDockerHash(unpack[string](value)))

proc setDockerExeLocation*() =
  once:
    trace("Searching PATH for 'docker'")
    let
      dockerConfigPath = chalkConfig.getDockerExe()
      dockerExeOpt     = findExePath("docker",
                                     configPath = dockerConfigPath,
                                     ignoreChalkExes = true)
    dockerExeLocation = dockerExeOpt.get("")
    if dockerExeLocation == "":
       warn("No docker command found in PATH. `chalk docker` not available.")

proc runDockerGetEverything*(args: seq[string], stdin = "", silent = true): ExecOutput =
  if not silent:
    trace("Running docker: " & dockerExeLocation & " " & args.join(" "))
    if stdin != "":
      trace("Passing on stdin: \n" & stdin)
  result = runCmdGetEverything(dockerExeLocation, args, stdin)
  if not silent and result.exitCode > 0:
    trace(strutils.strip(result.stderr & result.stdout))
  return result

proc getVersionFromLine(line: string): Version =
  for word in line.splitWhitespace():
    if '.' in word:
      try:
        return parseVersion(word)
      except:
        # word wasnt a version number
        discard
  raise newException(ValueError, "no version found")

proc getBuildXVersion*(): Version =
  # Have to parse the thing to get compares right.
  once:
    if getEnv("DOCKER_BUILDKIT") == "0":
      return buildXVersion

    # examples:
    # github.com/docker/buildx v0.10.2 00ed17df6d20f3ca4553d45789264cdb78506e5f
    # github.com/docker/buildx 0.11.2 9872040b6626fb7d87ef7296fd5b832e8cc2ad17
    let version = runDockerGetEverything(@["buildx", "version"])
    if version.exitCode == 0:
      try:
        buildXVersion = getVersionFromLine(version.stdOut)
        trace("Docker buildx version: " & $(buildXVersion))
      except:
        dumpExOnDebug()

  return buildXVersion

proc getDockerVersion*(): Version =
  once:
    # examples:
    # Docker version 1.13.0, build 49bf474
    # Docker version 23.0.0, build e92dd87
    # Docker version 24.0.6, build ed223bc820
    let version = runDockerGetEverything(@["--version"])
    if version.exitCode == 0:
      try:
        dockerVersion = getVersionFromLine(version.stdOut)
        trace("Docker version: " & $(dockerVersion))
      except:
        dumpExOnDebug()

  return dockerVersion

template hasBuildx*(): bool =
  getBuildXVersion() > parseVersion("0")

template supportsBuildContextFlag*(): bool =
  # https://github.com/docker/buildx/releases/tag/v0.8.0
  getDockerVersion() >= parseVersion("21") and getBuildXVersion() >= parseVersion("0.8")

template supportsCopyChmod*(): bool =
  # > the --chmod option requires BuildKit.
  # > Refer to https://docs.docker.com/go/buildkit/ to learn how to
  # > build images with BuildKit enabled
  hasBuildx()

proc dockerFailsafe*(info: DockerInvocation) {.cdecl, exportc.} =
  # If our mundged docker invocation fails, then we conservatively
  # assume we made some big mistake, and run Docker the way it
  # was originally called.

  var newStdin = "" # Passthrough; either nothing or a build context

  # Here, a docker file was passed on stdin, and we have already
  # read it, so we need to put it back on stdin.
  if info.dockerFileLoc == ":stdin:":
    newStdin = info.inDockerFile

  let exitCode = runCmdNoOutputCapture(dockerExeLocation,
                                        info.originalArgs,
                                        newStdin)
  doReporting("fail")
  quitChalk(exitCode)

var contextCounter = 0

proc makeFileAvailableToDocker*(ctx:     DockerInvocation,
                                inLoc:   string,
                                move:    bool,
                                chmod:   string = "",
                                newName: string) =
  var
    loc           = inLoc.resolvePath()
    chmod         = chmod

  let
    (dir, file)   = loc.splitPath()
    userDirective = ctx.dfSections[^1].lastUser
    hasUser       = userDirective != nil

  # if USER directive is present and --chmod is not requested
  # default container user will not have access to the copied file
  # hence we default permission to read-only for all users
  if hasUser and chmod == "":
    chmod = "0444"

  let chmodstr = if chmod == "": "" else: "--chmod=" & chmod & " "

  if move:
    trace("Making file available to docker via move: " & loc)
  else:
    trace("Making file available to docker via copy: " & loc)

  if supportsBuildContextFlag():
    once:
      trace("Docker injection method: --build-context")

    ctx.newCmdLine.add("--build-context")
    ctx.newCmdLine.add("chalkexedir" & $(contextCounter) & "=" & dir & "")
    ctx.addedInstructions.add("COPY " & chmodstr & "--from=chalkexedir" &
      $(contextCounter) & " " & file & " /" & newname)
    contextCounter += 1
    if move:
      registerTempFile(loc)

  elif ctx.foundContext == "-":
    warn("Cannot chalk when context is passed to stdin w/o BUILDKIT support")
    raise newException(ValueError, "stdinctx")

  else:
    once:
      trace("Docker injection method: COPY")

    var
      contextDir  = ctx.foundContext.resolvePath()
      dstLoc      = contextDir.joinPath(file)

    trace("Context directory is: " & contextDir)
    if not dirExists(contextDir):
      warn("Cannot find context directory (" & contextDir &
        "), so cannot wrap entry point.")
      raise newException(ValueError, "ctxwrite")

    try:
      if move:
        moveFile(loc, dstLoc)
        trace("Moved " & loc & " to " & dstLoc)
      else:
        while fileExists(dstLoc):
          dstLoc &= ".tmp"
        copyFile(loc, dstLoc)
        trace("Copied " & loc & " to " & dstLoc)

      if chmodstr != "" and supportsCopyChmod():
        ctx.addedInstructions.add("COPY " & chmodstr &
                                  file & " " & " /" & newname)
      elif chmod != "":
        # TODO detect user from base image if possible but thats not
        # trivial as what is a base image is not a trivial question
        # due to multi-stage build possibilities...
        if hasUser:
          ctx.addedInstructions.add("USER root")
        ctx.addedInstructions.add("COPY " & file & " " & " /" & newname)
        ctx.addedInstructions.add("RUN chmod " & chmod & " /" & newname)
        if hasUser:
          ctx.addedInstructions.add("USER " & userDirective.str)
      else:
        ctx.addedInstructions.add("COPY " & file & " " & " /" & newname)
      registerTempFile(dstLoc)

    except:
      dumpExOnDebug()
      warn("Could not write to context directory.")
      raise newException(ValueError, "ctxcpy")

proc chooseNewTag*(): string =
  let
    randInt = secureRand[uint]()
    hexVal  = toHex(randInt and 0xffffffffffff'u).toLowerAscii()

  return "chalk-" & hexVal & ":latest"

proc parseTag*(tag: string): (string, string) =
  # parseUri requires some scheme to parse url correctly so we add dummy https
  # parsed uri will allow us to figure out if tag contains version
  # (note that tag can be full registry path which can include
  # port in the hostname)
  let uri = parseUri("https://" & tag)
  if ":" in uri.path:
    let
      tagParts = tag.rsplit(":", maxsplit = 1)
      name     = tagParts[0]
      version  = tagParts[1]
    return (name, version)
  else:
    return (tag, "latest")

proc getAllDockerContexts*(info: DockerInvocation): seq[string] =
  if info.gitContext != nil:
    result.add(info.gitContext.tmpGitDir)
  else:
    if info.foundContext != "" and info.foundContext != "-":
      result.add(resolvePath(info.foundContext))

  for k, v in info.otherContexts:
    result.add(resolvePath(v))

proc getDefaultBuildPlatforms*(ctx: DockerInvocation): Table[string, string] =
  ## probe for default build target/build platforms
  ## this is needed to be able to correctly eval Dockerfile as these
  ## platforms will be prepopulated in buildx
  ## or we can use this to figure out default system target platform
  ## as this uses docker build to probe.
  ## Without probe well need to account for all the docker configs/env vars
  ## to correctly guage default build platform.
  if len(ctx.defaultPlatforms) > 0:
    return ctx.defaultPlatforms

  result = initTable[string, string]()

  let
    tmpTag     = chooseNewTag()
    envVars    = @[setEnv("DOCKER_BUILDKIT", "1")]
    probeFile  = """
FROM busybox
ARG BUILDPLATFORM
ARG TARGETPLATFORM
RUN echo "{\"BUILDPLATFORM\": \"$BUILDPLATFORM\", \"TARGETPLATFORM\": \"$TARGETPLATFORM\"}" > /platforms.json
CMD cat /platforms.json
"""

  var data = ""

  try:
    withEnvRestore(envVars):
      let build  = runDockerGetEverything(@["build", "-t", tmpTag, "-f", "-", "."],
                                          probeFile)
      if build.getExit() != 0:
        warn("Could not probe docker build platforms: " & build.stdErr)
        return result

    let probe = runDockerGetEverything(@["run", "--rm", tmpTag])
    if probe.getExit() != 0:
      warn("Could not probe docker build platforms: " & probe.stdErr)
      return result

    data = probe.stdOut
    trace("Probing for docker build platforms: " & data)

  finally:
    discard runDockerGetEverything(@["rmi", tmpTag])

  if data == "":
    warn("Could not probe docker build platforms. Got empty output")
    return result

  let json = parseJson(data)
  for k, v in json.pairs():
    let value = v.getStr()
    if value == "":
      warn("Could not probe docker build platforms. Got empty value for: " & k)
      return result
    else:
      result[k] = value

  ctx.defaultPlatforms = result

proc getBuildTargetPlatform*(ctx: DockerInvocation): string =
  ## get target build platform for the specific build
  if ctx.foundPlatform != "":
    return ctx.foundPlatform
  let platforms = ctx.getDefaultBuildPlatforms()
  return platforms.getOrDefault("TARGETPLATFORM", "")

proc getAllBuildArgs*(ctx: DockerInvocation): Table[string, string] =
  ## get all build args (manually passed ones and system defaults)
  ## docker automatically assings some args for buildx build
  ## so we add them to the manually passed args which is necessary
  ## to correctly eval dockerfile to potentially resolve base image
  result = initTable[string, string]()
  for k, v in ctx.buildArgs:
    result[k] = v
  for k, v in ctx.getDefaultBuildPlatforms():
    result[k] = v
  let platform = ctx.getBuildTargetPlatform()
  if platform != "":
    result["TARGETPLATFORM"] = platform

proc inspectImageConfig*(image: string, platform: string = ""): JsonNode =
  ## fetch image config from local docker cache (if present)
  ## image config will include information about image cmd/entrypoint/etc
  trace("docker: inspecting image " & image)
  let output = runDockerGetEverything(@["inspect", image, "--format", "json"])
  if output.getExit() != 0:
    return nil
  let
    stdout     = output.getStdout().strip()
    json       = parseJson(stdout)
  if len(json) == 0:
    return nil
  let
    data     = json[0]
    os       = data{"Os"}.getStr()
    arch     = data{"Architecture"}.getStr()
    together = os & "/" & arch
    config   = data{"Config"}
  if platform != "" and platform != together:
    trace("docker: local image " & image & " doesn't match targeted platform: " &
          together & " != " & platform)
    return nil
  return config

proc fetchImageRawManifestData*(image: string): string =
  ## fetch raw json manifest via docker imagetools
  ## however if that fails withs 401 error, attept to manually
  ## fetch the manifest via the URL from the error message
  ## as the error could be due to www-authenticate chellenge
  let msg = "docker: fetching image manifest for " & image
  trace(msg)
  let
    output = runDockerGetEverything(@["buildx", "imagetools", "inspect", image, "--raw"])
    stdout = output.getStdout()
    stderr = output.getStderr()
    text   = stdout & stderr
  if output.getExit() == 0:
    return stdout
  # sample output:
  # ERROR: unexpected status from HEAD request to https://<registry>: 401 Unauthorized
  if "401 Unauthorized" notin stderr:
    error(msg & " failed with: " & text)
    return ""
  if not ("http://" in stderr or "https://" in stderr):
    error(msg & " auth failed without an URL: " & text)
    return ""
  let words = stderr.split()
  var url   = ""
  for word in words:
    if word.startsWith("http://") or word.startsWith("https://"):
      url = word.strip(leading = false, chars = {':'})
      break
  if url == "":
    error(msg & " failed to find auth chellenge URL: " & text)
    return ""
  trace(msg & " requires auth. fetching www-authenticate chellenge from: " & url)
  let headChellenge = safeRequest(url, httpMethod = HttpHead)
  if headChellenge.code() != Http401:
    error(msg & " failed to get 401 for: " & url)
    return ""
  if not headChellenge.headers.hasKey("www-authenticate"):
    error(msg & " www-authenticate header is not returned by: " & url)
    return ""
  try:
    let
      wwwAuthenticate = headChellenge.headers["www-authenticate"]
      chellenges      = parseAuthChellenges(wwwAuthenticate)
      headers         = chellenges.elicitHeaders()
    trace(msg & " from URL: " & url)
    let response      = safeRequest(url, headers = headers)
    if not response.code().is2xx():
      error(msg & " manifest was not returned from URL: " & response.status)
      return ""
    return response.body()
  except:
    error(msg & " failed to fetch manifest via www-authenticate chellenge: " &
          getCurrentExceptionMsg())
    return ""

proc fetchImageRawManifest*(image: string): JsonNode =
  ## fetch raw json manifest from registry
  let manifest = fetchImageRawManifestData(image)
  if manifest == "":
    return nil
  result = parseJson(manifest)

proc fetchImageConfig*(image: string, platform: string): JsonNode =
  ## fetch image config directly from the registry
  ## image config will include information about image cmd/entrypoint/etc
  let name = image.split(":")[0].split("@")[0]
  # keep in mind that image can be of multiple formats
  # foo                   # image manifest name
  # foo:tag               # manifest for specific tag
  # foo@sha256:<checksum> # pinned to specific digest
  # therefore we gracefully handle each possibility
  var json = fetchImageRawManifest(image)
  if json == nil:
    return nil
  # when its a manifest list, find the image within the manifest
  if "manifests" in json:
    trace("docker: " & image & " is a manifest list. looking for image manifest for " & platform)
    for manifest in json["manifests"].items():
      if "platform" in manifest:
        let
          digest    = manifest{"digest"}.getStr()
          mPlatform = manifest["platform"]
          os        = mPlatform{"os"}.getStr()
          arch      = mPlatform{"architecture"}.getStr()
          together  = os & "/" & arch
        if platform == together:
          json = fetchImageRawManifest(name & "@" & digest)
          if json == nil:
            return
          break
  if "layers" in json:
    trace("docker: found image manifest. looking for image config")
    let
      config = json{"config"}
      digest = config{"digest"}.getStr()
    json = fetchImageRawManifest(name & "@" & digest)
    if json == nil:
      return nil
  if "config" notin json or "architecture" notin json or "os" notin json:
    return nil
  let
    config   = json{"config"}
    os       = json{"os"}.getStr()
    arch     = json{"architecture"}.getStr()
    together = os & "/" & arch
  if platform != together:
    error("docker: remote image " & image & " doesn't match targeted platform: " &
          together & " != " & platform)
    return nil
  return config

proc fetchImageEntrypoint*(info: DockerInvocation, image: string):
    tuple[entrypoint: EntrypointInfo, cmd: CmdInfo, shell: ShellInfo] =
  ## fetch image entrypoints (entrypoint/cmd/shell)
  ## fetches from local docker cache (if present),
  ## else will directly query registry
  let platform  = info.getBuildTargetPlatform()
  var imageInfo = inspectImageConfig(image, platform)
  if imageInfo == nil:
    imageInfo = fetchImageConfig(image, platform)
  if imageInfo == nil:
    raise newException(ValueError, "Could not inspect base image: " & image)
  let
    entrypoint = fromJson[EntrypointInfo](imageInfo{"Entrypoint"})
    cmd        = fromJson[CmdInfo](imageInfo{"Cmd"})
    shell      = fromJson[ShellInfo](imageInfo{"Shell"})
  return (entrypoint, cmd, shell)

proc getTargetDockerSection*(info: DockerInvocation): DockerFileSection =
  ## get the target docker section which is to be built
  ## will either be the last section if no target is specified
  ## appropriate section by its alias otherwise
  if info.targetBuildStage == "":
    if len(info.dfSections) == 0:
      raise newException(ValueError, "there are no docker sections")
    return info.dfSections[^1]
  else:
    if info.targetBuildStage notin info.dfSectionAliases:
      raise newException(KeyError, info.targetBuildStage & ": is not found in Dockerfile")
    return info.dfSectionAliases[info.targetBuildStage]

proc getTargetEntrypoints*(info: DockerInvocation):
    tuple[entrypoint: EntrypointInfo, cmd: CmdInfo, shell: ShellInfo] =
  ## get entrypoints (entrypoint/cmd/shell) from the target section
  ## this recursively looks up parent sections in dockerfile
  ## and eventually looks up entrypoints in base image
  var
    section    = info.getTargetDockerSection()
    entrypoint = section.entryPoint
    cmd        = section.cmd
    shell      = section.shell
  while entrypoint == nil or cmd == nil or shell == nil:
    if section.image in info.dfSectionAliases:
      section = info.dfSectionAliases[section.image]
      if entrypoint == nil:
        entrypoint = section.entryPoint
        if entrypoint != nil:
          # defining entrypoint in image wipes any previous CMD
          # and it needs to be redefined again in Dockerfile
          cmd      = nil
      if cmd == nil:
        cmd        = section.cmd
      if shell == nil:
        shell      = section.shell
    else:
      # no more sections in Dockerfile and instead we need to
      # inspect the base image
      let info = info.fetchImageEntrypoint(section.image)
      if entrypoint == nil:
        entrypoint = info.entrypoint
        if entrypoint != nil:
          # defining entrypoint in image wipes any previous CMD
          # and it needs to be redefined again in Dockerfile
          cmd      = nil
      if cmd == nil:
        cmd        = info.cmd
      if shell == nil:
        shell      = info.shell
      break
  # default shell to /bin/sh so that we can wrap CMD shell-form correctly
  if shell == nil:
    shell = ShellInfo()
    shell.json = `%*`(["/bin/sh", "-c"])
  return (entrypoint, cmd, shell)

proc populateBasicImageInfo*(chalk: ChalkObj, info: JsonNode) =
  let
    repo  = info["Repository"].getStr()
    tag   = info["Tag"].getStr.replace("\u003cnone\u003e", "").strip()
    short = info["ID"].getStr()

  chalk.repo    = repo
  chalk.tag     = tag
  chalk.shortId = short

proc getBasicImageInfo*(refName: string): Option[JsonNode] =
  let
    allInfo = runDockerGetEverything(@["images", "--format", "{{json . }}"])
    stdout  = allInfo.getStdout().strip()

  if allInfo.getExit() != 0 or stdout == "":
    return none(JsonNode)

  let
    lines = stdout.split("\n")
    name  = refName.toLowerAscii()

  for line in lines:
    # Comparing line.strip() to "" or checking the length didn't work??
    # There might be some unprintable character before EOF in stdin.
    if not line.strip().startswith("{"):
      break
    let
      json = parseJson(line)
      repo = json["Repository"].getStr()
      tag  = json["Tag"].getStr().replace("\u003cnone\u003e", "")
      id   = json["ID"].getStr()

    if name.toLowerAscii() == id:
      return some(json)
    if name == repo:
      return some(json)
    if name == repo & ":" & tag:
      return some(json)

  return none(JsonNode)

proc extractBasicImageInfo*(chalk: ChalkObj): bool =
  # usreRef should always be what was passed on the command line, and
  # if nothing was passed on the command line, it will be our
  # temporary tag.
  let info = getBasicImageInfo(chalk.userRef)

  if info.isNone():
    return false

  chalk.populateBasicImageInfo(info.get())
  return true

proc dockerGenerateChalkId*(): string =
  var
    b      = secureRand[array[32, char]]()
    preRes = newStringOfCap(32)
  for ch in b: preRes.add(ch)
  return preRes.idFormat()

proc getValue*(secret: DockerSecret): string =
  if secret.src != "":
    return tryToLoadFile(secret.src)
  return ""

proc getSecret*(state: DockerInvocation, name: string): DockerSecret =
  let empty = DockerSecret(id: "", src: "")
  return state.secrets.getOrDefault(name, empty)
