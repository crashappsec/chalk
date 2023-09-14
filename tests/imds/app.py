# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import json

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse


PREFIX = "/latest"
TOKEN = "token"
TAGS = {
    "Name": "foobar",
    "Environment": "staging",
}
ACCOUNT_ID = "123456789012"
MAC = "00:25:96:FF:FE:12:34:56"
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html
RESPONSES = {
    # "meta-data/ancestor-ami-ids": "",
    # "meta-data/ipv6": "",
    # "meta-data/kernel-id": "",
    # "meta-data/placement/group-name": "",
    # "meta-data/placement/host-id": "",
    "meta-data/ami-id": "ami-0abcdef1234567890",
    "meta-data/ami-launch-index": "0",
    "meta-data/ami-manifest-path": "(unknown)",
    "meta-data/hostname": "ip-10-251-50-12.ec2.internal",
    "meta-data/instance-id": "i-abc123xyz789",
    "meta-data/instance-life-cycle": "on-demand",
    "meta-data/instance-type": "t2.medium",
    "meta-data/local-hostname": "ip-10-251-50-12.ec2.internal",
    "meta-data/local-ipv4": "10.251.50.12",
    "meta-data/placement/availability-zone": "us-east-1e",
    "meta-data/placement/availability-zone-id": "use1-az3",
    "meta-data/placement/region": "us-east-1",
    "meta-data/public-hostname": "ec2-203-0-113-25.compute-1.amazonaws.com",
    "meta-data/public-ipv4": "203.0.113.25",
    "meta-data/security-groups": "\n".join(["default", "test"]),
    "meta-data/services/domain": "amazonaws.com",
    "meta-data/services/partition": "aws",
    "meta-data/tags/instance": "\n".join(TAGS.keys()),
    **{f"meta-data/tags/instance/{k}": v for k, v in TAGS.items()},
    "meta-data/mac": MAC,
    **{
        f"meta-data/network/interfaces/macs/{MAC}/{k}": v
        for k, v in {
            "vpc-id": "vpc-1234567890",
            "subnet-id": "subnet-1234567890",
            "interface-id": "eni-1234567890",
            "security-group-ids": "\n".join(["sg-1234567890", "sg-098764321"]),
        }.items()
    },
    "meta-data/iam/info": json.dumps(
        {
            "Code": "Success",
            "LastUpdated": "2023-09-12T15:16:58Z",
            "InstanceProfileArn": f"arn:aws:iam::{ACCOUNT_ID}:instance-profile/IMDSTestEc2Role",
            "InstanceProfileId": "AIPATILQWXT62BCWDUQCT",
        }
    ),
    "meta-data/identity-credentials/ec2/info": json.dumps(
        {
            "Code": "Success",
            "LastUpdated": "2023-09-13T13:13:39Z",
            "AccountId": ACCOUNT_ID,
        }
    ),
    "meta-data/identity-credentials/ec2/security-credentials/ec2-instance": json.dumps(
        {
            "Code": "Success",
            "LastUpdated": "2023-09-13T13:12:26Z",
            "Type": "AWS-HMAC",
            "AccessKeyId": "ASIATILQWXT67VGGR4O2",
            "SecretAccessKey": "SECRET",
            "Token": "SECRET",
            "Expiration": "2023-09-13T19:40:12Z",
        }
    ),
    "meta-data/public-keys/0/openssh-key": (
        "ssh-rsa "
        "AAAAB3NzaC1yc2EAAAADAQABAAAAgQC63mQI7eNK"
        "/f6ERi37TOvZxnyxfCOvkfFLKEHSh0Z1pR1elFx8aRAbBYJ7xPHBbGX"
        "+qJcld/3qGCDGvCHhnRyYr+7Q+kzK2TQo4"
        "+INIa35GBqjlKAO9Rr47eo1fiXIGSE8LfXrGHrKalnn"
        "+rADWn64IN4tOYA9k+4OSXpyxAOB8Q== test"
    ),
    "dynamic/instance-identity/document": json.dumps(
        {
            "accountId": ACCOUNT_ID,
            "architecture": "x86_64",
            "availabilityZone": "us-east-1e",
            "billingProducts": None,
            "devpayProductCodes": None,
            "marketplaceProductCodes": None,
            "imageId": "ami-0abcdef1234567890",
            "instanceId": "i-abc123xyz789",
            "instanceType": "t2.medium",
            "kernelId": None,
            "pendingTime": "2023-09-11T06:01:38Z",
            "privateIp": "10.251.50.12",
            "ramdiskId": None,
            "region": "us-east-1",
            "version": "2017-09-30",
        }
    ),
    "dynamic/instance-identity/pkcs7": (
        "MIAGCSqGSIb3DQEHAqCAMIACAQExCzAJBgUrDgMCGgUAMIAGCSqGSIb3DQEHAaCABIIB3nsKICAi"
        "YWNjb3VudElkIiA6ICIyMjQxMTE1NDE1MDEiLAogICJhcmNoaXRlY3R1cmUiIDogIng4Nl82NCIs"
        "CiAgImF2YWlsYWJpbGl0eVpvbmUiIDogInVzLWVhc3QtMWUiLAogICJiaWxsaW5nUHJvZHVjdHMi"
        "IDogbnVsbCwKICAiZGV2cGF5UHJvZHVjdENvZGVzIiA6IG51bGwsCiAgIm1hcmtldHBsYWNlUHJv"
        "ZHVjdENvZGVzIiA6IG51bGwsCiAgImltYWdlSWQiIDogImFtaS0wNTNiMGQ1M2MyNzlhY2M5MCIs"
        "CiAgImluc3RhbmNlSWQiIDogImktMGJhOTgyZDVmZDhjZTVjZWEiLAogICJpbnN0YW5jZVR5cGUi"
        "IDogInQyLm1lZGl1bSIsCiAgImtlcm5lbElkIiA6IG51bGwsCiAgInBlbmRpbmdUaW1lIiA6ICIy"
        "MDIzLTA5LTExVDA2OjAxOjM4WiIsCiAgInByaXZhdGVJcCIgOiAiMTcyLjMxLjQ4LjE2MCIsCiAg"
        "InJhbWRpc2tJZCIgOiBudWxsLAogICJyZWdpb24iIDogInVzLWVhc3QtMSIsCiAgInZlcnNpb24i"
        "IDogIjIwMTctMDktMzAiCn0AAAAAMYIBPzCCATsCAQEwaTBcMQswCQYDVQQGEwJVUzEZMBcGA1UE"
        "CBMQV2FzaGluZ3RvbiBTdGF0ZTEQMA4GA1UEBxMHU2VhdHRsZTEgMB4GA1UEChMXQW1hem9uIFdl"
        "YiBTZXJ2aWNlcyBMTEMCCQCWukjZ5V4aZzAJBgUrDgMCGgUAoIGEMBgGCSqGSIb3DQEJAzELBgkq"
        "hkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTIzMDkxMTA2MDEzOVowIwYJKoZIhvcNAQkEMRYEFIfT"
        "tF0PqkfKrmSH+tV0BWRB8v0PMCUGCSqGSIb3DQEJNDEYMBYwCQYFKw4DAhoFAKEJBgcqhkjOOAQD"
        "MAkGByqGSM44BAMELjAsAhQ3F3331Nr2Za0CMKJ81kXK+qitbwIUZZP2DCwOt9AkvDxF4e3qU1Cf"
        "/DcAAAAAAAA="
    ),
    "dynamic/instance-identity/signature": (
        "Puc5GhTTOl31T9LTKTQE4fQLkeSr5sdV5dcXij6oiWlylfcJj2O/juf02ymbRbHDJq4TXdpRs693"
        "heLxjsofvG5cx/2SpnVbrzjn38xy8H3I2YyGbQgddDDDY04fxE9ETQXSNWAKuR2sOv2g+MuBAMc+"
        "paIyVxXMENVHsLehh10="
    ),
}


app = FastAPI()


@app.get("/health")
def health():
    return


@app.put(f"{PREFIX}/api/token", response_class=PlainTextResponse)
def token():
    return TOKEN


def endpoint(url: str, value: str):
    app.get(url, response_class=PlainTextResponse)(lambda: value)


for key, value in RESPONSES.items():
    endpoint(f"{PREFIX}/{key}", value)
