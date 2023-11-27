##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##
import osproc, ../config, ../docker_base, ../chalkjson, ../attestation,
       ../plugin_api

const
  markFile     = "chalk.json"
  markLocation = "/chalk.json"

proc dockerGetChalkId*(self: Plugin, chalk: ChalkObj): string {.cdecl.} =
  if chalk.extract != nil and "CHALK_ID" in chalk.extract:
    return unpack[string](chalk.extract["CHALK_ID"])
  return dockerGenerateChalkId()

proc extractImageMark(chalk: ChalkObj): ChalkDict =
  result = ChalkDict(nil)

  let
    imageId = chalk.imageId
    dir     = getNewTempDir()

  try:
    withWorkingDir(dir):

      let procInfo = runDockerGetEverything(@["save", imageId, "-o", "image.tar"])

      if procInfo.getExit() != 0:
        error("Image " & imageId & ": error extracting chalk mark")
        return
      if execCmd("tar -xf image.tar manifest.json") != 0:
        error("Image " & imageId & ": could not extract manifest (no tar cmd?)")
        return

      let
        file = newFileStream("manifest.json")

      if file == nil:
        error("Image " & imageId & ": could not extract manifest (permissions?)")
        return
      let
        str    = file.readAll()
        json   = str.parseJson()
        layers = json.getElems()[0]["Layers"]

      file.close()

      if execCmd("tar -xf image.tar " & layers[^1].getStr()) != 0:
        error("Image " & imageId & ": error extracting chalk mark")
        return

      if execCmd("tar -xf " & layers[^1].getStr() &
        " chalk.json 2>/dev/null") == 0:
        let file = newFileStream(markFile)

        if file == nil:
          error("Image " & imageId & " has a chalk file but we can't read it?")
          return

        chalk.cachedMark = file.readAll()
        file.close()

        let mark = newStringStream(chalk.cachedMark)
        result   = extractOneChalkJson(mark, imageId)

        mark.close()
        return
      else:
        warn("Image " & imageId & " has no chalk mark in the top layer.")
        if not chalkConfig.extractConfig.getSearchBaseLayersForMarks():
          return
        # We're only going to go deeper if there's no chalk mark found.
        var
          n = len(layers) - 1

        while n != 0:
          n = n - 1
          if execCmd("tar -xf " & layers[n].getStr() &
            " chalk.json 2>/dev/null") == 0:
            let file = newFileStream("chalk.json")
            if file == nil:
              continue
            try:
              let
                extract = extractOneChalkJson(file, imageId)
                cid     = extract["CHALK_ID"]
                mdid    = extract["METADATA_ID"]

              info("In layer " & $(n) & " (of " & $(len(layers)) & "), found " &
                "Chalk mark reporting CHALK_ID = " & $(cid) &
                " and METADATA_ID = " & $(mdid))
              chalk.collectedData["_FOUND_BASE_MARK"] = pack(@[cid, mdid])
              return
            except:
              continue
  except:
    dumpExOnDebug()
    trace(imageId & ": Could not complete mark extraction")

proc extractMarkFromStdin(s: string): string =
  var raw = s

  while true:
    let ix = raw.find('{')
    if ix == -1:
      return ""
    raw = raw[ix .. ^1]
    if raw[1 .. ^1].strip().startswith("\"MAGIC\""):
      return raw

proc extractContainerMark(chalk: ChalkObj): ChalkDict =
  result = ChalkDict(nil)
  let
    cid = chalk.containerId

  try:
    let
      procInfo = runDockerGetEverything(@["cp", cid & ":" & markLocation, "-"])
      mark     = procInfo.getStdOut().extractMarkFromStdin()

    if procInfo.getExit() != 0:
      let err = procInfo.getStdErr()
      if err.contains("No such container"):
        error(chalk.name & ": container shut down before mark extraction")
      elif err.contains("Could not find the file"):
        warn(chalk.name & ": container is unmarked.")
      else:
        warn(chalk.name & ": container mark not retrieved: " & err)
      return
    result = extractOneChalkJson(newStringStream(mark), cid)
  except:
    dumpExOnDebug()
    error(chalk.name & ": got error when extracting from container.")

proc getImageChalks*(codec: Plugin): seq[ChalkObj] {.exportc,cdecl.} =
  try:
    let
      raw    = runDockerGetEverything(@["images", "--format", "json"])
      stdout = raw.getStdout().strip()

    if raw.getExit() != 0 or stdout == "":
      trace("No local images.")
    else:
      for line in stdout.split("\n"):
        let
          json    = parseJson(line)
          imageId = json["ID"].getStr()
          repo    = json["Repository"].getStr()
          tag     = json["Tag"].getStr().replace("\u003cnone\u003e","").strip()
          chalk   = newChalk(name         = imageId,
                             codec        = codec,
                             repo         = repo,
                             tag          = imageId,
                             imageId      = imageId,
                             extract      = ChalkDict(),
                             resourceType = {ResourceImage})
        chalk.tag = tag
        trace("Got image with ID = " & imageId)
        result.add(chalk)
  except:
    dumpExOnDebug()
    trace("No docker command found.")
    return

proc inspectContainer(chalk: ChalkObj) # Defined below.

proc getContainerChalks*(codec: Plugin): seq[ChalkObj] {.exportc,cdecl.} =
  try:
    let
      raw    = runDockerGetEverything(@["ps", "--format", "json"])
      stdout = raw.getStdout().strip()

    if raw.getExit() != 0 or stdout == "":
      trace("No running containers.")
      return
    for line in stdout.split("\n"):
      let
        containerId = parseJson(line)["ID"].getStr()
        name        = parseJson(line)["Names"].getStr()
        chalk       = newChalk(name         = name,
                               tag          = name,
                               containerId  = containerId,
                               codec        = codec,
                               resourceType = {ResourceContainer})

      if chalk.name == "":
        chalk.name = containerId

      chalk.inspectContainer()

      result.add(chalk)
  except:
    dumpExOnDebug()
    trace("Could not run docker.")

# These are the keys we can auto-convert without any special-casing.
# Types of the JSon will be checked against the key's declared type.
let dockerImageAutoMap = {
  "RepoTags":                           "_REPO_TAGS",
  "RepoDigests":                        "_REPO_DIGESTS",
  "Comment":                            "_IMAGE_COMMENT",
  "Created":                            "_IMAGE_CREATION_DATETIME",
  "DockerVersion":                      "_IMAGE_DOCKER_VERSION",
  "Author":                             "_IMAGE_AUTHOR",
  "Architecture":                       "_IMAGE_ARCHITECTURE",
  "Variant":                            "_IMAGE_VARIANT",
  "OS":                                 "_IMAGE_OS",
  "OsVersion":                          "_IMAGE_OS_VERSION",
  "Size":                               "_IMAGE_SIZE",
  "RootFS.Type":                        "_IMAGE_ROOT_FS_TYPE",
  "RootFS.Layers",                      "_IMAGE_ROOT_FS_LAYERS",
  "Config.Hostname":                    "_IMAGE_HOSTNAMES",
  "Config.Domainname":                  "_IMAGE_DOMAINNAME",
  "Config.User":                        "_IMAGE_USER",
  "Config.ExposedPorts":                "_IMAGE_EXPOSEDPORTS",
  "Config.Env":                         "_IMAGE_ENV",
  "Config.Cmd":                         "_IMAGE_CMD",
  "Config.Image":                       "_IMAGE_NAME",
  "Config.Healthcheck.Test":            "_IMAGE_HEALTHCHECK_TEST",
  "Config.Healthcheck.Interval":        "_IMAGE_HEALTHCHECK_INTERVAL",
  "Config.Healthcheck.Timeout":         "_IMAGE_HEALTHCHECK_TIMEOUT",
  "Config.Healthcheck.StartPeriod":     "_IMAGE_HEALTHCHECK_START_PERIOD",
  "Config.Healthcheck.StartInterval":   "_IMAGE_HEALTHCHECK_START_INTERVAL",
  "Config.Healthcheck.Retries":         "_IMAGE_HEALTHCHECK_RETRIES",
  "Config.Volumes":                     "_IMAGE_MOUNTS",
  "Config.WorkingDir":                  "_IMAGE_WORKINGDIR",
  "Config.Entrypoint":                  "_IMAGE_ENTRYPOINT",
  "Config.NetworkDisabled":             "_IMAGE_NETWORK_DISABLED",
  "Config.MacAddress":                  "_IMAGE_MAC_ADDR",
  "Config.OnBuild":                     "_IMAGE_ONBUILD",
  "Config.Labels":                      "_IMAGE_LABELS",
  "Config.StopSignal":                  "_IMAGE_STOP_SIGNAL",
  "Config.StopTimeout":                 "_IMAGE_STOP_TIMEOUT",
  "Config.Shell":                       "_IMAGE_SHELL",
  "VirtualSize":                        "_IMAGE_VIRTUAL_SIZE",
  "Metadata.LastTagTime":               "_IMAGE_LAST_TAG_TIME",
  "GraphDriver":                        "_IMAGE_STORAGE_METADATA"
  }.toOrderedTable()

let dockerContainerAutoMap = {
  "Id":                                 "_INSTANCE_CONTAINER_ID",
  "Created":                            "_INSTANCE_CREATION_DATETIME",
  "Path":                               "_INSTANCE_ENTRYPOINT_PATH",
  "Args":                               "_INSTANCE_ENTRYPOINT_ARGS",
  "State.Status":                       "_INSTANCE_STATUS",
  "State.Pid":                          "_INSTANCE_PID",
  "ResolvConfPath":                     "_INSTANCE_RESOLVE_CONF_PATH",
  "HostNamePath":                       "_INSTANCE_HOSTNAME_PATH",
  "HostsPath":                          "_INSTANCE_HOSTS_PATH",
  "LogPath":                            "_INSTANCE_LOG_PATH",
  "Name":                               "_INSTANCE_NAME",
  "RestartCount":                       "_INSTANCE_RESTART_COUNT",
  "Driver":                             "_INSTANCE_DRIVER",
  "Platform":                           "_INSTANCE_PLATFORM",
  "MountLabel":                         "_INSTANCE_MOUNT_LABEL",
  "ProcessLabel":                       "_INSTANCE_PROCESS_LABEL",
  "AppArmorProfile":                    "_INSTANCE_APP_ARMOR_PROFILE",
  "ExecIDs":                            "_INSTANCE_EXEC_IDS",
  "HostConfig.Binds":                   "_INSTANCE_BINDS",
  "HostConfig.ContainerIDFile":         "_INSTANCE_CONTAINER_ID_FILE",
  "HostConfig.LogConfig.Config":        "_INSTANCE_LOG_CONFIG",
  "HostConfig.NetworkMode":             "_INSTANCE_NETWORK_MODE",
  "HostConfig.PortBindings":            "_INSTANCE_BOUND_PORTS",
  "HostConfig.RestartPolicy.Name":      "_INSTANCE_RESTART_POLICY_NAME",
  "HostConfig.RestartPolicy.MaximumRetryCount": "_INSTANCE_RESTART_RETRY_COUNT",
  "HostConfig.AutoRemove":              "_INSTANCE_AUTOREMOVE",
  "HostConfig.VolumeDriver":            "_INSTANCE_VOLUME_DRIVER",
  "HostConfig.VolumesFrom":             "_INSTANCE_VOLUMES_FROM",
  "HostConfig.ConsoleSize":             "_INSTANCE_CONSOLE_SIZE",
  "HostConfig.CapAdd":                  "_INSTANCE_ADDED_CAPS",
  "HostConfig.CapDrop":                 "_INSTANCE_DROPPED_CAPS",
  "HostConfig.CgroupnsMode":            "_INSTANCE_CGROUP_NS_MODE",
  "HostConfig.Dns":                     "_INSTANCE_DNS",
  "HostConfig.DnsOptions":              "_INSTANCE_DNS_OPTIONS",
  "HostConfig.DnsSearch":               "_INSTANCE_DNS_SEARCH",
  "HostConfig.ExtraHosts":              "_INSTANCE_EXTRA_HOSTS",
  "HostConfig.GroupAdd":                "_INSTANCE_GROUP_ADD",
  "HostConfig.IpcMode":                 "_INSTANCE_IPC_MODE",
  "HostConfig.Cgroup":                  "_INSTANCE_CGROUP",
  "HostConfig.Links":                   "_INSTANCE_LINKS",
  "HostConfig.OomScoreAdj":             "_INSTANCE_OOM_SCORE_ADJ",
  "HostConfig.PidMode":                 "_INSTANCE_PID_MODE",
  "HostConfig.Privileged":              "_INSTANCE_IS_PRIVILEGED",
  "HostConfig.PublishAllPorts":         "_INSTANCE_PUBLISH_ALL_PORTS",
  "HostConfig.ReadonlyRootfs":          "_INSTANCE_READONLY_ROOT_FS",
  "HostConfig.SecurityOpt":             "_INSTANCE_SECURITY_OPT",
  "HostConfig.UTSMode":                 "_INSTANCE_UTS_MODE",
  "HostConfig.UsernsMode":              "_INSTANCE_USER_NS_MODE",
  "HostConfig.ShmSize":                 "_INSTANCE_SHM_SIZE",
  "HostConfig.Runtime":                 "_INSTANCE_RUNTIME",
  "HostConfig.Isolation":               "_INSTANCE_ISOLATION",
  "HostConfig.CpuShares":               "_INSTANCE_CPU_SHARES",
  "HostConfig.Memory":                  "_INSTANCE_MEMORY",
  "HostConfig.NanoCpus":                "_INSTANCE_NANO_CPUS",
  "HostConfig.CgroupParent":            "_INSTANCE_CGROUP_PARENT",
  "HostConfig.BlkioWeight":             "_INSTANCE_BLOCKIO_WEIGHT",
  "HostConfig.BlkioWeightDevice":       "_INSTANCE_BLOCKIO_WEIGHT_DEVICE",
  "HostConfig.BlkioDeviceReadBps":      "_INSTANCE_BLOCKIO_DEVICE_READ_BPS",
  "HostConfig.BlkioDeviceWriteBps":     "_INSTANCE_BLOCKIO_DEVICE_WRITE_BPS",
  "HostConfig.BlkioDeviceReadIOps":     "_INSTANCE_BLOCKIO_DEVICE_READ_IOPS",
  "HostConfig.BlkioDeviceWriteIops":    "_INSTANCE_BLOCKIO_DEVICE_WRITE_IOPS",
  "HostConfig.CpuPeriod":               "_INSTANCE_CPU_PERIOD",
  "HostConfig.CpuQuota":                "_INSTANCE_CPU_QUOTA",
  "HostConfig.CpuRealtimePeriod":       "_INSTANCE_CPU_REALTIME_PERIOD",
  "HostConfig.CpuRealtimeRuntime":      "_INSTANCE_CPU_REALTIME_RUNTIME",
  "HostConfig.CpusetCpus":              "_INSTANCE_CPUSET_CPUS",
  "HostConfig.CpusetMems":              "_INSTANCE_CPUSET_MEMS",
  "HostConfig.Devices":                 "_INSTANCE_DEVICES",
  "HostConfig.DeviceCgroupRules":       "_INSTANCE_CGROUP_RULES",
  "HostConfig.DeviceRequests":          "_INSTANCE_DEVICE_REQUESTS",
  "HostConfig.MemoryReservation":       "_INSTANCE_MEMORY_RESERVATION",
  "HostConfig.MemorySwap":              "_INSTANCE_MEMORY_SWAP",
  "HostConfig.MemorySwappiness":        "_INSTANCE_MEMORY_SWAPPINESS",
  "HostConfig.OomKillDisable":          "_INSTANCE_OOM_KILL_DISABLE",
  "HostConfig.PidsLimit":               "_INSTANCE_PIDS_LIMIT",
  "HostConfig.Ulimits":                 "_INSTANCE_ULIMITS",
  "HostConfig.CpuCount":                "_INSTANCE_CPU_COUNT",
  "HostConfig.CpuPercent":              "_INSTANCE_CPU_PERCENT",
  "HostConfig.IOMaximumIOps":           "_INSTANCE_IO_MAX_IOPS",
  "HostConfig.IOMaximumBandwidth":      "_INSTANCE_IO_MAX_BPS",
  "HostConfig.MaskedPaths":             "_INSTANCE_MASKED_PATHS",
  "HostConfig.ReadonlyPaths":           "_INSTANCE_READONLY_PATHS",
  "GraphDriver":                        "_INSTANCE_STORAGE_METADATA",
  "Mounts":                             "_INSTANCE_MOUNTS",
  "Config.Hostname":                    "_INSTANCE_HOSTNAME",
  "Config.Domainname":                  "_INSTANCE_DOMAINNAME",
  "Config.User":                        "_INSTANCE_USER",
  "Config.AttachStdin":                 "_INSTANCE_ATTACH_STDIN",
  "Config.AttachStdout":                "_INSTANCE_ATTACH_STDOUT",
  "Config.AttachStderr":                "_INSTANCE_ATTACH_STDERR",
  "Config.ExposedPorts":                "_INSTANCE_EXPOSED_PORTS",
  "Config.Tty":                         "_INSTANCE_HAS_TTY",
  "Config.OpenStdin":                   "_INSTANCE_OPEN_STDIN",
  "Config.StdinOnce":                   "_INSTANCE_STDIN_ONCE",
  "Config.Env":                         "_INSTANCE_ENV",
  "Config.Cmd":                         "_INSTANCE_CMD",
  "Config.Image":                       "_INSTANCE_CONFIG_IMAGE",
  "Config.Volumes":                     "_INSTANCE_VOLUMES",
  "Config.WorkingDir":                  "_INSTANCE_WORKING_DIR",
  "Config.Entrypoint":                  "_INSTANCE_ENTRYPOINT",
  "Config.OnBuild":                     "_INSTANCE_ONBUILD",
  "Config.Labels":                      "_INSTANCE_LABELS",
  "NetworkSettings.Bridge":             "_INSTANCE_BRIDGE",
  "NetworkSettings.SandboxId":          "_INSTANCE_SANDBOXID",
  "NetworkSettings.HairpinMode":        "_INSTANCE_HAIRPINMODE",
  "NetworkSettings.LinkLocalIPv6Address":   "_INSTANCE_LOCAL_IPV6",
  "NetworkSettings.LinkLocalIPv6PrefixLen": "_INSTANCE_LOCAL_IPV6_PREFIX_LEN",
  "NetworkSettings.Ports":                  "_INSTANCE_BOUND_PORTS",
  "NetworkSettings.SanboxKey":              "_INSTANCE_SANDBOX_KEY",
  "NetworkSettings.SecondaryIPAddresses":   "_INSTANCE_SECONDARY_IPS",
  "NetworkSettings.SecondaryIPv6Addresses": "_INSTANCE_SECONDARY_IPV6_ADDRS",
  "NetworkSettings.EndpointID":             "_INSTANCE_ENDPOINTID",
  "NetworkSettings.Gateway":                "_INSTANCE_GATEWAY",
  "NetworkSettings.GlobalIPv6Address":      "_INSTANCE_GLOBAL_IPV6_ADDRESS",
  "NetworkSettings.GlobalIPv6PrefixLen":    "_INSTANCE_GLOBAL_IPV6_PREFIX_LEN",
  "NetworkSettings.IPAddress":              "_INSTANCE_IPADDRESS",
  "NetworkSettings.IPPrefixLen":            "_INSTANCE_IP_PREFIX_LEN",
  "NetworkSettings.IPv6Gateway":            "_INSTANCE_IPV6_GATEWAY",
  "NetworkSettings.MacAddress":             "_INSTANCE_MAC",
  "NetworkSettings.Networks":               "_INSTANCE_NETWORKS"
}.toOrderedTable()

template extractDockerHashMap(value: Box): Box =
  let list     = unpack[seq[string]](value)
  var outTable = OrderedTableRef[string, string]()

  for item in list:
    let ix = item.find(hashHeader) # defined in docker_base.nim
    if ix == -1:
      warn("Unrecognized item in _REPO_DIGEST array: " & item)
      continue
    let
      k = item[0 ..< ix - 1] # Also chop off the @
      v = item[ix + len(hashHeader) .. ^1]

    outTable[k] = v

  pack(outTable)

template extractDockerHashList(value: Box): Box =
  let list    = unpack[seq[string]](value)
  var outList = seq[string](@[])

  for item in list:
    outList.add(item.extractDockerHash())

  pack[seq[string]](outList)

proc jsonOneAutoKey(node:        JsonNode,
                    chalkKey:    string,
                    dict:        ChalkDict,
                    reportEmpty: bool) =

  # We need _REPO_DIGESTS for attestation even if it's not subscribed to.
  if not chalkKey.isSubscribedKey() and chalkKey != "_REPO_DIGESTS":
    return
  var value = node.nimJsonToBox()

  if value.kind == MkObj: # Using this to represent 'null' / not provided
    return

  # Handle any transformations we know we need.
  case chalkKey
  of "_REPO_DIGESTS":
    value = extractDockerHashMap(value)
  of "_IMAGE_HOSTNAMES":
    value = extractDockerHashList(value)
  of "_INSTANCE_NAME":
    value    = extractBoxedDockerHash(value)
    let name = unpack[string](value)

    if name.startswith("/"):
      value = pack(name[1 .. ^1])
  else:
    discard

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

proc jsonAutoKey(map:  OrderedTable[string, string],
                 top:  JsonNode,
                 dict: ChalkDict) =
  let reportEmpty = chalkConfig.dockerConfig.getReportEmptyFields()

  for jsonKey, chalkKey in map:
    let subJsonOpt = top.getPartialJsonObject(jsonKey)

    if subJsonOpt.isNone():
      continue

    jsonOneAutoKey(subJsonOpt.get(), chalkKey, dict, reportEmpty)

template inspectCommon(map=dockerImageAutoMap) =
  chalk.imageId    = chalk.cachedHash
  chalk.setIfNeeded("_IMAGE_ID", chalk.cachedHash)
  chalk.setIfNeeded("_OP_ALL_IMAGE_METADATA", contents.nimJsonToBox())

  jsonAutoKey(map, contents, chalk.collectedData)

  if "_REPO_DIGESTS" in chalk.collectedData:
    let
      box  = chalk.collectedData["_REPO_DIGESTS"]
      info = unpack[OrderedTableRef[string, string]](box)
    for k, v in info:
      trace("Image ID is: " & chalk.imageId)
      trace("Repo Digest: " & v)
      if chalk.repo != "" and chalk.repo != k:
        warn("Changing repo from " & chalk.repo & " to: " & k)
      chalk.setIfNeeded("_STORE_URI", "https://" & k & "@sha256:" & v)
      chalk.repo     = k
      chalk.repoHash = v
      if chalk.containerId == "":
        if chalk.tag == "":
          chalk.userRef = chalk.repo
        else:
          chalk.userRef = chalk.repo & ":" & chalk.tag
        chalk.name = chalk.userRef
      break

proc inspectImage(chalk: ChalkObj): bool {.discardable.} =
  let
    cmdOut = runDockerGetEverything(@["inspect", chalk.name])

  if cmdOut.getExit() != 0:
    info(chalk.name & ": Docker inspect image failed: " & cmdOut.getStdErr())
    return false

  let contents = cmdOut.getStdOut().parseJson().getElems()[0]

  chalk.cachedHash = contents["Id"].getStr().extractDockerHash()
  if "_OP_ARTIFACT_TYPE" notin chalk.collectedData:
    chalk.setIfNeeded("_OP_ARTIFACT_TYPE", artTypeDockerImage)
  inspectCommon()

  return true

proc inspectContainer(chalk: ChalkObj) =
  let
    id     = chalk.userRef
    cmdOut = runDockerGetEverything(@["container", "inspect", id])

  if cmdout.getExit() != 0:
    warn(chalk.userRef & ": Container inspection failed (no longer running?)")
    return

  let
    contents = cmdOut.getStdout().parseJson().getElems()[0]

  chalk.cachedHash  = contents["Image"].getStr().extractDockerHash()
  chalk.containerId = contents["Id"].getStr()
  chalk.name        = contents["Name"].getStr()

  if chalk.name.startsWith("/"):
    chalk.name = chalk.name[1 .. ^1]

  chalk.setIfNeeded("_OP_ARTIFACT_TYPE", artTypeDockerContainer)
  chalk.resourceType = {ResourceContainer}
  inspectCommon(dockerContainerAutoMap)

proc inspectArtifact(chalk: ChalkObj) {.inline.} =
  if chalk.containerId != "":
    chalk.inspectContainer()
    if chalk.cachedHash != "":
      chalk.imageId = chalk.cachedHash
  if chalk.containerId == "":
    chalk.resourceType = {ResourceImage}
  chalk.inspectImage()

proc scanOne*(codec: Plugin, item: string): Option[ChalkObj]
    {.exportc, cdecl.} =

  let chalk = newChalk(name = item, tag = item, codec = codec)

  # Call docker images first, and if there's no shortId we found 0.
  info("Extracting basic image info.")
  if not chalk.extractBasicImageInfo():
    chalk.inspectContainer()
    if chalk.containerId == "" and not chalk.inspectImage():
      return none(ChalkObj)

  return some(chalk)

proc dockerGetRunTimeArtifactInfo*(self: Plugin, chalk: ChalkObj, ins: bool):
                                 ChalkDict {.exportc, cdecl.} =
  result = ChalkDict()
  # If a container name / id was passed, it got inspected during scan,
  # but images did not.
  if ResourceContainer notin chalk.resourceType:
    chalk.inspectArtifact()

proc dockerExtractChalkMark*(chalk: ChalkObj): ChalkDict {.exportc, cdecl.} =
  if chalk.repo != "":
    result = chalk.extractAttestationMark()

  if result != nil:
    info(chalk.name & ": Chalk mark successfully extracted from attestation.")
    chalk.signed = true
    return

  result = chalk.extractImageMark()
  if result != nil:
    info(chalk.name & ": Chalk mark extracted from base image.")
    return
  if chalk.containerId != "":
    result = chalk.extractContainerMark()
    if result != nil:
      info(chalk.name & ": Chalk mark extracted from running container")
      return

  warn(chalk.name & ": No chalk mark extracted.")
  addUnmarked(chalk.name)

proc loadCodecDocker*() =
  newCodec("docker",
           rtArtCallback = RunTimeArtifactCb(dockerGetRunTimeArtifactInfo),
           getChalkId    = ChalkIdCb(dockerGetChalkId))
