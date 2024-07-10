##
## Copyright (c) 2023-2024, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Query common AWS metadata va IMDSv2

import std/[httpclient, net, strutils, json]
import ".."/[config, plugin_api, chalkjson]

const
  awsBaseUri     = "http://169.254.169.254/latest/"
  awsMdUri       = awsBaseUri & "meta-data/"
  awsDynUri      = awsBaseUri & "dynamic/"
  # this env var is undocumented in GCP, but does exist in GoogleCloudPlatform repos:
  # - https://github.com/GoogleCloudPlatform/functions-framework-php/blob/e3a4d658ab3fd127931818d26aaa3e29c622f40c/router.php#L46
  # - https://github.com/GoogleCloudPlatform/functions-framework-python/blob/02472e7315d0fd642db26441b3cb21f799906739/src/functions_framework/_http/gunicorn.py#L35
  # - https://github.com/GoogleCloudPlatform/functions-framework-nodejs/blob/0bb6efb6c6a915bc96c50ed5aeda79d7b8e3b15e/src/options.ts#L121
  CLOUD_RUN_TIMEOUT_SECONDS = "CLOUD_RUN_TIMEOUT_SECONDS"
  K_SERVICE = "K_SERVICE"
  # special keys for special processing
  AWS_IDENTITY_CREDENTIALS_SECURITY_CREDS = "_AWS_IDENTITY_CREDENTIALS_EC2_SECURITY_CREDENTIALS_EC2_INSTANCE"

proc getAwsToken(): Option[string] =
  let
    url      = awsBaseUri & "api/token"
    hdrs     = newHttpHeaders([("X-aws-ec2-metadata-token-ttl-seconds", "10")])
    response = safeRequest(url        = url,
                           httpMethod = HttpPut,
                           timeout    = 250, # 1/4 of a second
                           headers    = hdrs)
    body     = response.body().strip()

  if not response.code.is2xx():
    trace("Could not retrieve IMDSv2 token from: " & url & " - " & response.status & ": " & body)
    return none(string)

  trace("Retrieved AWS metadata token")
  return some(body)

proc hitProviderEndpoint(path: string, hdrs: HttpHeaders): Option[string] =
  let
    response = safeRequest(url        = path,
                           httpMethod = HttpGet,
                           timeout    = 250, # 1/4 of a second
                           headers    = hdrs)
    body     = response.body().strip()

  if not response.code.is2xx():
    trace("Could not retrieve metadata from: " & path & " - " & response.status & ": " & body)
    return none(string)

  if body == "":
    # some paths are expected to be empty so this is not an error
    trace("Got empty metadata from: " & path)

  trace("Retrieved metadata from: " & path)
  return some(body)

template oneItem(keyname: string, url: string) =
  if isSubscribedKey(keyname):
    let
      hdrs      = newHttpHeaders([("X-aws-ec2-metadata-token", token)])
      resultOpt = hitProviderEndpoint(url, hdrs)
    if resultOpt.isSome():
      setIfNotEmpty(result, keyname, resultOpt.get())

template listKey(keyname: string, url: string) =
  if isSubscribedKey(keyname):
    let
      hdrs      = newHttpHeaders([("X-aws-ec2-metadata-token", token)])
      resultOpt = hitProviderEndpoint(url, hdrs)
    if resultOpt.isSome():
      setIfNeeded(result, keyname, resultOpt.get().splitLines())

template jsonKey(keyname: string, url: string) =
  if isSubscribedKey(keyname):
    let
      hdrs      = newHttpHeaders([("X-aws-ec2-metadata-token", token)])
      resultOpt = hitProviderEndpoint(url, hdrs)
    if resultOpt.isSome():
      let value = resultOpt.get()
      # imdsv2 does not respond with application/json content-type
      # header and so we check first char before attempting json parse
      if not value.startswith("{"):
        trace("IMDSv2 didnt respond with json object. Ignoring it. URL: " & url)
      else:
        try:
          let jsonValue = parseJson(value)
          # redact some keys as they contain sensitive api keys
          case keyname
          of AWS_IDENTITY_CREDENTIALS_SECURITY_CREDS:
            jsonValue["SecretAccessKey"] = newJString("<<redacted>>")
            jsonValue["Token"] = newJString("<<redacted>>")
          setIfNeeded(result, keyname, jsonValue.nimJsonToBox())
        except:
          trace("IMDSv2 responded with invalid json for URL: " & url)

template extractJsonKey(keyname: string, url: string, subkey: string) =
  if isSubscribedKey(keyname):
    let
      hdrs      = newHttpHeaders([("X-aws-ec2-metadata-token", token)])
      resultOpt = hitProviderEndpoint(url, hdrs)
    if resultOpt.isSome():
      let value = resultOpt.get()
      # imdsv2 does not respond with application/json content-type
      # header and so we check first char before attempting json parse
      if not value.startswith("{"):
        trace("Provider Didn't respond with json object. Ignoring it. URL: " & url)
      else:
        try:
          let jsonValue = parseJson(value)
          setIfNotEmpty(result, keyname, jsonValue[subkey].getStr())
        except:
          trace("Could not set " & keyname & " with subkey " & subkey & " from " & url)

template getTags(keyname: string, url: string) =
  if isSubscribedKey(keyname):
    let
      hdrs      = newHttpHeaders([("X-aws-ec2-metadata-token", token)])
      resultOpt = hitProviderEndpoint(url, hdrs)
    if resultOpt.isSome():
      let
        value = resultOpt.get()
        tags  = ChalkDict()
      # tag reponse is a newline-delimited list of tags
      # which are set on the instance
      # to each tag values an endpoint needs to be hit
      # for each tag key to get its value
      for line in value.split("\n"):
        let name = line.strip()
        if name == "":
          continue
        let tagOpt = hitProviderEndpoint(url & "/" & name, hdrs)
        if tagOpt.isSome():
          tags[name] = pack(tagOpt.get())
        setIfNeeded(result, keyname, tags)

type
  HostKind = enum
    hkUnknown = "unknown"
    hkAws = "aws"
    hkAzure = "azure"
    hkGcp = "gcp"

proc getAzureMetadata(): ChalkDict =
  result = ChalkDict()
  result.setIfNeeded("_OP_CLOUD_PROVIDER", $hkAzure)

  if isSubscribedKey("_AZURE_INSTANCE_METADATA") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_IP") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_REGION") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_TAGS") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_ACCOUNT_INFO") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_SERVICE_TYPE") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_INSTANCE_TYPE"):
    let resultOpt = hitProviderEndpoint("http://169.254.169.254/metadata/instance?api-version=2021-02-01", newHttpHeaders([("Metadata", "true")]))
    if not resultOpt.isSome():
      trace("Did not get metadata back from Azure endpoint")
      return
    let value = resultOpt.get()
    if not value.startswith("{"):
      trace("Azure metadata didnt respond with json object. Ignoring it")
      return
    try:
      let jsonValue = parseJson(value)
      setIfNeeded(result, "_AZURE_INSTANCE_METADATA", jsonValue.nimJsonToBox())
      try:
        setIfNeeded(result, "_OP_CLOUD_PROVIDER_TAGS", jsonValue["compute"]["tagsList"].nimJsonToBox())
      except:
        trace("Could not insert _OP_CLOUD_PROVIDER_TAGS for azure")
      try:
        for iface in jsonValue["network"]["interface"]:
          var found = false
          for address in iface["ipv4"]["ipAddress"]:
            let ipv4 = address["publicIpAddress"].getStr()
            if ipv4 != "":
              found = true
              # just pick the first
              setIfNeeded(result, "_OP_CLOUD_PROVIDER_IP", ipv4)
              break
          if found:
            break
      except:
        trace("Could not insert _OP_CLOUD_PROVIDER_IP for azure")
      try:
        setIfNeeded(result, "_OP_CLOUD_PROVIDER_ACCOUNT_INFO", jsonValue["compute"]["subscriptionId"].getStr())
      except:
        trace("Could not insert _OP_CLOUD_PROVIDER_ACCOUNT_INFO for azure")
      try:
        setIfNeeded(result, "_OP_CLOUD_PROVIDER_REGION", jsonValue["compute"]["location"].getStr())
      except:
        trace("Could not insert _OP_CLOUD_PROVIDER_REGION for azure")
      try:
        setIfNeeded(result, "_OP_CLOUD_PROVIDER_INSTANCE_TYPE", jsonValue["compute"]["vmSize"].getStr())
      except:
        trace("Could not insert _OP_CLOUD_PROVIDER_INSTANCE_TYPE for azure")
    except:
      trace("Azure metadata responded with invalid json")

proc getGcpMetadata(): ChalkDict =
  result = ChalkDict()
  result.setIfNeeded("_OP_CLOUD_PROVIDER", $hkGcp)

  if isSubscribedKey("_GCP_INSTANCE_METADATA") or
      isSubscribedKey("_GCP_PROJECT_METADATA") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_IP") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_REGION") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_TAGS") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_ACCOUNT_INFO") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_SERVICE_TYPE") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_INSTANCE_TYPE"):
    trace("Querying for GCP metadata")
    if isSubscribedKey("_GCP_PROJECT_METADATA"):
      let projectOpt = hitProviderEndpoint("http://169.254.169.254/computeMetadata/v1/project/?recursive=true", newHttpHeaders([("Metadata-Flavor", "Google")]))
      if projectOpt.isSome():
        try:
          let valueProj = projectOpt.get()
          if valueProj.startswith("{"):
            let jsonProjValue = parseJson(valueProj)
            setIfNeeded(result, "_GCP_PROJECT_METADATA", jsonProjValue.nimJsonToBox())
          else:
            trace("GCP project metadata didnt respond with json object. Ignoring it")
        except:
          trace("Could not insert _GCP_PROJECT_METADATA")

    let resultOpt = hitProviderEndpoint("http://169.254.169.254/computeMetadata/v1/instance/?recursive=true", newHttpHeaders([("Metadata-Flavor", "Google")]))
    if not resultOpt.isSome():
      trace("Did not get instance metadata back from GCP endpoint")
      return
    let value = resultOpt.get()
    if not value.startswith("{"):
      trace("GCP metadata didnt respond with json object. Ignoring it")
      return
    try:
      let jsonValue = parseJson(value)
      try:
        setIfNeeded(result, "_GCP_INSTANCE_METADATA", jsonValue.nimJsonToBox())
      except:
        trace("Could not insert _GCP_INSTANCE_METADATA")
      try:
        setIfNeeded(result, "_OP_CLOUD_PROVIDER_TAGS", jsonValue["tags"].nimJsonToBox())
      except:
        trace("Could not insert _OP_CLOUD_PROVIDER_TAGS for gcp")
      try:
        setIfNeeded(result, "_OP_CLOUD_PROVIDER_ACCOUNT_INFO", jsonValue["serviceAccounts"].nimJsonToBox())
      except:
        trace("Could not insert _OP_CLOUD_PROVIDER_TAGS for gcp")
      try:
        for iface in jsonValue["networkInterfaces"]:
          var found = false
          for config in iface["accessConfigs"]:
            let ipv4 = config["externalIp"].getStr()
            if ipv4 != "":
              found = true
              # just pick the first
              setIfNeeded(result, "_OP_CLOUD_PROVIDER_IP", ipv4)
              break
          if found:
            break
      except:
        trace("Could not insert _OP_CLOUD_PROVIDER_IP for gcp")
      try:
        setIfNeeded(result, "_OP_CLOUD_PROVIDER_REGION", jsonValue["zone"].getStr().split("/")[^1])
      except:
        trace("Could not insert _OP_CLOUD_PROVIDER_REGION for gcp")
      try:
        setIfNeeded(result, "_OP_CLOUD_PROVIDER_INSTANCE_TYPE", jsonValue["machineType"].getStr().split("/")[^1])
      except:
        trace("Could not insert _OP_CLOUD_PROVIDER_INSTANCE_TYPE for gcp")
    except:
      trace("GCP metadata responded with invalid json")

    if getEnv(K_SERVICE) != "" and getEnv(CLOUD_RUN_TIMEOUT_SECONDS) != "":
      result["_OP_CLOUD_PROVIDER_SERVICE_TYPE"] = pack("gcp_cloud_run_service")

proc getAwsMetadata(): ChalkDict =
  result = ChalkDict()
  result.setIfNeeded("_OP_CLOUD_PROVIDER", $hkAws)

  var tokenOpt: Option[string]

  try:
    tokenOpt = getAwsToken()
    if tokenOpt.isNone():
      trace("IMDSv2 token not available.")
      return
  except:
    trace("IMDSv2 metadata not available.")
    # if we do not find imdsv2 but we have a kubernetes cluster and running
    # in AWS EC2, most likely we are running in an eks fargate cluster.
    # https://docs.aws.amazon.com/eks/latest/userguide/fargate.html
    let k8sPort = getEnv("KUBERNETES_PORT")
    let k8sServiceHost = getEnv("KUBERNETES_SERVICE_HOST")
    if k8sPort != "" or k8sServiceHost != "":
      # this is most definitely fargate at this point, but might have FP, so
      # leaving EKS to be on the safe side
      result["_OP_CLOUD_PROVIDER_SERVICE_TYPE"] = pack("aws_eks")
    return

  let
    token = tokenOpt.get()

  # at this point we have metadata, differentiate between eks, ec2, ecs
  if isSubscribedKey("_OP_CLOUD_PROVIDER_SERVICE_TYPE"):
    # XXX ignoring task metadata v2 which is no longer actively maintained
    let ecsv3 = getEnv("ECS_CONTAINER_METADATA_URI")
    let ecsv4 = getEnv("ECS_CONTAINER_METADATA_URI_V4")
    if ecsv3 != "" or ecsv4 != "":
      result["_OP_CLOUD_PROVIDER_SERVICE_TYPE"] = pack("aws_ecs")
    else:
      let k8sPort = getEnv("KUBERNETES_PORT")
      let k8sServiceHost = getEnv("KUBERNETES_SERVICE_HOST")
      if k8sPort != "" or k8sServiceHost != "":
        # XXX this might have FP in case of a user that has deployed k8s within
        # a single EC2 instance, so should differentiate from the rest of the
        # IMDS metadata versions
        result["_OP_CLOUD_PROVIDER_SERVICE_TYPE"] = pack("aws_eks")
      else:
        result["_OP_CLOUD_PROVIDER_SERVICE_TYPE"] = pack("aws_ec2")

  # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-categories.html
  # dynamic entries
  # dynamic data categories
  jsonKey("_AWS_INSTANCE_IDENTITY_DOCUMENT",         awsDynUri & "instance-identity/document")
  extractJsonKey("_OP_CLOUD_PROVIDER_ACCOUNT_INFO",  awsDynUri & "instance-identity/document", "accountId")
  extractJsonKey("_OP_CLOUD_PROVIDER_INSTANCE_TYPE", awsDynUri & "instance-identity/document", "instanceType")
  extractJsonKey("_OP_CLOUD_PROVIDER_INSTANCE_ARCH", awsDynUri & "instance-identity/document", "architecture")
  oneItem("_AWS_INSTANCE_IDENTITY_PKCS7",            awsDynUri & "instance-identity/pkcs7")
  oneItem("_AWS_INSTANCE_IDENTITY_SIGNATURE",        awsDynUri & "instance-identity/signature")
  oneItem("_AWS_INSTANCE_MONITORING",                awsDynUri & "fws/instance-monitoring")

  oneItem("_AWS_AMI_ID",                             awsMdUri & "ami-id")
  oneItem("_AWS_AMI_LAUNCH_INDEX",                   awsMdUri & "ami-launch-index")
  oneItem("_AWS_AMI_MANIFEST_PATH",                  awsMdUri & "ami-manifest-path")
  oneItem("_AWS_ANCESTOR_AMI_IDS",                   awsMdUri & "ancestor-ami-ids")
  oneItem("_AWS_AUTOSCALING_TARGET_LIFECYCLE_STATE", awsMdUri & "autoscaling/target-lifecycle-state")
  oneItem("_AWS_AZ",                                 awsMdUri & "placement/availability-zone")
  oneItem("_AWS_AZ_ID",                              awsMdUri & "placement/availability-zone-id")
  oneItem("_AWS_BLOCK_DEVICE_MAPPING_AMI",           awsMdUri & "block-device-mapping/ami")
  oneItem("_AWS_BLOCK_DEVICE_MAPPING_ROOT",          awsMdUri & "block-device-mapping/root")
  oneItem("_AWS_BLOCK_DEVICE_MAPPING_SWAP",          awsMdUri & "block-device-mapping/swap")
  oneItem("_AWS_DEDICATED_HOST_ID",                  awsMdUri & "placement/host-id")
  oneItem("_AWS_EVENTS_MAINTENANCE_HISTORY",         awsMdUri & "events/maintenance/history")
  oneItem("_AWS_EVENTS_MAINTENANCE_SCHEDULED",       awsMdUri & "events/maintenance/scheduled")
  oneItem("_AWS_EVENTS_RECOMMENDATIONS_REBALANCE",   awsMdUri & "events/recommendations/rebalance")
  oneItem("_AWS_HOSTNAME",                           awsMdUri & "hostname")
  oneItem("_AWS_INSTANCE_ACTION",                    awsMdUri & "instance-action")
  oneItem("_AWS_INSTANCE_ID",                        awsMdUri & "instance-id")
  oneItem("_AWS_INSTANCE_LIFE_CYCLE",                awsMdUri & "instance-life-cycle")
  oneItem("_AWS_INSTANCE_TYPE",                      awsMdUri & "instance-type")
  oneItem("_AWS_IPV6_ADDR",                          awsMdUri & "ipv6")
  oneItem("_AWS_KERNEL_ID",                          awsMdUri & "kernel-id")
  oneItem("_AWS_LOCAL_HOSTNAME",                     awsMdUri & "local-hostname")
  oneItem("_AWS_LOCAL_IPV4_ADDR",                    awsMdUri & "local-ipv4")
  oneItem("_AWS_MAC",                                awsMdUri & "mac")
  oneItem("_AWS_METRICS_VHOSTMD",                    awsMdUri & "metrics/vhostmd")
  oneItem("_AWS_OPENSSH_PUBKEY",                     awsMdUri & "public-keys/0/openssh-key")
  oneItem("_AWS_PARTITION_NAME",                     awsMdUri & "services/partition")
  oneItem("_AWS_PARTITION_NUMBER",                   awsMdUri & "placement/partition-number")
  oneItem("_AWS_PLACEMENT_GROUP",                    awsMdUri & "placement/group-name")
  oneItem("_AWS_PRODUCT_CODES",                      awsMdUri & "product-codes")
  oneItem("_AWS_PUBLIC_HOSTNAME",                    awsMdUri & "public-hostname")
  oneItem("_AWS_PUBLIC_IPV4_ADDR",                   awsMdUri & "public-ipv4")
  oneItem("_OP_CLOUD_PROVIDER_IP",                   awsMdUri & "public-ipv4")
  oneItem("_AWS_RAMDISK_ID",                         awsMdUri & "ramdisk-id")
  oneItem("_AWS_REGION",                             awsMdUri & "placement/region")
  oneItem("_OP_CLOUD_PROVIDER_REGION",               awsMdUri & "placement/region")
  oneItem("_AWS_RESERVATION_ID",                     awsMdUri & "reservation-id")
  oneItem("_AWS_RESOURCE_DOMAIN",                    awsMdUri & "services/domain")
  oneItem("_AWS_SPOT_INSTANCE_ACTION",               awsMdUri & "spot/instance-action")
  oneItem("_AWS_SPOT_TERMINATION_TIME",              awsMdUri & "spot/termination-time")

  listKey("_AWS_SECURITY_GROUPS",                    awsMdUri & "security-groups")

  jsonKey("_AWS_IAM_INFO",                           awsMdUri & "iam/info")
  jsonKey("_AWS_IDENTITY_CREDENTIALS_EC2_INFO",      awsMdUri & "identity-credentials/ec2/info")
  jsonKey(AWS_IDENTITY_CREDENTIALS_SECURITY_CREDS,   awsMdUri & "identity-credentials/ec2/security-credentials/ec2-instance")

  getTags("_AWS_TAGS",                               awsMdUri & "tags/instance")
  getTags("_OP_CLOUD_PROVIDER_TAGS",                 awsMdUri & "tags/instance")

  if "_AWS_MAC" in result:
    let mac = unpack[string]result["_AWS_MAC"]
    oneItem("_AWS_VPC_ID",                           awsMdUri & "network/interfaces/macs/" & mac & "/vpc-id")
    oneItem("_AWS_SUBNET_ID",                        awsMdUri & "network/interfaces/macs/" & mac & "/subnet-id")
    oneItem("_AWS_INTERFACE_ID",                     awsMdUri & "network/interfaces/macs/" & mac & "/interface-id")
    listKey("_AWS_SECURITY_GROUP_IDS",               awsMdUri & "network/interfaces/macs/" & mac & "/security-group-ids")

proc isAwsEc2Host(vendor: string): bool =
  # ref: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/identify_ec2_instances.html

  # older Xen instances
  let uuid = tryToLoadFile(get[string](getChalkScope(), "cloud_provider.cloud_instance_hw_identifiers.sys_hypervisor_path"))
  if uuid.toLowerAscii().startsWith("ec2"):
    return true

  # nitro instances
  if vendor.toLowerAscii().contains("amazon"):
    return true

  # this will only work if we have root, normally sudo dmidecode  --string system-uuid
  # gives the same output
  let productUuid = tryToLoadFile(get[string](getChalkScope(), "cloud_provider.cloud_instance_hw_identifiers.sys_product_path"))
  if productUuid.toLowerAscii().startsWith("ec2"):
    return true

  return false

proc isAzureHost(vendor: string): bool =
  return vendor.toLowerAscii().contains("microsoft")

proc isGoogleHost(vendor: string, resolvContents: string): bool =
  # vendor is present
  if vendor.toLowerAscii().contains("google"):
    return true

  # vendor information should be present in most services, but its not present
  # in cloud run. In cloud run we can detect the presence of a knative service
  # via ENV variables but we are being conservative in also checking resolv.conf
  var hasGoogleInternal = false
  for line in resolvContents.splitLines():
    # Checking that resolv.conf contains `google.internal` outside of a comment
    # should be more than sufficient.
    #
    # From `man resolv.conf`:
    #
    # - The keyword and value must appear on a single line, and the keyword
    #   (e.g., nameserver) must start the line.  The value follows the keyword,
    #   separated by white space.
    #
    # - Lines that contain a semicolon (;) or hash character (#) in the first
    #   column are treated as comments.
    if line.len() > 0 and line[0] notin {';', '#'} and line.contains("google.internal"):
      hasGoogleInternal = true
      break
  return (hasGoogleInternal and
          getEnv(CLOUD_RUN_TIMEOUT_SECONDS) != "" and
          getEnv(K_SERVICE) != "")

proc getHostKind(vendor: string, resolvContents: string): HostKind =
  if isAwsEc2Host(vendor):
    hkAws
  elif isAzureHost(vendor):
    hkAzure
  elif isGoogleHost(vendor, resolvContents):
    hkGcp
  else:
    hkUnknown

proc cloudMetadataGetrunTimeHostInfo*(self: Plugin, objs: seq[ChalkObj]):
                               ChalkDict {.cdecl.} =
  let vendor = tryToLoadFile(get[string](getChalkScope(), "cloud_provider.cloud_instance_hw_identifiers.sys_vendor_path"))
  let resolv = tryToLoadFile(get[string](getChalkScope(), "cloud_provider.cloud_instance_hw_identifiers.sys_resolv_path"))

  let hostKind = getHostKind(vendor, resolv)
  result = case hostKind
  of hkUnknown:
    trace("Unknown cloud host: does not seem to be AWS, Azure, or Google")
    ChalkDict()
  of hkAws:
    getAwsMetadata()
  of hkAzure:
    getAzureMetadata()
  of hkGcp:
    getGcpMetadata()

proc loadCloudMetadata*() =
  newPlugin("cloud_metadata", rtHostCallback = RunTimeHostCb(cloudMetadataGetrunTimeHostInfo))
