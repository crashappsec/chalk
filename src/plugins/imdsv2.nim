## Query common AWS metadata va IMDSv2
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2023, Crash Override, Inc.

import httpclient, net, uri, ../config, ../plugin_api
from ../chalkjson import nimJsonToBox

const
  baseUri     = "http://169.254.169.254/latest/"
  mdUri       = baseUri & "meta-data/"
  # dynamic data categories
  monitoring  = baseUri & "dynamic/fws/instance-monitoring"
  identityDoc = baseUri & "dynamic/instance-identity/document"
  identityPkcs = baseUri & "dynamic/instance-identity/pkcs7"
  identitySig = baseUri & "dynamic/instance-identity/signature"
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

template oneItem(keyname: string, url: string) =
  if isSubscribedKey(keyname):
    let resultOpt = hitAwsEndpoint(url, token)
    if resultOpt.isNone():
      # log failing keys in trace mode only as some are expected to be absent
      trace("With valid IMDSv2 token, could not retrieve metadata from: " & url)
    else:
      setIfNotEmpty(result, keyname, resultOpt.get())

proc imdsv2GetrunTimeHostInfo*(self: Plugin, objs: seq[ChalkObj]):
                               ChalkDict {.cdecl.} =
  result = ChalkDict()
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


proc loadImdsv2*() =
  newPlugin("imdsv2", rtHostCallback = RunTimeHostCb(imdsv2GetrunTimeHostInfo))
