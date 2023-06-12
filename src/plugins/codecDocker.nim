## :Author: John Viega, Brandon Edwards
## :Copyright: 2023, Crash Override, Inc.

import tables, strutils, json, options, os, osproc, streams, parseutils,
       posix_utils, std/tempfiles, nimutils, con4m, ../config, ../plugins,
       ../dockerfile, ../chalkjson

type
  CodecDocker* = ref object of Codec
  DockerFileSection = ref object
    image:        string
    alias:        string
    entryPoint:   EntryPointInfo
    cmd:          CmdInfo
    shell:        ShellInfo
  #% INTERNAL
  InspectedImage = tuple[entryArgv: seq[string],
                         cmdArgv:   seq[string],
                         shellArgv: seq[string],
                         success:   bool]
  #% END
  DockerInfoCache* = ref object of RootObj
    # These fields apply to all artifacts
    container*:             bool     # Whether it's a container or an image.
    inspectOut*:            JSonNode
    # These fields are used on insertion for image artifacts.
    context:                string
    dockerFilePath:         string
    dockerFileContents:     string
    additionalInstructions: string
    tags*:                  seq[string]
    ourTag*:                string
    platform:               string
    labels:                 Con4mDict[string, string]
    execNoArgs:             seq[string]
    execWithArgs:           seq[string]
    tmpDockerFile:          string
    tmpChalkMark:           string
    relativeEntry:          string
    #% INTERNAL
    tmpEntryPoint:          string
    #% END

proc extractArgv(json: string): seq[string] {.inline.} =
  for item in parseJson(json).getElems():
    result.add(item.getStr())

method usesFStream*(self: CodecDocker): bool = false

method autoArtifactPath*(self: Codec): bool        = false

method getUnchalkedHash*(self: CodecDocker, chalk: ChalkObj): Option[string] =
  return none(string)

method getChalkId*(self: CodecDocker, chalk: ChalkObj): string =
  var
    b      = secureRand[array[32, char]]()
    preRes = newStringOfCap(32)
  for ch in b: preRes.add(ch)
  return preRes.idFormat()

# This codec is hard-wired to the docker command at the moment.
method scan*(self: CodecDocker, stream: FileStream, loc: string):
       Option[ChalkObj] = none(ChalkObj)

var dockerPathOpt: Option[string] = none(string)

proc findDockerPath*(): Option[string] =
  once:
    dockerPathOpt = chalkConfig.getDockerExe()
    if dockerPathOpt.isSome():
      let potential = resolvePath(dockerPathOpt.get())
      if fileExists(potential):
        dockerPathOpt = some(potential)
        return dockerPathOpt
    let (mydir, me) = getAppFileName().splitPath()
    for path in getEnv("PATH").split(":"):
      if me == "docker" and path == mydir: continue # Don't find ourself.

      let candidate = joinPath(path, "docker")
      if fileExists(candidate):
        dockerPathOpt = some(candidate)
        return dockerPathOpt
    dockerPathOpt = none(string)

  return dockerPathOpt

#% INTERNAL
proc dockerInspectEntryAndCmd(imageName: string): InspectedImage =
  # `docker inspect imageName`
  #FIXME another thing: this probably needs to be aware of if docker sock
  # or context or docker config is specified to the original docker command!
  #FIXME also needs to return `Shell`

  if imageName == "scratch": return

  let
    cmd  = findDockerPath().get()
    json = execProcess(cmd, args = ["inspect", imageName], options = {})
    arr  = json.parseJson().getElems()

  if len(arr) == 0: return

  result.success = true

  if hasKey(arr[0], "ContainerConfig"):
    let containerConfig = arr[0]["ContainerConfig"]
    if containerConfig.hasKey("Cmd"):
      for i, item in containerConfig["Cmd"].getElems():
        let s = item.getStr()
        if s.startsWith("#(nop)"):
          break
        result.shellArgv.add(s)
  if hasKey(arr[0], "Config"):
    let config = arr[0]["Config"]
    if hasKey(config, "Entrypoint"):
      let items = config["Entrypoint"].getElems()
      for item in items:
        result.entryArgv.add(item.getStr())
    if hasKey(config, "Cmd"):
      let items = config["Cmd"]
      for item in items:
        result.cmdArgv.add(item.getStr())

template inspectionFailed(image: InspectedImage): bool =
  image.success == false
#% END

proc dockerStringToArgv(cmd:   string,
                        shell: seq[string],
                        json:  bool): seq[string] =
  if json: return extractArgv(cmd)

  for value in shell: result.add(value)
  result.add(cmd)

method getChalkInfo*(self: CodecDocker, chalk: ChalkObj): ChalkDict =
  result = ChalkDict()
  let cache = DockerInfoCache(chalk.cache)

  result["DOCKER_TAGS"]     = pack(cache.tags)
  result["ARTIFACT_PATH"]   = pack(cache.context)
  result["DOCKERFILE_PATH"] = pack(cache.dockerFilePath) #TODO
  result["DOCKER_FILE"]     = pack(cache.dockerFileContents)
  result["DOCKER_CONTEXT"]  = pack(cache.context)
  result["ARTIFACT_TYPE"]   = artTypeDockerImage

  if cache.platform != "":
    result["DOCKER_PLATFORM"] = pack(cache.platform)

  if cache.labels.len() != 0:
    result["DOCKER_LABELS"]   = pack(cache.labels)

template extractDockerHash(s: string): string =
  s.split(":")[1].toLowerAscii()

proc getBoxType(b: Box): Con4mType =
  case b.kind
  of MkStr:   return stringType
  of MkInt:   return intType
  of MkFloat: return floatType
  of MkBool:  return boolType
  of MkSeq:
    var itemTypes: seq[Con4mType]
    let l = unpack[seq[Box]](b)

    if l.len() == 0:
      return newListType(newTypeVar())

    for item in l:
      itemTypes.add(item.getBoxType())
    for item in itemTypes[1..^1]:
      if item.unify(itemTypes[0]).isBottom():
        return Con4mType(kind: TypeTuple, itemTypes: itemTypes)
    return newListType(itemTypes[0])
  of MkTable:
    # This is a lie, but con4m doesn't have real objects, or a "Json" / Mixed
    # type, so we'll just continue to special case dicts.
    return newDictType(stringType, newTypeVar())
  else:
    return newTypeVar() # The JSON "Null" can stand in for any type.

proc checkAutoType(b: Box, t: Con4mType): bool =
  return not b.getBoxType().unify(t).isBottom()

proc jsonOneAutoKey(node:        JsonNode,
                    chalkKey:    string,
                    dict:        ChalkDict,
                    reportEmpty: bool) =
  let value = node.nimJsonToBox()

  if value.kind == MkObj: # Using this to represent 'null' / not provided
    return

  if not reportEmpty:
    case value.kind
    of MkStr:
      if unpack[string](value) == "": return
    of MkSeq:
      if len(unpack[seq[Box]](value)) == 0: return
    of MkTable:
      if len(unpack[OrderedTableRef[string, Box]](value)) == 0: return
    else:
      discard

  if not value.checkAutoType(chalkConfig.keyspecs[chalkKey].`type`):
    warn("Docker-provided JSON associated with chalk key '" & chalkKey &
      "' is not of the expected type.  Using it anyway.")

  dict[chalkKey] = value

proc getPartialJsonObject(top: JSonNode, key: string): Option[JSonNode] =
  var cur = top

  let keyParts = key.split('.')
  for item in keyParts:
    if item notin cur:
      return none(JSonNode)
    cur = cur[item]

  return some(cur)

# These are the keys we can auto-convert without any special-casing.
# Types of the JSon will be checked against the key's declared type.
let dockerContainerAutoMap = {
  "RepoTags":                           "_REPO_TAGS",
  "RepoDigests":                        "_REPO_DIGESTS",
  "Args" :                              "_INSTANCE_ARGV",
  "Config.Env" :                        "_INSTANCE_ENV",
  "Id" :                                "_INSTANCE_ID",
  "Created" :                           "_INSTANCE_CREATION_DATETIME",
  "Path" :                              "_INSTANCE_ENTRYPOINT",
  "EntryPoint":                         "_INSTANCE_ENTRYPOINT",
  "Cmd":                                "_INSTANCE_ENTRYPOINT",
  "Config.Image" :                      "_INSTANCE_IMAGE_NAME",
  "Image":                              "_INSTANCE_IMAGE_ID",
  "State.Status" :                      "_INSTANCE_STATUS",
  "State.ExitCode" :                    "_INSTANCE_EXIT_CODE",
  "State.Pid" :                         "_INSTANCE_PID",
  "Name" :                              "_INSTANCE_NAME",
  "RestartCount" :                      "_INSTANCE_RESTART_COUNT",
  "Platform" :                          "_INSTANCE_PLATFORM",
  "HostConfig.Mounts" :                 "_INSTANCE_MOUNTS",
  "HostConfig.PortBindings" :           "_INSTANCE_BOUND_PORTS",
  "HostConfig.Cgroup" :                 "_INSTANCE_CGROUP",
  "HostConfig.Isolation":               "_INSTANCE_ISOLATION",
  "HostConfig.Privileged" :             "_INSTANCE_IS_PRIVILEGED",
  "HostConfig.CapAdd" :                 "_INSTANCE_ADDED_CAPS",
  "HostConfig.CapDrop" :                "_INSTANCE_DROPPED_CAPS",
  "HostConfig.ReadonlyRootfs" :         "_INSTANCE_IMMUTABLE",
  "HostConfig.Runtime" :                "_INSTANCE_RUNTIME",
  "Config.Hostname" :                   "_INSTANCE_HOSTNAME",
  "Config.Domainname" :                 "_INSTANCE_DOMAINNAME",
  "Config.User" :                       "_INSTANCE_USER",
  "Config.Tty" :                        "_INSTANCE_HAS_TTY",
  "Config.Labels" :                     "_INSTANCE_LABELS",
  "Config.ExposedPorts":                "_INSTANCE_EXPOSED_PORTS",
  "NetworkSettings.Ports" :             "_INSTANCE_BOUND_PORTS",
  "NetworkSettings.IPAddress" :         "_INSTANCE_IP",
  "NetworkSettings.GlobalIPv6Address" : "_INSTANCE_IPV6",
  "NetworkSettings.Gateway" :           "_INSTANCE_GATEWAY",
  "NetworkSettings.IPv6Gateway" :       "_INSTANCE_GATEWAYV6",
  "NetworkSettings.MacAddress" :        "_INSTANCE_MAC",
  "Comment":                            "_INSTANCE_COMMENT",
  "Architecture":                       "_INSTANCE_ARCH",
  "Os":                                 "_INSTANCE_OS",
  "Size":                               "_INSTANCE_SIZE"
}.toOrderedTable()

proc jsonAutoKey(map:  OrderedTable[string, string],
                 top:  JsonNode,
                 dict: ChalkDict) =
  let reportEmpty = chalkConfig.dockerConfig.getReportEmptyFields()

  for jsonKey, chalkKey in map:
    let subJsonOpt = top.getPartialJsonObject(jsonKey)

    if subJsonOpt.isNone():
      continue

    jsonOneAutoKey(subJsonOpt.get(), chalkKey, dict, reportEmpty)

method getPostChalkInfo*(self:  CodecDocker,
                         chalk: ChalkObj,
                         ins:   bool): ChalkDict =
  result    = ChalkDict()
  let
    cache      = DockerInfoCache(chalk.cache)
    inspectOut = cache.inspectOut


  if not cache.container:
    chalk.cachedHash = inspectOut["Id"].getStr().extractDockerHash()
    result["_OP_ALL_IMAGE_METADATA"] = inspectOut.nimJsonToBox()
    result["_OP_ARTIFACT_TYPE"]      = artTypeDockerImage
    return
  chalk.cachedHash = inspectOut["Image"].getStr().extractDockerHash()
  result["_OP_ALL_CONTAINER_METADATA"] = inspectOut.nimJsonToBox()
  result["_OP_ARTIFACT_TYPE"]          = artTypeDockerContainer

  jsonAutoKey(dockerContainerAutoMap, inspectOut, result)

proc extractDockerInfo*(chalk:          ChalkObj,
                        flags:          OrderedTable[string, FlagSpec],
                        cmdlineContext: string): bool =
  ## This function evaluates the docker state, including environment
  ## variables, command-line flags and docker file.

  let
    env   = unpack[Con4mDict[string, string]](c4mEnvAll(@[]).get())
    cache = DockerInfoCache()

  var
    errors:         seq[string] = @[]
    rawArgs:        seq[string] = @[]
    fileArgs:       Table[string, string]
    labels        = Con4mDict[string, string]()

  chalk.cache = cache
  cache.labels = Con4mDict[string, string]()

  # Pull data from flags we care about.
  if "tag" in flags:
    cache.tags = unpack[seq[string]](flags["tag"].getValue())

  let randint: uint = secureRand[uint]()
  cache.ourTag      = "chalk:" & $(randint)

  if "platform" in flags:
    cache.platform = (unpack[seq[string]](flags["platform"].getValue()))[0]
    if cache.platform != "linux/amd64":
      error("chalk: skipping unsupported platform: " & cache.platform)
      return false

  if "label" in flags:
    let rawLabels = unpack[seq[string]](flags["label"].getValue())
    for item in rawLabels:
      let arr = item.split("=")
      cache.labels[arr[0]] = arr[^1]

  if "build-arg" in flags:
    rawArgs = unpack[seq[string]](flags["build-arg"].getValue())

  for item in rawArgs:
    let n = item.find("=")
    if n == -1: continue
    fileArgs[item[0 ..< n]] = item[n+1 .. ^1]

  if cmdlineContext == "-":
    cache.context        = "/tmp/"
    cache.dockerFilePath = "-"
  else:
    let possibility = cmdLineContext.resolvePath()
    try:
      discard possibility.stat()
    except:
      error("Chalk: When trying to find: " & possibility &
        ": couldn't find local context: " & getCurrentExceptionMsg())
      error("Remote contexts are not currently supported.")
      return false
    cache.context = possibility

    if "file" in flags:
      cache.dockerFilePath = unpack[seq[string]](flags["file"].getValue())[0]
      if cache.dockerFilePath == "-":
        #NOTE: this is distinct from `docker build -`,
        # this for cases like `docker build -f - .`
        cache.dockerFileContents = stdin.readAll()
        cache.dockerFilePath     = "-"
      else:
        if not cache.dockerFilePath.startsWith("/"):
          let unresolved       = cache.context.joinPath(cache.dockerFilePath)
          cache.dockerFilePath = unresolved.resolvePath()
    else:
      cache.dockerFilePath = cache.context.joinPath("Dockerfile")

  if cache.dockerFilePath == "-":
    cache.dockerFileContents = stdin.readAll()
  else:
    try:
      let s                    = newFileStream(cache.dockerFilePath, fmRead)
      if s != nil:
        cache.dockerFileContents = s.readAll()
        s.close()
      else:
        error(cache.dockerFilePath & ": Dockerfile not found")
    except:
      error(cache.dockerFilePath & ": docker build failed to read Dockerfile")
      return false

  # Part 3: Evaluate the docker file to the extent necessary.
  let stream        = newStringStream(cache.dockerFileContents)
  let (parse, cmds) = stream.parseAndEval(fileArgs, errors)
  for err in errors:
    error(chalk.fullPath & ": " & err)

  var
    section:    DockerFileSection
    curSection: DockerFileSection
    itemFrom:   FromInfo
    foundEntry: EntryPointInfo
    foundCmd:   CmdInfo
    foundShell: ShellInfo
    sectionTable = Table[string, DockerFileSection]()

  for item in cmds:
    if item of FromInfo:
      if section != nil:
        if len(section.alias) > 0:
          sectionTable[section.alias] = section
        else:
          # This is a leaf node section, it doesn't resolve to any tag name
          #TODO insert/chalk this layer in resulting Dockerfile prime
          error("skipping unreferenced discrete section in Dockerfile")
          discard
      section = DockerFileSection()
      itemFrom = FromInfo(item)
      section.image = parse.evalOrReturnEmptyString(itemFrom.image, errors)
      if itemFrom.tag.isSome():
        section.image &= ":" &
                 parse.evalSubstitutions(itemFrom.tag.get(), errors)
      section.alias = parse.evalOrReturnEmptyString(itemFrom.asArg, errors)
    elif item of EntryPointInfo:
      section.entryPoint = EntryPointInfo(item)
    elif item of CmdInfo:
      section.cmd = CmdInfo(item)
    elif item of ShellInfo:
      section.shell = ShellInfo(item)
    elif item of LabelInfo:
      for k, v in LabelInfo(item).labels:
        labels[k] = v
    # TODO: when we support CopyInfo, we need to add a case for it here
    # to save the source location as a hint for where to look for git info

  # might have had errors walking the Dockerfile commands
  for err in errors:
    error(chalk.fullPath & ": " & err)

  # Command line flags replace what's in the docker file if there's a key
  # collision.
  for k, v in labels:
    if k notin cache.labels:
      cache.labels[k] = v

  if section == nil:
    warn("No content found in the docker file")
    return false

  #% INTERNAL
  if not chalkConfig.dockerConfig.getWrapEntryPoint():
    stream.close()
    return true

  # walk the sections from the most-recently-defined section.
  curSection = section
  while true:
    if foundCmd == nil:
      foundCmd = curSection.cmd
    if foundEntry == nil:
      foundEntry = curSection.entryPoint
    if foundShell == nil:
      foundShell = curSection.shell
    if curSection.image notin sectionTable:
      break
    curSection = sectionTable[curSection.image]

  var
    entryArgv:             seq[string]
    cmdArgv:               seq[string]
    shellArgv:             seq[string]
    inspected:             InspectedImage
    containerExecNoArgs:   seq[string]
    containerExecWithArgs: seq[string]

  if foundShell != nil:
    # shell is required to be specified in JSON, note that
    # here with ShellInfo the .json is a string not a bool :)
    shellArgv = extractArgv(foundShell.json)

  if foundEntry == nil or (foundEntry.json == false and foundShell == nil):
    # we need to inspect the ancestor image if:
    #   - we didn't find an entrypoint, as we need to know if there is one
    #     and if there's not, then we need to default to cmd, which we also
    #     might not have
    #   - we found the entrypoint but in shell-form and we didn't find a shell
    # if we don't have cmd, we should also populate that from inspect results
    inspected       = dockerInspectEntryAndCmd(curSection.image)
    if inspected.inspectionFailed():
      warn("Docker inspect failed.")
      return false
    if foundEntry == nil:
      # we don't have entrypoint, so use the one from inspect, which might also
      # be nil but that's ok
      entryArgv = inspected.entryArgv
      if foundShell == nil:
        shellArgv = inspected.shellArgv
      # This dockerfile hasn't defined its own entrypoint, so we need
      # to honor the cmd if it is defined in the ancestor.
      if foundCmd == nil:
        cmdArgv = inspected.cmdArgv
      else:
        cmdArgv = dockerStringToArgv(foundCmd.contents,shellArgv,foundCmd.json)
    else:
      # we have an entry point, but it's not json and we didn't find shell
      shellArgv = inspected.shellArgv
      entryArgv = dockerStringToArgv(foundEntry.contents, shellArgv, false)
  else:
    # we had found entrypoint, and if it's not json we also have shell
    entryArgv = dockerStringToArgv(foundEntry.contents,
                                   shellArgv,
                                   foundEntry.json)
    if foundCmd != nil:
      # fun fact: from the docs you would think this should also
      # check that foundEntry.json == true, because entrypoints defined
      # in shellform supposedly discard cmd.. except that behavior is a
      # byproduct of `/bin/sh -c`, which treats the next argv entry as
      # the only command to execute.
      if foundShell == nil and not foundCmd.json:
        inspected = dockerInspectEntryAndCmd(curSection.image)
        if inspected.inspectionFailed():
          warn("Docker inspect failed.")
          return false
        shellArgv = inspected.shellArgv
      cmdArgv = dockerStringToArgv(foundCmd.contents, shellArgv, foundCmd.json)

  if len(entryArgv) == 0:
    if len(cmdArgv) == 0:
      # TODO this should be configurable: if we don't have an entrypoint
      # and we don't have a cmd, if the user still wants us to embed an
      # entrypoint we can. Once we have a config option and thought about
      # what default should be then resume here to implement
      error("skipping currently unsupported case of !entrypoint && !cmd")
      return false

    # If cmd is specified in exec form, and the first item doesn't
    # have an explicitly defined /path/to/file, then we should be sure
    # that, if we wrap the entry point, we can find the command at
    # build time.  Sure, they might come in and slam the path, but if
    # they do something crazy like that, we'll just fail and re-build
    # the container without chalking.
    if cmdArgv[0][0] != '/':
      cache.relativeEntry = cmdArgv[0].split(" ")[0]

    cache.execNoArgs   = cmdArgv
    cache.execWithArgs = @[]
  else:
    cache.execNoArgs   = entryArgv & cmdArgv
    cache.execWithArgs = entryArgv
  #% END
  stream.close()
  return true

proc processLabel(s: string): string =
  let
    prefix = chalkConfig.dockerConfig.getLabelPrefix()
    joined = if prefix.endsWith('.'): prefix & s else: prefix & "." & s
    lower  = joined.toLowerAscii()

  result = lower.replace("_", "-")
  if result.contains("$"):
    result = result.replace("$", "_")

proc writeChalkMark*(chalk: ChalkObj, mark: string) =
  var
    cache     = DockerInfoCache(chalk.cache)
    (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix, cache.context)
    ctx       = newFileStream(f)
    labelOps  = chalkConfig.dockerConfig.getCustomLabels()

  try:
    ctx.writeLine(mark)
    ctx.close()
    cache.tmpChalkMark = path
    info("Creating temporary chalk file: " & path)
    cache.additionalInstructions = "COPY " & path.splitPath().tail & " " &
      chalkConfig.dockerConfig.getChalkFileLocation() & "\n"
    if labelOps.isSome():
      for k, v in labelOps.get():
        let jtxt = if v.startsWith('"'): v else: escapeJson(v)
        cache.additionalInstructions &= "LABEL " & processLabel(k) &
          "=" & jtxt & "\n"
    let labelProfileName = chalkConfig.dockerConfig.getLabelProfile()
    if labelProfileName != "":
      let lprof = chalkConfig.profiles[labelProfileName]
      if lprof.enabled:
        let toLabel = filterByProfile(hostInfo, chalk.collectedData, lprof)
        for k, v in toLabel:
          let
            jraw = boxToJson(v)
            jtxt = if jraw.startswith('"'): jraw else: jraw.escapeJson()
          cache.additionalInstructions &= "LABEL " & processLabel(k) &
            "=" & jtxt & "\n"
  finally:
    if ctx != nil:
      try:
        ctx.close()
      except:
        removeFile(path)
        error("Could not write chalk mark (no permission)")
        raise

#% INTERNAL
const
  hostDefault = "host_report_other_base"
  artDefault  = "artifact_report_extract_base"

proc profileToString(name: string): string =
  if name in ["", hostDefault, artDefault]: return ""

  result      = "profile " & name & " {\n"
  let profile = chalkConfig.profiles[name]

  for k, obj in profile.keys:
    let
      scope  = obj.getAttrScope()
      report = get[bool](scope, "report")
      order  = getOpt[int](scope, "order")

    result &= "  key." & k & ".report = " & $(report) & "\n"
    if order.isSome():
      result &= "  key." & k & ".order = " & $(order.get()) & "\n"

  result &= "}\n\n"

proc sinkConfToString(name: string): string =
  result     = "sink_config " & name & " {\n  filters: ["
  var frepr  = seq[string](@[])
  let
    config   = chalkConfig.sinkConfs[name]
    scope    = config.getAttrScope()

  for item in config.filters: frepr.add("\"" & item & "\"")

  result &= frepr.join(", ") & "]\n"
  result &= "  sink: \"" & config.sink & "\"\n"

  # copy out the config-specific variables.
  for k, v in scope.contents:
    if k in ["enabled", "filters", "loaded", "sink"]: continue
    if v.isA(AttrScope): continue
    let val = getOpt[string](scope, k).getOrElse("")
    result &= "  " & k & ": \"" & val & "\"\n"

  result &= "}\n\n"

proc prepEntryPointBinary*(chalk, selfChalk: ChalkObj) =
  # TODO: this and the template need to be massaged to work, and
  # we need to write the code to actually handle the 'entrypoint' command.
  # Similarly, need to have a flag to skip arg parsing altogether.

  var newCfg     = entryPtTemplate
  let
    cache        = DockerInfoCache(chalk.cache)
    noArgs       = $(%* cache.execNoArgs)
    withArgs     = $(%* cache.execWithArgs)
    dockerCfg    = chalkConfig.dockerConfig
    hostProfName = dockerCfg.getEntrypointHostReportProfile().get(hostDefault)
    artProfName  = dockerCfg.getEntrypointHostReportProfile().get(artDefault)
    sinkName     = dockerCfg.getEntrypointReportSink()
    hostProfile  = hostProfName.profileToString()
    artProfile   = artProfName.profileToString()
    sinkSpec     = sinkName.sinkConfToString()

  newCfg = newCfg.replace("$$$CHALKFILE$$$", dockerCfg.getChalkFileLocation())
  newCfg = newCfg.replace("$$$ENTRYPOINT$$$", "???")
  newCfg = newCfg.replace("$$$SINKNAME$$$", sinkName)
  newCfg = newCfg.replace("$$$HOSTPROFILE$$$", hostProfile)
  newCfg = newCfg.replace("$$$ARTIFACTPROFILE$$$", artProfile)
  newCfg = newCfg.replace("$$$ARTPROFILEREF$$$", hostProfName)
  newCfg = newCfg.replace("$$$HOSTPROFILEREF$$$", artProfName)
  newCfg = newCfg.replace("$$$CONTAINEREXECNOARGS$$$", noArgs)
  newCfg = newCfg.replace("$$$CONTAINEREXECWITHARGS$$$", withArgs)
  newCfg = newCfg.replace("$$$SINKCONFIG$$$", sinkSpec)

  selfChalk.collectedData["$CHALK_CONFIG"] = pack(newCfg)

proc writeEntryPointBinary*(chalk, selfChalk: ChalkObj, toWrite: string) =
  let
    cache     = DockerInfoCache(chalk.cache)
    (f, path) = createTempFile(tmpFilePrefix, tmpFileSuffix, cache.context)
    codec     = selfChalk.myCodec

  f.close() # Just needed the name...
  trace("Writing new entrypoint binary to: " & path)

  # If we cannot write to the file system, we should write the chalk
  # mark to a label (TODO)
  try:
    codec.handleWrite(selfChalk, some(toWrite))
    info("New entrypoint binary written to: " & path)

    # If we saw a relative path for the entry point binary, we should make sure
    # that we're going to find it in the container, so that we don't silently
    # fail when running as an entry point.  If the 'which' command fails, the
    # build should fail, and the container should re-build without us.
    if cache.relativeEntry != "":
      cache.additionalInstructions &= "RUN which " & cache.relativeEntry & "\n"

    # Here's the rationale around the random string:
    # 1. Unlikely, but two builds could use the same context dir concurrently
    # 2. Docker caches layers from RUN commands, and possibly from COPY,
    #    so to ensure the binary is treated uniquely we use a random name
    #    (we could pass --no-cache to Docker, but this could have other
    #     side-effects we don't want, and also doesn't address #1)
    # 3. We don't copy directly to /chalk in container because there might
    #    already be a /chalk binary there, and we need to consume its contents
    #    if it's there
    if chalkConfig.getRecursive():
      cache.additionalInstructions &= "RUN /" & path & " insert\n"
      cache.additionalInstructions &= "COPY " & path & " /" & path & "\n"
    else:
      cache.additionalInstructions &= "COPY " & path & " /chalk\n"
    cache.additionalInstructions &= "ENTRYPOINT [\"/chalk\"]\n"
  except:
    error("Writing entrypoint binary failed: " & getCurrentExceptionMsg())
    dumpExOnDebug()
    raise

  try:
    discard cache.context.joinPath(".dockerignore").stat()
    # really not sure the best approach here, they all feel racy
    # do we just write an exclusion (which begins with '!') in
    # the form of !{tmpFilePrefix} ? or !{generated-tmp-path}
    # but if we have concurrent accesses ... well it could get ugly
  except:
    discard
#% END
proc runInspectOnImage*(cmd: string, chalk: ChalkObj): bool =
  let
    cache  = DockerInfoCache(chalk.cache)
    output = execProcess(cmd, args = @["inspect", cache.ourTag], options = {})
    items  = output.parseJson().getElems()

  if len(items) != 0:
    cache.inspectOut = items[0]
    return true

proc buildContainer*(chalk:  ChalkObj,
                     flags:  OrderedTable[string, FlagSpec],
                     inargs: seq[string]): bool =
  # Going to reparse the original argument to lift out any -f/--file
  # but otherwise will pass through all arguments.
  let
    cache     = DockerInfoCache(chalk.cache)
    fullFile  = cache.dockerFileContents & "\n" & cache.additionalInstructions
    (f, path) = createTempFile(tmpFilePrefix, tmpFilesuffix, cache.context)
    # This line should be semantically the same as the one after it.
    # However, for some reason, even if I pass every arg by position,
    # noSpace ends up 'true' immediately after???  Oddest thing I've seen
    # in a while. TODO: WTF is going on??
    #
    # reparse   = newSpecObj(maxArgs = high(int), unknownFlagsOk = true,
    #                        noSpace = false)
    reparse = CommandSpec(maxArgs: high(int), dockerSingleArg: true,
                                  unknownFlagsOk: true, noSpace: false)

  let
    cmd       = findDockerPath().get()

  info("Created temporary docker file: " & path)
  cache.tmpDockerFile = path
  f.write(fullFile)
  f.close()
  reparse.addFlagWithArg("file", ["f", "file"], true, true, optArg = false)
  var args = reparse.parse(inargs).args[""] & @["-f", path, "-t", cache.ourTag]

  let
    subp = startProcess(cmd, args = args, options = {poParentStreams})
    code = subp.waitForExit()

  if code != 0: return false

  result = runInspectOnImage(cmd, chalk)

  # If the user supplied tags, remove the tag we added.
  if cache.tags.len() != 0:
    discard execProcess(cmd, args = @["rmi", cache.ourTag], options = {})


proc cleanupTmpFiles*(chalk: ChalkObj) =
  let cache = DockerInfoCache(chalk.cache)

  if not chalkConfig.getChalkDebug():
    if cache == nil:              return
    if cache.tmpDockerFile != "": removeFile(cache.tmpDockerFile)
    if cache.tmpChalkMark  != "": removeFile(cache.tmpChalkMark)
    #% INTERNAL
    if cache.tmpEntryPoint != "": removeFile(cache.tmpEntryPoint)
    #% END
  else:
    # This generally won't print since --log-level defaults to 'error' for chalk
    info("Skipping deletion of temporary files due to chalk_debug = true")

proc processPushInfo*(arr: seq[JSonNode], arg: string) =
  let
    slashIx  = arg.find('/')
    endIx    = if slashIx == -1: len(arg) else: slashIx
    fullRepo = arg[0 ..< endIx]
    parts    = fullRepo.split(':')
  if len(parts) > 0:
    hostInfo["_REPO_HOST"] = pack(parts[0])
  if len(parts) > 1:
    var port: int
    try:
      discard parseInt(parts[1], port)
      hostInfo["_REPO_PORT"] = pack(port)
    except:
      hostInfo["_REPO_HOST"] = pack(fullRepo)

  # Really should only have one, but just in case...
  for item in arr:
    if "Id" notin item:
      continue
    let
      id    = item["Id"].getStr()
      chalk = newChalk(FileStream(nil), id)

    # We're assuming it's marked; we don't want to bother looking for the mark
    chalk.marked = true
    chalk.addToAllChalks()
    chalk.collectedData["_CURRENT_HASH"] = pack(id.split(":")[^1])
    if "RepoTags" in item:
      var
        tags: seq[string] = @[]
        jsonArr           = item["RepoTags"].getElems()
      for item in jsonArr:
        tags.add(item.getStr())
      if len(tags) != 0:
        chalk.collectedData["_REPO_TAGS"] = pack(tags)
    if "RepoDigests" in item:
      var
        digests: seq[string] = @[]
        jsonArr              = item["RepoDigests"].getElems()
      for item in jsonArr:
        digests.add(item.getStr().split(":")[^1])
      if len(digests) != 0:
        chalk.collectedData["_REPO_DIGESTS"] = pack(digests)

#% INTERNAL
# This stuff needs to get done somewhere...
#
# when we execute docker build (using user's original commandline):
#   - change/set -f/--file to /tmp/chalkdockerfileRandomString
#
# when chalk is executing from the RUN statement above, it will be in-container
# during build-time, it needs to :
#   - check for existing chalk at /chalk: consume that chalk metadata
#   - write to /chalk itself + any metadata consumed
#   - remove /chalkBinaryRandomString
#
# When we exec in container fo real!
#   - fork() --> child reports home (not parent!), with some timeout (< 1sec)
#   - in parent (pid 1 in theory):
#       - if len(argv) > 1:
#         exec(containerExecWithArgs + argv[1:^1])
#       - else
#         exec(containerExecNoArgs)
# TODO: not handling virtual chalking.
# TODO: report not being able to chalk.
# TODO: add chalk.postHash
# TODO: remove chalk and chalk.json from the context if they exist.
# TODO: report the image ID as the post-hash (needs appropriate formatting)
#% END
registerPlugin("docker", CodecDocker())
