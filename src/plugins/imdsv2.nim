##
## Copyright (c) 2023, Crash Override, Inc.
##
## This file is part of Chalk
## (see https://crashoverride.com/docs/chalk)
##

## Query common AWS metadata va IMDSv2

import httpclient, net, uri
import std/strutils, std/json
import nimutils/sinks
import ../config, ../plugin_api, ../chalkjson, ./procfs

const
  baseUri     = "http://169.254.169.254/latest/"
  mdUri       = baseUri & "meta-data/"
  dynUri      = baseUri & "dynamic/"
  # special keys for special processing
  AWS_IDENTITY_CREDENTIALS_SECURITY_CREDS = "_AWS_IDENTITY_CREDENTIALS_EC2_SECURITY_CREDENTIALS_EC2_INSTANCE"

proc getAwsToken(): Option[string] =
  let
    uri      = parseURI(baseUri & "api/token")
    hdrs     = newHttpHeaders([("X-aws-ec2-metadata-token-ttl-seconds", "10")])
    client   = newHttpClient(timeout = 250) # 1/4 of a second
    response = client.safeRequest(url = uri, httpMethod = HttpPut, headers = hdrs)

  if response.status[0] != '2':
    trace("Could not retrieve IMDSv2 token from: " & $uri)
    return none(string)

  trace("Retrieved AWS metadata token")
  return some(response.bodyStream.readAll().strip())

proc hitAwsEndpoint(path: string, token: string): Option[string] =
  let
    uri      = parseUri(path)
    hdrs     = newHttpHeaders([("X-aws-ec2-metadata-token", token)])
    client   = newHttpClient(timeout = 250) # 1/4 of a second
    response = client.safeRequest(url = uri, httpMethod = HttpGet, headers = hdrs)

  if response.status[0] != '2':
    trace("With valid IMDSv2 token, could not retrieve metadata from: " & $uri)
    return none(string)

  trace("Retrieved AWS metadata " & uri.path)
  result = some(response.bodyStream.readAll().strip())
  if not result.isSome():
    # log failing keys in trace mode only as some are expected to be absent
    trace("With valid IMDSv2 token, could not retrieve metadata from: " & uri.path)

template oneItem(keyname: string, url: string) =
  if isSubscribedKey(keyname):
    let resultOpt = hitAwsEndpoint(url, token)
    if resultOpt.isSome():
      setIfNotEmpty(result, keyname, resultOpt.get())

template listKey(keyname: string, url: string) =
  if isSubscribedKey(keyname):
    let resultOpt = hitAwsEndpoint(url, token)
    if resultOpt.isSome():
      setIfNeeded(result, keyname, resultOpt.get().splitLines())

template jsonKey(keyname: string, url: string) =
  if isSubscribedKey(keyname):
    let resultOpt = hitAwsEndpoint(url, token)
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

template getTags(keyname: string, url: string) =
  if isSubscribedKey(keyname):
    let resultOpt = hitAwsEndpoint(url, token)
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
        let tagOpt = hitAwsEndpoint(url & "/" & name, token)
        if tagOpt.isSome():
          tags[name] = pack(tagOpt.get())
        setIfNeeded(result, keyname, tags)

proc isAwsEc2Host(): bool =
  # ref: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/identify_ec2_instances.html

  # older Xen instances
  let uuid = readOneFile(chalkConfig.awsConfig.ec2Config.getSysHypervisorPath())
  if uuid.isSome() and strutils.toLowerAscii(uuid.get())[0..2] == "ec2":
      return true

  # nitro instances
  let vendor = readOneFile(chalkConfig.awsConfig.ec2Config.getSysVendorPath())
  if vendor.isSome() and contains(strutils.toLowerAscii(vendor.get()), "amazon"):
      return true

  # this will only work if we have root, normally sudo dmidecode  --string system-uuid
  # gives the same output
  let product_uuid = readOneFile(chalkConfig.awsConfig.ec2Config.getSysProductPath())
  if product_uuid.isSome() and strutils.toLowerAscii(product_uuid.get())[0..2] == "ec2":
      return true

  return false

proc imdsv2GetrunTimeHostInfo*(self: Plugin, objs: seq[ChalkObj]):
                               ChalkDict {.cdecl.} =
  result = ChalkDict()

  let isAwsEc2 = isAwsEc2Host()
  if not isAwsEc2:
    trace("Not an EC2 instance - skipping check for IMDSv2")
    return

  var tokenOpt: Option[string]

  try:
    tokenOpt = getAwsToken()
    if tokenOpt.isNone():
      trace("IMDSv2 token not available.")
      return
  except:
    trace("IMDSv2 metadata not available.")
    return

  let
    token = tokenOpt.get()

  # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-categories.html
  # dynamic entries
  # dynamic data categories
  jsonKey("_AWS_INSTANCE_IDENTITY_DOCUMENT",         dynUri & "instance-identity/document")
  oneItem("_AWS_INSTANCE_IDENTITY_PKCS7",            dynUri & "instance-identity/pkcs7")
  oneItem("_AWS_INSTANCE_IDENTITY_SIGNATURE",        dynUri & "instance-identity/signature")
  oneItem("_AWS_INSTANCE_MONITORING",                dynUri & "fws/instance-monitoring")

  oneItem("_AWS_AMI_ID",                             mdUri & "ami-id")
  oneItem("_AWS_AMI_LAUNCH_INDEX",                   mdUri & "ami-launch-index")
  oneItem("_AWS_AMI_MANIFEST_PATH",                  mdUri & "ami-manifest-path")
  oneItem("_AWS_ANCESTOR_AMI_IDS",                   mdUri & "ancestor-ami-ids")
  oneItem("_AWS_AUTOSCALING_TARGET_LIFECYCLE_STATE", mdUri & "autoscaling/target-lifecycle-state")
  oneItem("_AWS_AZ",                                 mdUri & "placement/availability-zone")
  oneItem("_AWS_AZ_ID",                              mdUri & "placement/availability-zone-id")
  oneItem("_AWS_BLOCK_DEVICE_MAPPING_AMI",           mdUri & "block-device-mapping/ami")
  oneItem("_AWS_BLOCK_DEVICE_MAPPING_ROOT",          mdUri & "block-device-mapping/root")
  oneItem("_AWS_BLOCK_DEVICE_MAPPING_SWAP",          mdUri & "block-device-mapping/swap")
  oneItem("_AWS_DEDICATED_HOST_ID",                  mdUri & "placement/host-id")
  oneItem("_AWS_EVENTS_MAINTENANCE_HISTORY",         mdUri & "events/maintenance/history")
  oneItem("_AWS_EVENTS_MAINTENANCE_SCHEDULED",       mdUri & "events/maintenance/scheduled")
  oneItem("_AWS_EVENTS_RECOMMENDATIONS_REBALANCE",   mdUri & "events/recommendations/rebalance")
  oneItem("_AWS_HOSTNAME",                           mdUri & "hostname")
  oneItem("_AWS_INSTANCE_ACTION",                    mdUri & "instance-action")
  oneItem("_AWS_INSTANCE_ID",                        mdUri & "instance-id")
  oneItem("_AWS_INSTANCE_LIFE_CYCLE",                mdUri & "instance-life-cycle")
  oneItem("_AWS_INSTANCE_TYPE",                      mdUri & "instance-type")
  oneItem("_AWS_IPV6_ADDR",                          mdUri & "ipv6")
  oneItem("_AWS_KERNEL_ID",                          mdUri & "kernel-id")
  oneItem("_AWS_LOCAL_HOSTNAME",                     mdUri & "local-hostname")
  oneItem("_AWS_LOCAL_IPV4_ADDR",                    mdUri & "local-ipv4")
  oneItem("_AWS_MAC",                                mdUri & "mac")
  oneItem("_AWS_METRICS_VHOSTMD",                    mdUri & "metrics/vhostmd")
  oneItem("_AWS_OPENSSH_PUBKEY",                     mdUri & "public-keys/0/openssh-key")
  oneItem("_AWS_PARTITION_NAME",                     mdUri & "services/partition")
  oneItem("_AWS_PARTITION_NUMBER",                   mdUri & "placement/partition-number")
  oneItem("_AWS_PLACEMENT_GROUP",                    mdUri & "placement/group-name")
  oneItem("_AWS_PRODUCT_CODES",                      mdUri & "product-codes")
  oneItem("_AWS_PUBLIC_HOSTNAME",                    mdUri & "public-hostname")
  oneItem("_AWS_PUBLIC_IPV4_ADDR",                   mdUri & "public-ipv4")
  oneItem("_AWS_RAMDISK_ID",                         mdUri & "ramdisk-id")
  oneItem("_AWS_REGION",                             mdUri & "placement/region")
  oneItem("_AWS_RESERVATION_ID",                     mdUri & "reservation-id")
  oneItem("_AWS_RESOURCE_DOMAIN",                    mdUri & "services/domain")
  oneItem("_AWS_SPOT_INSTANCE_ACTION",               mdUri & "spot/instance-action")
  oneItem("_AWS_SPOT_TERMINATION_TIME",              mdUri & "spot/termination-time")

  listKey("_AWS_SECURITY_GROUPS",                    mdUri & "security-groups")

  jsonKey("_AWS_IAM_INFO",                           mdUri & "iam/info")
  jsonKey("_AWS_IDENTITY_CREDENTIALS_EC2_INFO",      mdUri & "identity-credentials/ec2/info")
  jsonKey(AWS_IDENTITY_CREDENTIALS_SECURITY_CREDS,   mdUri & "identity-credentials/ec2/security-credentials/ec2-instance")

  getTags("_AWS_TAGS",                               mdUri & "tags/instance")

  if "_AWS_MAC" in result:
    let mac = unpack[string]result["_AWS_MAC"]
    oneItem("_AWS_VPC_ID",                           mdUri & "network/interfaces/macs/" & mac & "/vpc-id")
    oneItem("_AWS_SUBNET_ID",                        mdUri & "network/interfaces/macs/" & mac & "/subnet-id")
    oneItem("_AWS_INTERFACE_ID",                     mdUri & "network/interfaces/macs/" & mac & "/interface-id")
    listKey("_AWS_SECURITY_GROUP_IDS",               mdUri & "network/interfaces/macs/" & mac & "/security-group-ids")

proc loadImdsv2*() =
  newPlugin("imdsv2", rtHostCallback = RunTimeHostCb(imdsv2GetrunTimeHostInfo))
