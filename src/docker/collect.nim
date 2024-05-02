##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## module for collecting docker information into chalk data-structures
##
## collect - use inspection result to load info into chalk

import std/[json]
import ".."/[config, chalkjson, util]
import "."/[inspect, json, hash]

# https://docs.docker.com/engine/api/v1.44/#tag/Image/operation/ImageInspect
# https://github.com/opencontainers/image-spec/blob/main/config.md
#
# These are the keys we can auto-convert without any special-casing.
# Types of the JSON will be checked against the key's declared type.
let dockerImageAutoMap: JsonToChalkKeysMapping = {
  "RepoTags":                                   ("_REPO_TAGS", identity),
  "RepoDigests":                                ("_REPO_DIGESTS", JsonTransformer((x: JsonNode) =>
                                                   `%`(extractDockerHashMap(x.getStrElems())))),
  "Comment":                                    ("_IMAGE_COMMENT", identity), # local-only
  "Created":                                    ("_IMAGE_CREATION_DATETIME", identity),
  "DockerVersion":                              ("_IMAGE_DOCKER_VERSION", identity), # most of the time empty string
  "Author":                                     ("_IMAGE_AUTHOR", identity),
  "Architecture":                               ("_IMAGE_ARCHITECTURE", identity),
  "Variant":                                    ("_IMAGE_VARIANT", identity),
  "Os":                                         ("_IMAGE_OS", identity),
  "OsVersion":                                  ("_IMAGE_OS_VERSION", identity), # local-only
  "os.version":                                 ("_IMAGE_OS_VERSION", identity), # remote-only
  "Size":                                       ("_IMAGE_SIZE", identity),
  "CompressedSize":                             ("_IMAGE_COMPRESSED_SIZE", identity), # injected in remote manifest processing
  "RootFS.Type":                                ("_IMAGE_ROOT_FS_TYPE", identity),
  "RootFS.Layers":                              ("_IMAGE_ROOT_FS_LAYERS", identity),
  "Config.Shell":                               ("_IMAGE_SHELL", identity),
  "Config.Entrypoint":                          ("_IMAGE_ENTRYPOINT", identity),
  "Config.Cmd":                                 ("_IMAGE_CMD", identity),
  "Config.Hostname":                            ("_IMAGE_HOSTNAMES", JsonTransformer((x: JsonNode) =>
                                                   `%`(extractDockerHashList(x.getStrElems())))),
  "Config.Domainname":                          ("_IMAGE_DOMAINNAME", identity),
  "Config.User":                                ("_IMAGE_USER", identity),
  "Config.ExposedPorts":                        ("_IMAGE_EXPOSEDPORTS", identity),
  "Config.Env":                                 ("_IMAGE_ENV", identity),
  "Config.Image":                               ("_IMAGE_NAME", identity),
  "Config.Healthcheck.Test":                    ("_IMAGE_HEALTHCHECK_TEST", identity),
  "Config.Healthcheck.Interval":                ("_IMAGE_HEALTHCHECK_INTERVAL", identity),
  "Config.Healthcheck.Timeout":                 ("_IMAGE_HEALTHCHECK_TIMEOUT", identity),
  "Config.Healthcheck.StartPeriod":             ("_IMAGE_HEALTHCHECK_START_PERIOD", identity),
  "Config.Healthcheck.StartInterval":           ("_IMAGE_HEALTHCHECK_START_INTERVAL", identity),
  "Config.Healthcheck.Retries":                 ("_IMAGE_HEALTHCHECK_RETRIES", identity),
  "Config.Volumes":                             ("_IMAGE_MOUNTS", identity),
  "Config.WorkingDir":                          ("_IMAGE_WORKINGDIR", identity),
  "Config.NetworkDisabled":                     ("_IMAGE_NETWORK_DISABLED", identity),
  "Config.MacAddress":                          ("_IMAGE_MAC_ADDR", identity),
  "Config.OnBuild":                             ("_IMAGE_ONBUILD", identity),
  "Config.Labels":                              ("_IMAGE_LABELS", identity),
  "Config.StopSignal":                          ("_IMAGE_STOP_SIGNAL", identity),
  "Config.StopTimeout":                         ("_IMAGE_STOP_TIMEOUT", identity),
  }.toOrderedTable()

let dockerContainerAutoMap: JsonToChalkKeysMapping = {
  "Name":                                       ("_INSTANCE_NAME", JsonTransformer((x: JsonNode) =>
                                                   `%`(x.getStr().extractDockerHash()))),
  "Id":                                         ("_INSTANCE_CONTAINER_ID", identity),
  "Created":                                    ("_INSTANCE_CREATION_DATETIME", identity),
  "Path":                                       ("_INSTANCE_ENTRYPOINT_PATH", identity),
  "Args":                                       ("_INSTANCE_ENTRYPOINT_ARGS", identity),
  "State.Status":                               ("_INSTANCE_STATUS", identity),
  "State.Pid":                                  ("_INSTANCE_PID", identity),
  "ResolvConfPath":                             ("_INSTANCE_RESOLVE_CONF_PATH", identity),
  "HostNamePath":                               ("_INSTANCE_HOSTNAME_PATH", identity),
  "HostsPath":                                  ("_INSTANCE_HOSTS_PATH", identity),
  "LogPath":                                    ("_INSTANCE_LOG_PATH", identity),
  "RestartCount":                               ("_INSTANCE_RESTART_COUNT", identity),
  "Driver":                                     ("_INSTANCE_DRIVER", identity),
  "Platform":                                   ("_INSTANCE_PLATFORM", identity),
  "MountLabel":                                 ("_INSTANCE_MOUNT_LABEL", identity),
  "ProcessLabel":                               ("_INSTANCE_PROCESS_LABEL", identity),
  "AppArmorProfile":                            ("_INSTANCE_APP_ARMOR_PROFILE", identity),
  "ExecIDs":                                    ("_INSTANCE_EXEC_IDS", identity),
  "HostConfig.Binds":                           ("_INSTANCE_BINDS", identity),
  "HostConfig.ContainerIDFile":                 ("_INSTANCE_CONTAINER_ID_FILE", identity),
  "HostConfig.LogConfig.Config":                ("_INSTANCE_LOG_CONFIG", identity),
  "HostConfig.NetworkMode":                     ("_INSTANCE_NETWORK_MODE", identity),
  "HostConfig.PortBindings":                    ("_INSTANCE_BOUND_PORTS", identity),
  "HostConfig.RestartPolicy.Name":              ("_INSTANCE_RESTART_POLICY_NAME", identity),
  "HostConfig.RestartPolicy.MaximumRetryCount": ("_INSTANCE_RESTART_RETRY_COUNT", identity),
  "HostConfig.AutoRemove":                      ("_INSTANCE_AUTOREMOVE", identity),
  "HostConfig.VolumeDriver":                    ("_INSTANCE_VOLUME_DRIVER", identity),
  "HostConfig.VolumesFrom":                     ("_INSTANCE_VOLUMES_FROM", identity),
  "HostConfig.ConsoleSize":                     ("_INSTANCE_CONSOLE_SIZE", identity),
  "HostConfig.CapAdd":                          ("_INSTANCE_ADDED_CAPS", identity),
  "HostConfig.CapDrop":                         ("_INSTANCE_DROPPED_CAPS", identity),
  "HostConfig.CgroupnsMode":                    ("_INSTANCE_CGROUP_NS_MODE", identity),
  "HostConfig.Dns":                             ("_INSTANCE_DNS", identity),
  "HostConfig.DnsOptions":                      ("_INSTANCE_DNS_OPTIONS", identity),
  "HostConfig.DnsSearch":                       ("_INSTANCE_DNS_SEARCH", identity),
  "HostConfig.ExtraHosts":                      ("_INSTANCE_EXTRA_HOSTS", identity),
  "HostConfig.GroupAdd":                        ("_INSTANCE_GROUP_ADD", identity),
  "HostConfig.IpcMode":                         ("_INSTANCE_IPC_MODE", identity),
  "HostConfig.Cgroup":                          ("_INSTANCE_CGROUP", identity),
  "HostConfig.Links":                           ("_INSTANCE_LINKS", identity),
  "HostConfig.OomScoreAdj":                     ("_INSTANCE_OOM_SCORE_ADJ", identity),
  "HostConfig.PidMode":                         ("_INSTANCE_PID_MODE", identity),
  "HostConfig.Privileged":                      ("_INSTANCE_IS_PRIVILEGED", identity),
  "HostConfig.PublishAllPorts":                 ("_INSTANCE_PUBLISH_ALL_PORTS", identity),
  "HostConfig.ReadonlyRootfs":                  ("_INSTANCE_READONLY_ROOT_FS", identity),
  "HostConfig.SecurityOpt":                     ("_INSTANCE_SECURITY_OPT", identity),
  "HostConfig.UTSMode":                         ("_INSTANCE_UTS_MODE", identity),
  "HostConfig.UsernsMode":                      ("_INSTANCE_USER_NS_MODE", identity),
  "HostConfig.ShmSize":                         ("_INSTANCE_SHM_SIZE", identity),
  "HostConfig.Runtime":                         ("_INSTANCE_RUNTIME", identity),
  "HostConfig.Isolation":                       ("_INSTANCE_ISOLATION", identity),
  "HostConfig.CpuShares":                       ("_INSTANCE_CPU_SHARES", identity),
  "HostConfig.Memory":                          ("_INSTANCE_MEMORY", identity),
  "HostConfig.NanoCpus":                        ("_INSTANCE_NANO_CPUS", identity),
  "HostConfig.CgroupParent":                    ("_INSTANCE_CGROUP_PARENT", identity),
  "HostConfig.BlkioWeight":                     ("_INSTANCE_BLOCKIO_WEIGHT", identity),
  "HostConfig.BlkioWeightDevice":               ("_INSTANCE_BLOCKIO_WEIGHT_DEVICE", identity),
  "HostConfig.BlkioDeviceReadBps":              ("_INSTANCE_BLOCKIO_DEVICE_READ_BPS", identity),
  "HostConfig.BlkioDeviceWriteBps":             ("_INSTANCE_BLOCKIO_DEVICE_WRITE_BPS", identity),
  "HostConfig.BlkioDeviceReadIOps":             ("_INSTANCE_BLOCKIO_DEVICE_READ_IOPS", identity),
  "HostConfig.BlkioDeviceWriteIops":            ("_INSTANCE_BLOCKIO_DEVICE_WRITE_IOPS", identity),
  "HostConfig.CpuPeriod":                       ("_INSTANCE_CPU_PERIOD", identity),
  "HostConfig.CpuQuota":                        ("_INSTANCE_CPU_QUOTA", identity),
  "HostConfig.CpuRealtimePeriod":               ("_INSTANCE_CPU_REALTIME_PERIOD", identity),
  "HostConfig.CpuRealtimeRuntime":              ("_INSTANCE_CPU_REALTIME_RUNTIME", identity),
  "HostConfig.CpusetCpus":                      ("_INSTANCE_CPUSET_CPUS", identity),
  "HostConfig.CpusetMems":                      ("_INSTANCE_CPUSET_MEMS", identity),
  "HostConfig.Devices":                         ("_INSTANCE_DEVICES", identity),
  "HostConfig.DeviceCgroupRules":               ("_INSTANCE_CGROUP_RULES", identity),
  "HostConfig.DeviceRequests":                  ("_INSTANCE_DEVICE_REQUESTS", identity),
  "HostConfig.MemoryReservation":               ("_INSTANCE_MEMORY_RESERVATION", identity),
  "HostConfig.MemorySwap":                      ("_INSTANCE_MEMORY_SWAP", identity),
  "HostConfig.MemorySwappiness":                ("_INSTANCE_MEMORY_SWAPPINESS", identity),
  "HostConfig.OomKillDisable":                  ("_INSTANCE_OOM_KILL_DISABLE", identity),
  "HostConfig.PidsLimit":                       ("_INSTANCE_PIDS_LIMIT", identity),
  "HostConfig.Ulimits":                         ("_INSTANCE_ULIMITS", identity),
  "HostConfig.CpuCount":                        ("_INSTANCE_CPU_COUNT", identity),
  "HostConfig.CpuPercent":                      ("_INSTANCE_CPU_PERCENT", identity),
  "HostConfig.IOMaximumIOps":                   ("_INSTANCE_IO_MAX_IOPS", identity),
  "HostConfig.IOMaximumBandwidth":              ("_INSTANCE_IO_MAX_BPS", identity),
  "HostConfig.MaskedPaths":                     ("_INSTANCE_MASKED_PATHS", identity),
  "HostConfig.ReadonlyPaths":                   ("_INSTANCE_READONLY_PATHS", identity),
  "GraphDriver":                                ("_INSTANCE_STORAGE_METADATA", identity),
  "Mounts":                                     ("_INSTANCE_MOUNTS", identity),
  "Config.Hostname":                            ("_INSTANCE_HOSTNAME", identity),
  "Config.Domainname":                          ("_INSTANCE_DOMAINNAME", identity),
  "Config.User":                                ("_INSTANCE_USER", identity),
  "Config.AttachStdin":                         ("_INSTANCE_ATTACH_STDIN", identity),
  "Config.AttachStdout":                        ("_INSTANCE_ATTACH_STDOUT", identity),
  "Config.AttachStderr":                        ("_INSTANCE_ATTACH_STDERR", identity),
  "Config.ExposedPorts":                        ("_INSTANCE_EXPOSED_PORTS", identity),
  "Config.Tty":                                 ("_INSTANCE_HAS_TTY", identity),
  "Config.OpenStdin":                           ("_INSTANCE_OPEN_STDIN", identity),
  "Config.StdinOnce":                           ("_INSTANCE_STDIN_ONCE", identity),
  "Config.Env":                                 ("_INSTANCE_ENV", identity),
  "Config.Cmd":                                 ("_INSTANCE_CMD", identity),
  "Config.Image":                               ("_INSTANCE_CONFIG_IMAGE", identity),
  "Config.Volumes":                             ("_INSTANCE_VOLUMES", identity),
  "Config.WorkingDir":                          ("_INSTANCE_WORKING_DIR", identity),
  "Config.Entrypoint":                          ("_INSTANCE_ENTRYPOINT", identity),
  "Config.OnBuild":                             ("_INSTANCE_ONBUILD", identity),
  "Config.Labels":                              ("_INSTANCE_LABELS", identity),
  "NetworkSettings.Bridge":                     ("_INSTANCE_BRIDGE", identity),
  "NetworkSettings.SandboxId":                  ("_INSTANCE_SANDBOXID", identity),
  "NetworkSettings.HairpinMode":                ("_INSTANCE_HAIRPINMODE", identity),
  "NetworkSettings.LinkLocalIPv6Address":       ("_INSTANCE_LOCAL_IPV6", identity),
  "NetworkSettings.LinkLocalIPv6PrefixLen":     ("_INSTANCE_LOCAL_IPV6_PREFIX_LEN", identity),
  "NetworkSettings.Ports":                      ("_INSTANCE_BOUND_PORTS", identity),
  "NetworkSettings.SanboxKey":                  ("_INSTANCE_SANDBOX_KEY", identity),
  "NetworkSettings.SecondaryIPAddresses":       ("_INSTANCE_SECONDARY_IPS", identity),
  "NetworkSettings.SecondaryIPv6Addresses":     ("_INSTANCE_SECONDARY_IPV6_ADDRS", identity),
  "NetworkSettings.EndpointID":                 ("_INSTANCE_ENDPOINTID", identity),
  "NetworkSettings.Gateway":                    ("_INSTANCE_GATEWAY", identity),
  "NetworkSettings.GlobalIPv6Address":          ("_INSTANCE_GLOBAL_IPV6_ADDRESS", identity),
  "NetworkSettings.GlobalIPv6PrefixLen":        ("_INSTANCE_GLOBAL_IPV6_PREFIX_LEN", identity),
  "NetworkSettings.IPAddress":                  ("_INSTANCE_IPADDRESS", identity),
  "NetworkSettings.IPPrefixLen":                ("_INSTANCE_IP_PREFIX_LEN", identity),
  "NetworkSettings.IPv6Gateway":                ("_INSTANCE_IPV6_GATEWAY", identity),
  "NetworkSettings.MacAddress":                 ("_INSTANCE_MAC", identity),
  "NetworkSettings.Networks":                   ("_INSTANCE_NETWORKS", identity),
}.toOrderedTable()

proc collectCommon(chalk: ChalkObj, contents: JsonNode, map = dockerImageAutoMap) =
  chalk.setIfNeeded("_IMAGE_ID", chalk.imageId)
  chalk.setIfNeeded("_OP_ALL_IMAGE_METADATA", contents.nimJsonToBox())
  chalk.collectedData.mapFromJson(contents, map)

proc collectImage*(chalk: ChalkObj, name: string) =
  let
    contents          = inspectImageJson(name) # TODO filter by platform
    id                = contents["Id"].getStr().extractDockerHash()
    tags              = contents["RepoTags"].getElems()
    digests           = contents["RepoDigests"].getElems()
    userRef           = name.extractDockerHash()
  if chalk.cachedHash == "":
    chalk.cachedHash  = id
  if len(tags) > 0:
    let (repo, tag)   = tags[0].getStr().splitBy(":", "latest")
    chalk.repo        = repo
    chalk.tag         = tag
  if len(digests) > 0:
    chalk.imageDigest = digests[0].getStr().extractDockerHash()
  if chalk.name == "":
    chalk.name        = chalk.dockerTag(default = userRef)
  if chalk.userRef == "":
    chalk.userRef     = chalk.dockerTag(default = userRef)
  # we could be inspecting container image hence resource type should be untouched
  if ResourceContainer notin chalk.resourceType:
    chalk.setIfNeeded("_OP_ARTIFACT_TYPE", artTypeDockerImage)
  chalk.resourceType.incl(ResourceImage)
  chalk.imageId       = id
  chalk.collectCommon(contents, dockerImageAutoMap)
  if "_REPO_DIGESTS" in chalk.collectedData:
    let
      box  = chalk.collectedData["_REPO_DIGESTS"]
      info = unpack[OrderedTableRef[string, string]](box)
    for k, v in info:
      trace("Image ID is: " & chalk.imageId)
      trace("Repo Digest: " & v)
      if chalk.repo != "" and chalk.repo != k:
        warn("Changing repo from " & chalk.repo & " to: " & k)
      chalk.repo        = k
      chalk.imageDigest = v
      break

proc collectImage*(chalk: ChalkObj) =
  if chalk.imageId == "":
    raise newException(ValueError, "docker: no image name/id to inspect")
  chalk.collectImage(chalk.imageId)

proc collectContainer*(chalk: ChalkObj, name: string) =
  let
    contents          = inspectContainerJson(name)
    id                = contents["Id"].getStr()
    image             = contents["Image"].getStr().extractDockerHash()
  if chalk.cachedHash  == "":
    # why are we using image hash for containers?
    chalk.cachedHash  = image
  if chalk.name == "":
    # container name can start with `/`
    chalk.name        = contents["Name"].getStr().strip(chars = {'/'})
  chalk.imageId       = image
  chalk.containerId   = id
  chalk.resourceType.incl(ResourceContainer)
  chalk.setIfNeeded("_OP_ARTIFACT_TYPE", artTypeDockerContainer)
  chalk.collectCommon(contents, dockerContainerAutoMap)
