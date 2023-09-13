## Query common AWS metadata va IMDSv2
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import httpclient, net, uri, ../config, ../plugin_api
import std/strutils
import std/json

const
  baseUri     = "http://169.254.169.254/latest/"
  mdUri       = baseUri & "meta-data/"
  # dynamic data categories
  monitoring  = baseUri & "dynamic/fws/instance-monitoring"
  identityDoc = baseUri & "dynamic/instance-identity/document"
  identityPkcs = baseUri & "dynamic/instance-identity/pkcs7"
  identitySig = baseUri & "dynamic/instance-identity/signature"


# XXX can we re-use it from procfs?
template readOneFile(fname: string): Option[string] =
  let stream = newFileStream(fname, fmRead)
  if stream == nil:
    none(string)
  else:
    let contents = stream.readAll().strip()
    if len(contents) == 0:
       none(string)
    else:
      stream.close()
      some(contents)

proc getAwsToken(): Option[string] =
  let
    uri      = parseURI(baseUri & "api/token")
    hdrs     = newHttpHeaders([("X-aws-ec2-metadata-token-ttl-seconds", "10")])
    client   = newHttpClient(timeout = 250) # 1/4 of a second
    response = client.request(url = uri, httpMethod = HttpPut, headers = hdrs)

  if response.status[0] != '2':
    trace(response.status)
    return none(string)

  trace("Retrieved AWS metadata token")
  return some(response.bodyStream.readAll().strip())

proc hitAwsEndpoint(path: string, token: string): Option[string] =
  let
    uri      = parseUri(path)
    hdrs     = newHttpHeaders([("X-aws-ec2-metadata-token", token)])
    client   = newHttpClient(timeout = 250) # 1/4 of a second
    response = client.request(url = uri, httpMethod = HttpGet, headers = hdrs)

  if response.status[0] != '2':
    trace(response.status)
    return none(string)

  trace("Retrieved AWS metadata token")
  return some(response.bodyStream.readAll().strip())

proc redact(keyname: string, raw: string): string =
  if keyname == "_AWS_IDENTITY_CREDENTIALS_EC2_SECURITY_CREDENTIALS_EC2_INSTANCE":
    let creds = parseJson(raw)
    creds["SecretAccessKey"] = newJString("<<redacted>>")
    creds["Token"] = newJString("<<redacted>>")
    return $(creds)
  return raw

template oneItem(keyname: string, url: string) =
  if isSubscribedKey(keyname):
    let resultOpt = hitAwsEndpoint(url, token)
    if resultOpt.isNone():
      # log failing keys in trace mode only as some are expected to be absent
      trace("With valid IMDSv2 token, could not retrieve metadata from: " & url)
    else:
      setIfNotEmpty(result, keyname, redact(keyname, resultOpt.get()))


proc isAwsEc2Host(): bool =
  # ref: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/identify_ec2_instances.html

  # older Xen instances
  let uuid = readOneFile("/sys/hypervisor/uuid")
  if uuid.isSome() and strutils.toLowerAscii(uuid.get())[0..2] == "ec2":
      return true

  # nitro instances
  let vendor = readOneFile("/sys/class/dmi/id/board_vendor")
  if vendor.isSome() and contains(strutils.toLowerAscii(vendor.get()), "amazon"):
      return true

  # this will only work if we have root, normally sudo dmidecode  --string system-uuid
  # gives the same output
  let product_uuid = readOneFile("/sys/devices/virtual/dmi/id/product_uuid")
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
    let token = tokenOpt.get()
  except:
    trace("IMDSv2 metadata not available.")
    return

  let
    token    = tokenOpt.get()

  # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-categories.html
  # dynamic entries
  oneItem("_AWS_INSTANCE_IDENTITY_DOCUMENT", identityDoc)
  oneItem("_AWS_INSTANCE_IDENTITY_PKCS7", identityPkcs)
  oneItem("_AWS_INSTANCE_IDENTITY_SIGNATURE", identitySig)


  oneItem("_AWS_INSTANCE_MONITORING", monitoring)
  oneItem("_AWS_AMI_ID", mdUri & "ami-id")
  oneItem("_AWS_AMI_LAUNCH_INDEX", mdUri & "ami-launch-index")
  oneItem("_AWS_AMI_MANIFEST_PATH", mdUri & "ami-manifest-path")
  oneItem("_AWS_ANCESTOR_AMI_IDS", mdUri & "ancestor-ami-ids")
  oneItem("_AWS_HOSTNAME", mdUri & "hostname")
  oneItem("_AWS_IAM_INFO", mdUri & "iam/info")

  oneItem("_AWS_INSTANCE_ID",         mdUri & "instance-id")
  oneItem("_AWS_INSTANCE_LIFE_CYCLE", mdUri & "instance-life-cycle")
  oneItem("_AWS_INSTANCE_TYPE",       mdUri & "instance-type")
  oneItem("_AWS_IPV6_ADDR",           mdUri & "ipv6")
  oneItem("_AWS_KERNEL_ID",           mdUri & "kernel-id")
  oneItem("_AWS_LOCAL_HOSTNAME",      mdUri & "local-hostname")
  oneItem("_AWS_LOCAL_IPV4_ADDR",     mdUri & "local-ipv4")
  oneItem("_AWS_AZ",                  mdUri & "placement/availability-zone")
  oneItem("_AWS_AZ_ID",               mdUri & "placement/availability-zone-id")
  oneItem("_AWS_PLACEMENT_GROUP",     mdUri & "placement/group-name")
  oneItem("_AWS_DEDICATED_HOST_ID",   mdUri & "placement/host-id")
  oneItem("_AWS_PARTITION_NUMBER",    mdUri & "placement/partition-number")
  oneItem("_AWS_REGION",              mdUri & "placement/region")
  oneItem("_AWS_PUBLIC_HOSTNAME",     mdUri & "public-hostname")
  oneItem("_AWS_PUBLIC_IPV4_ADDR",    mdUri & "public-ipv4")
  oneItem("_AWS_OPENSSH_PUBKEY",      mdUri & "public-keys/0/openssh-key")
  oneItem("_AWS_SECURITY_GROUPS",     mdUri & "security-groups")
  oneItem("_AWS_RESOURCE_DOMAIN",     mdUri & "services/domain")
  oneItem("_AWS_PARTITION_NAME",      mdUri & "services/partition")
  oneItem("_AWS_TAGS",                mdUri & "tags/instance")

  oneitem("_AWS_AUTOSCALING_TARGET_LIFECYCLE_STATE", mdUri & "autoscaling/target-lifecycle-state")
  oneitem("_AWS_BLOCK_DEVICE_MAPPING_AMI", mdUri & "block-device-mapping/ami")
  oneitem("_AWS_BLOCK_DEVICE_MAPPING_ROOT", mdUri & "block-device-mapping/root")
  oneitem("_AWS_BLOCK_DEVICE_MAPPING_SWAP", mdUri & "block-device-mapping/swap")
  oneitem("_AWS_EVENTS_MAINTENANCE_HISTORY", mdUri & "events/maintenance/history")
  oneitem("_AWS_EVENTS_MAINTENANCE_SCHEDULED", mdUri & "events/maintenance/scheduled")
  oneitem("_AWS_EVENTS_RECOMMENDATIONS_REBALANCE", mdUri & "events/recommendations/rebalance")
  oneitem("_AWS_IDENTITY_CREDENTIALS_EC2_INFO", mdUri & "identity-credentials/ec2/info")
  oneitem("_AWS_IDENTITY_CREDENTIALS_EC2_SECURITY_CREDENTIALS_EC2_INSTANCE", mdUri & "identity-credentials/ec2/security-credentials/ec2-instance")
  oneitem("_AWS_INSTANCE_ACTION", mdUri & "instance-action")
  oneitem("_AWS_MAC", mdUri & "mac")
  oneitem("_AWS_METRICS_VHOSTMD", mdUri & "metrics/vhostmd")
  oneitem("_AWS_PRODUCT_CODES", mdUri & "product-codes")
  oneitem("_AWS_RAMDISK_ID", mdUri & "ramdisk-id")
  oneitem("_AWS_RESERVATION_ID", mdUri & "reservation-id")
  oneitem("_AWS_SPOT_INSTANCE_ACTION", mdUri & "spot/instance-action")
  oneitem("_AWS_SPOT_TERMINATION_TIME", mdUri & "spot/termination-time")

proc loadImdsv2*() =
  newPlugin("imdsv2", rtHostCallback = RunTimeHostCb(imdsv2GetrunTimeHostInfo))
