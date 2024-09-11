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
  awsBaseUri     = "/latest/"
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

proc getUrl(path: string): string =
  let ip = attrGet[string]("cloud_provider.metadata_ip")
  return "http://" & ip & path

proc hitProviderEndpoint(path: string, hdrs: HttpHeaders): Option[string] =
  let url      = getUrl(path)
  try:
    let
      response = safeRequest(url            = url,
                             httpMethod     = HttpGet,
                             timeout        = 1000, # 1 of a second
                             connectRetries = 2,
                             retries        = 2,
                             headers        = hdrs)
      body     = response.body().strip()

    if not response.code.is2xx():
      # 404 is expected response for some endpoints and logging full response body
      # is very verbose. We only care about full body for other errors like 400,500,etc
      if response.code == Http404:
        trace("Could not retrieve metadata from: " & url & " - " & response.status)
      else:
        trace("Could not retrieve metadata from: " & url & " - " & response.status & ": " & body)
      return none(string)

    if body == "":
      # some paths are expected to be empty so this is not an error
      trace("Got empty metadata from: " & url)

    trace("Retrieved metadata from: " & url)
    return some(body)
  except:
    trace("Could not retrieve metadata from: " & url & " due to: " & getCurrentExceptionMsg())
    dumpExOnDebug()
    return none(string)

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
      isSubscribedKey("_OP_CLOUD_PROVIDER_INSTANCE_TYPE"):
    let resultOpt = hitProviderEndpoint(
      "/metadata/instance?api-version=2021-02-01",
      newHttpHeaders([("Metadata", "true")]),
    )
    if not resultOpt.isSome():
      trace("Did not get metadata back from Azure endpoint")
      return
    let value = resultOpt.get()
    if not value.startswith("{"):
      trace("Azure metadata didnt respond with json object. Ignoring it")
      return
    try:
      let jsonValue = parseJson(value)
      result.setIfNeeded("_AZURE_INSTANCE_METADATA", jsonValue.nimJsonToBox())
      try:
        for iface in jsonValue["network"]["interface"]:
          var found = false
          for address in iface["ipv4"]["ipAddress"]:
            let ipv4 = address["publicIpAddress"].getStr()
            if ipv4 != "":
              found = true
              # just pick the first
              result.setIfNeeded("_OP_CLOUD_PROVIDER_IP", ipv4)
              break
          if found:
            break
      except:
        trace("Could not set _OP_CLOUD_PROVIDER_IP for azure: " & getCurrentExceptionMsg())
      result.trySetIfNeeded("_OP_CLOUD_PROVIDER_TAGS"):
        jsonValue["compute"]["tagsList"].nimJsonToBox()
      result.trySetIfNeeded("_OP_CLOUD_PROVIDER_ACCOUNT_INFO"):
        jsonValue["compute"]["subscriptionId"].getStr()
      result.trySetIfNeeded("_OP_CLOUD_PROVIDER_REGION"):
        jsonValue["compute"]["location"].getStr()
      result.trySetIfNeeded("_OP_CLOUD_PROVIDER_INSTANCE_TYPE"):
        jsonValue["compute"]["vmSize"].getStr()
    except:
      trace("Azure metadata responded with invalid json: " & getCurrentExceptionMsg())

proc getGcpMetadata(): ChalkDict =
  result = ChalkDict()
  result.setIfNeeded("_OP_CLOUD_PROVIDER", $hkGcp)

  if getEnv(K_SERVICE) != "" and getEnv(CLOUD_RUN_TIMEOUT_SECONDS) != "":
    result.setIfNeeded("_OP_CLOUD_PROVIDER_SERVICE_TYPE", "gcp_cloud_run_service")

  if isSubscribedKey("_GCP_INSTANCE_METADATA") or
      isSubscribedKey("_GCP_PROJECT_METADATA") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_IP") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_REGION") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_TAGS") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_ACCOUNT_INFO") or
      isSubscribedKey("_OP_CLOUD_PROVIDER_INSTANCE_TYPE"):
    trace("Querying for GCP metadata")
    if isSubscribedKey("_GCP_PROJECT_METADATA"):
      let projectOpt = hitProviderEndpoint(
        "/computeMetadata/v1/project/?recursive=true",
        newHttpHeaders([("Metadata-Flavor", "Google")]),
      )
      if projectOpt.isSome():
        try:
          let valueProj = projectOpt.get()
          if valueProj.startswith("{"):
            let jsonProjValue = parseJson(valueProj)
            result.setIfNeeded("_GCP_PROJECT_METADATA", jsonProjValue.nimJsonToBox())
          else:
            trace("GCP project metadata didnt respond with json object. Ignoring it")
        except:
          trace("Could not set _GCP_PROJECT_METADATA: " & getCurrentExceptionMsg())

    let resultOpt = hitProviderEndpoint(
      "/computeMetadata/v1/instance/?recursive=true",
      newHttpHeaders([("Metadata-Flavor", "Google")]),
    )
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
        for iface in jsonValue["networkInterfaces"]:
          var found = false
          for config in iface["accessConfigs"]:
            let ipv4 = config["externalIp"].getStr()
            if ipv4 != "":
              found = true
              # just pick the first
              result.setIfNeeded("_OP_CLOUD_PROVIDER_IP", ipv4)
              break
          if found:
            break
      except:
        trace("Could not insert _OP_CLOUD_PROVIDER_IP for gcp: " & getCurrentExceptionMsg())
      result.trySetIfNeeded("_GCP_INSTANCE_METADATA"):
        jsonValue.nimJsonToBox()
      result.trySetIfNeeded("_OP_CLOUD_PROVIDER_TAGS"):
        jsonValue["tags"].nimJsonToBox()
      result.trySetIfNeeded("_OP_CLOUD_PROVIDER_ACCOUNT_INFO"):
        jsonValue["serviceAccounts"].nimJsonToBox()
      result.trySetIfNeeded("_OP_CLOUD_PROVIDER_REGION"):
        jsonValue["zone"].getStr().split("/")[^1]
      result.trySetIfNeeded("_OP_CLOUD_PROVIDER_INSTANCE_TYPE"):
        jsonValue["machineType"].getStr().split("/")[^1]
    except:
      trace("GCP metadata responded with invalid json: " & getCurrentExceptionMsg())

proc getAwsToken(): tuple[token: Option[string], reason: Option[string]] =
  let url      = getUrl(awsBaseUri & "api/token")
  try:
    let
      hdrs     = newHttpHeaders([("X-aws-ec2-metadata-token-ttl-seconds", "10")])
      response = safeRequest(url            = url,
                             httpMethod     = HttpPut,
                             timeout        = 1000, # 1 of a second
                             connectRetries = 2,
                             retries        = 2,
                             headers        = hdrs)
      body     = response.body().strip()

    if response.code == Http403:
      # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html#instance-metadata-returns
      trace("Could not retrieve IMDSv2 as metadata endpoint is disabled")
      return (none(string), some("instance metadata is disabled"))

    elif not response.code.is2xx():
      trace("Could not retrieve IMDSv2 token from: " & url & " - " & response.status & ": " & body)
      return (none(string), none(string))

    trace("Retrieved AWS metadata token")
    return (some(body), none(string))
  except:
    let msg = getCurrentExceptionMsg()
    trace("Could not retrieve IMDSv2 token from: " & url & " due to: " & msg)
    dumpExOnDebug()
    if "'readLine' timed out" in msg:
      return (none(string), some("instance metadata hop limit is reached"))
    return (none(string), none(string))

proc oneItem(chalkDict: ChalkDict, token: string, keyname: string, url: string) =
  ## If `keyname` is subscribed, hits the given `url` and sets the `keyname` key
  ## in `chalkDict` to the value of the response (if non-empty).
  if isSubscribedKey(keyname):
    let
      hdrs      = newHttpHeaders([("X-aws-ec2-metadata-token", token)])
      resultOpt = hitProviderEndpoint(url, hdrs)
    if resultOpt.isSome():
      chalkDict.setIfNotEmpty(keyname, resultOpt.get())

proc listKey(chalkDict: ChalkDict, token: string, keyname: string, url: string) =
  ## If `keyname` is subscribed, hits the given `url` and sets the `keyname` key
  ## in `chalkDict` to the value of the response (as a `seq` of lines).
  if isSubscribedKey(keyname):
    let
      hdrs      = newHttpHeaders([("X-aws-ec2-metadata-token", token)])
      resultOpt = hitProviderEndpoint(url, hdrs)
    if resultOpt.isSome():
      chalkDict.setIfNeeded(keyname, resultOpt.get().splitLines())

proc jsonKey(chalkDict: ChalkDict, token: string, keyname: string, url: string) =
  ## If `keyname` is subscribed, hits the given `url` and sets the `keyname` key
  ## in `chalkDict` to the value of the response (as JSON).
  ##
  ## If `keyname` is the value of `AWS_IDENTITY_CREDENTIALS_SECURITY_CREDS`,
  ## sets `<<redacted>>` as the values of `SecretAccessKey` and `Token` in
  ## `chalkDict`.
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
          chalkDict.setIfNeeded(keyname, jsonValue.nimJsonToBox())
        except:
          trace("IMDSv2 responded with invalid json from " & url & ": " & getCurrentExceptionMsg())

proc extractJsonKey(chalkDict: ChalkDict, token: string, keyname: string,
                    url: string, subkey: string) =
  ## If `keyname` is subscribed, hits the given `url` and sets the `keyname` key
  ## in `chalkDict` to the value of `subkey` in the response.
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
        chalkDict.trySetIfNeeded(keyname):
          parseJson(value)[subkey].getStr()

proc getTags(chalkDict: ChalkDict, token: string, keyname: string, url: string) =
  ## If `keyname` is subscribed, hits the given `url` and sets the `keyname` key
  ## in `chalkDict` to a `ChalkDict` of tag/value pairs.
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
          tags.setIfNotEmpty(name, tagOpt.get())
        chalkDict.setIfNeeded(keyname, tags)

proc getAwsMetadata(): ChalkDict =
  result = ChalkDict()
  result.setIfNeeded("_OP_CLOUD_PROVIDER", $hkAws)

  # fetching token can fail due to timeout however as hardware vendor indicated
  # we are running in AWS and so we should report what type of the service
  # we are running in AWS (eks, ec2, ecs, etc)
  if isSubscribedKey("_OP_CLOUD_PROVIDER_SERVICE_TYPE"):
    # XXX ignoring task metadata v2 which is no longer actively maintained
    let ecsv3 = getEnv("ECS_CONTAINER_METADATA_URI")
    let ecsv4 = getEnv("ECS_CONTAINER_METADATA_URI_V4")
    if ecsv3 != "" or ecsv4 != "":
      result.setIfNotEmpty("_OP_CLOUD_PROVIDER_SERVICE_TYPE", "aws_ecs")
    else:
      let k8sPort = getEnv("KUBERNETES_PORT")
      let k8sServiceHost = getEnv("KUBERNETES_SERVICE_HOST")
      # https://docs.aws.amazon.com/eks/latest/userguide/fargate.html
      if k8sPort != "" or k8sServiceHost != "":
        # XXX this might have FP in case of a user that has deployed k8s within
        # a single EC2 instance, so should differentiate from the rest of the
        # IMDS metadata versions
        result.setIfNotEmpty("_OP_CLOUD_PROVIDER_SERVICE_TYPE", "aws_eks")
      else:
        result.setIfNotEmpty("_OP_CLOUD_PROVIDER_SERVICE_TYPE", "aws_ec2")

  let instanceId = tryToLoadFile(attrGet[string]("cloud_provider.cloud_instance_hw_identifiers.sys_board_asset_tag_path")).strip()
  if instanceId.toLowerAscii().startsWith("i-"):
    result.setIfNeeded("_AWS_INSTANCE_ID", instanceId)

  let (tokenOpt, reasonOpt) = getAwsToken()
  if tokenOpt.isNone():
    trace("IMDSv2 token not available.")
    if reasonOpt.isSome():
      result.setIfNeeded("_OP_CLOUD_METADATA_FAILURE_REASON", reasonOpt.get())
    return

  let token = tokenOpt.get()

  # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-categories.html
  # dynamic entries
  # dynamic data categories
  result.jsonKey(token, "_AWS_INSTANCE_IDENTITY_DOCUMENT",         awsDynUri & "instance-identity/document")
  result.extractJsonKey(token, "_OP_CLOUD_PROVIDER_ACCOUNT_INFO",  awsDynUri & "instance-identity/document", "accountId")
  result.extractJsonKey(token, "_OP_CLOUD_PROVIDER_INSTANCE_TYPE", awsDynUri & "instance-identity/document", "instanceType")
  result.extractJsonKey(token, "_OP_CLOUD_PROVIDER_INSTANCE_ARCH", awsDynUri & "instance-identity/document", "architecture")
  result.oneItem(token, "_AWS_INSTANCE_IDENTITY_PKCS7",            awsDynUri & "instance-identity/pkcs7")
  result.oneItem(token, "_AWS_INSTANCE_IDENTITY_SIGNATURE",        awsDynUri & "instance-identity/signature")
  result.oneItem(token, "_AWS_INSTANCE_MONITORING",                awsDynUri & "fws/instance-monitoring")

  result.oneItem(token, "_AWS_AMI_ID",                             awsMdUri & "ami-id")
  result.oneItem(token, "_AWS_AMI_LAUNCH_INDEX",                   awsMdUri & "ami-launch-index")
  result.oneItem(token, "_AWS_AMI_MANIFEST_PATH",                  awsMdUri & "ami-manifest-path")
  result.oneItem(token, "_AWS_ANCESTOR_AMI_IDS",                   awsMdUri & "ancestor-ami-ids")
  result.oneItem(token, "_AWS_AUTOSCALING_TARGET_LIFECYCLE_STATE", awsMdUri & "autoscaling/target-lifecycle-state")
  result.oneItem(token, "_AWS_AZ",                                 awsMdUri & "placement/availability-zone")
  result.oneItem(token, "_AWS_AZ_ID",                              awsMdUri & "placement/availability-zone-id")
  result.oneItem(token, "_AWS_BLOCK_DEVICE_MAPPING_AMI",           awsMdUri & "block-device-mapping/ami")
  result.oneItem(token, "_AWS_BLOCK_DEVICE_MAPPING_ROOT",          awsMdUri & "block-device-mapping/root")
  result.oneItem(token, "_AWS_BLOCK_DEVICE_MAPPING_SWAP",          awsMdUri & "block-device-mapping/swap")
  result.oneItem(token, "_AWS_DEDICATED_HOST_ID",                  awsMdUri & "placement/host-id")
  result.oneItem(token, "_AWS_EVENTS_MAINTENANCE_HISTORY",         awsMdUri & "events/maintenance/history")
  result.oneItem(token, "_AWS_EVENTS_MAINTENANCE_SCHEDULED",       awsMdUri & "events/maintenance/scheduled")
  result.oneItem(token, "_AWS_EVENTS_RECOMMENDATIONS_REBALANCE",   awsMdUri & "events/recommendations/rebalance")
  result.oneItem(token, "_AWS_HOSTNAME",                           awsMdUri & "hostname")
  result.oneItem(token, "_AWS_INSTANCE_ACTION",                    awsMdUri & "instance-action")
  result.oneItem(token, "_AWS_INSTANCE_ID",                        awsMdUri & "instance-id")
  result.oneItem(token, "_AWS_INSTANCE_LIFE_CYCLE",                awsMdUri & "instance-life-cycle")
  result.oneItem(token, "_AWS_INSTANCE_TYPE",                      awsMdUri & "instance-type")
  result.oneItem(token, "_AWS_IPV6_ADDR",                          awsMdUri & "ipv6")
  result.oneItem(token, "_AWS_KERNEL_ID",                          awsMdUri & "kernel-id")
  result.oneItem(token, "_AWS_LOCAL_HOSTNAME",                     awsMdUri & "local-hostname")
  result.oneItem(token, "_AWS_LOCAL_IPV4_ADDR",                    awsMdUri & "local-ipv4")
  result.oneItem(token, "_AWS_MAC",                                awsMdUri & "mac")
  result.oneItem(token, "_AWS_METRICS_VHOSTMD",                    awsMdUri & "metrics/vhostmd")
  result.oneItem(token, "_AWS_OPENSSH_PUBKEY",                     awsMdUri & "public-keys/0/openssh-key")
  result.oneItem(token, "_AWS_PARTITION_NAME",                     awsMdUri & "services/partition")
  result.oneItem(token, "_AWS_PARTITION_NUMBER",                   awsMdUri & "placement/partition-number")
  result.oneItem(token, "_AWS_PLACEMENT_GROUP",                    awsMdUri & "placement/group-name")
  result.oneItem(token, "_AWS_PRODUCT_CODES",                      awsMdUri & "product-codes")
  result.oneItem(token, "_AWS_PUBLIC_HOSTNAME",                    awsMdUri & "public-hostname")
  result.oneItem(token, "_AWS_PUBLIC_IPV4_ADDR",                   awsMdUri & "public-ipv4")
  result.oneItem(token, "_OP_CLOUD_PROVIDER_IP",                   awsMdUri & "public-ipv4")
  result.oneItem(token, "_AWS_RAMDISK_ID",                         awsMdUri & "ramdisk-id")
  result.oneItem(token, "_AWS_REGION",                             awsMdUri & "placement/region")
  result.oneItem(token, "_OP_CLOUD_PROVIDER_REGION",               awsMdUri & "placement/region")
  result.oneItem(token, "_AWS_RESERVATION_ID",                     awsMdUri & "reservation-id")
  result.oneItem(token, "_AWS_RESOURCE_DOMAIN",                    awsMdUri & "services/domain")
  result.oneItem(token, "_AWS_SPOT_INSTANCE_ACTION",               awsMdUri & "spot/instance-action")
  result.oneItem(token, "_AWS_SPOT_TERMINATION_TIME",              awsMdUri & "spot/termination-time")

  result.listKey(token, "_AWS_SECURITY_GROUPS",                    awsMdUri & "security-groups")

  result.jsonKey(token, "_AWS_IAM_INFO",                           awsMdUri & "iam/info")
  result.jsonKey(token, "_AWS_IDENTITY_CREDENTIALS_EC2_INFO",      awsMdUri & "identity-credentials/ec2/info")
  result.jsonKey(token, AWS_IDENTITY_CREDENTIALS_SECURITY_CREDS,   awsMdUri & "identity-credentials/ec2/security-credentials/ec2-instance")

  result.getTags(token, "_AWS_TAGS",                               awsMdUri & "tags/instance")
  result.getTags(token, "_OP_CLOUD_PROVIDER_TAGS",                 awsMdUri & "tags/instance")

  if "_AWS_MAC" in result:
    let
      mac    = unpack[string]result["_AWS_MAC"]
      macUrl = awsMdUri & "network/interfaces/macs/" & mac
    result.oneItem(token, "_AWS_VPC_ID",                           macUrl & "/vpc-id")
    result.oneItem(token, "_AWS_SUBNET_ID",                        macUrl & "/subnet-id")
    result.oneItem(token, "_AWS_INTERFACE_ID",                     macUrl & "/interface-id")
    result.listKey(token, "_AWS_SECURITY_GROUP_IDS",               macUrl & "/security-group-ids")

proc isAwsEc2Host(vendor: string): bool =
  # ref: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/identify_ec2_instances.html

  # older Xen instances
  let uuid = tryToLoadFile(attrGet[string]("cloud_provider.cloud_instance_hw_identifiers.sys_hypervisor_path"))
  if uuid.toLowerAscii().startsWith("ec2"):
    return true

  # nitro instances
  if vendor.toLowerAscii().contains("amazon"):
    return true

  # this will only work if we have root, normally sudo dmidecode  --string system-uuid
  # gives the same output
  let productUuid = tryToLoadFile(attrGet[string]("cloud_provider.cloud_instance_hw_identifiers.sys_product_path"))
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

proc cloudMetadataGetrunTimeHostInfo*(self: Plugin,
                                      objs: seq[ChalkObj]): ChalkDict {.cdecl.} =
  let
    vendor = tryToLoadFile(attrGet[string]("cloud_provider.cloud_instance_hw_identifiers.sys_vendor_path"))
    resolv = tryToLoadFile(attrGet[string]("cloud_provider.cloud_instance_hw_identifiers.sys_resolv_path"))

  result =
    case getHostKind(vendor, resolv)
    of hkUnknown:
      trace("Unknown cloud host: does not seem to be AWS, Azure, or Google")
      ChalkDict()
    of hkAws:
      getAwsMetadata()
    of hkAzure:
      getAzureMetadata()
    of hkGcp:
      getGcpMetadata()

  result.setIfNeeded("_OP_CLOUD_SYS_VENDOR", vendor)

proc loadCloudMetadata*() =
  newPlugin("cloud_metadata", rtHostCallback = RunTimeHostCb(cloudMetadataGetrunTimeHostInfo))
