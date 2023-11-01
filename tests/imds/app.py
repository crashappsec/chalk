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
    # "/latest/meta-data/ancestor-ami-ids": "",
    # "/latest/meta-data/ipv6": "",
    # "/latest/meta-data/kernel-id": "",
    # "/latest/meta-data/placement/group-name": "",
    # "/latest/meta-data/placement/host-id": "",
    "/latest/meta-data/ami-id": "ami-0abcdef1234567890",
    "/latest/meta-data/ami-launch-index": "0",
    "/latest/meta-data/ami-manifest-path": "(unknown)",
    "/latest/meta-data/hostname": "ip-10-251-50-12.ec2.internal",
    "/latest/meta-data/instance-id": "i-abc123xyz789",
    "/latest/meta-data/instance-life-cycle": "on-demand",
    "/latest/meta-data/instance-type": "t2.medium",
    "/latest/meta-data/local-hostname": "ip-10-251-50-12.ec2.internal",
    "/latest/meta-data/local-ipv4": "10.251.50.12",
    "/latest/meta-data/placement/availability-zone": "us-east-1e",
    "/latest/meta-data/placement/availability-zone-id": "use1-az3",
    "/latest/meta-data/placement/region": "us-east-1",
    "/latest/meta-data/public-hostname": "ec2-203-0-113-25.compute-1.amazonaws.com",
    "/latest/meta-data/public-ipv4": "203.0.113.25",
    "/latest/meta-data/security-groups": "\n".join(["default", "test"]),
    "/latest/meta-data/services/domain": "amazonaws.com",
    "/latest/meta-data/services/partition": "aws",
    "/latest/meta-data/tags/instance": "\n".join(TAGS.keys()),
    **{f"/latest/meta-data/tags/instance/{k}": v for k, v in TAGS.items()},
    "/latest/meta-data/mac": MAC,
    **{
        f"/latest/meta-data/network/interfaces/macs/{MAC}/{k}": v
        for k, v in {
            "vpc-id": "vpc-1234567890",
            "subnet-id": "subnet-1234567890",
            "interface-id": "eni-1234567890",
            "security-group-ids": "\n".join(["sg-1234567890", "sg-098764321"]),
        }.items()
    },
    "/latest/meta-data/iam/info": json.dumps(
        {
            "Code": "Success",
            "LastUpdated": "2023-09-12T15:16:58Z",
            "InstanceProfileArn": f"arn:aws:iam::{ACCOUNT_ID}:instance-profile/IMDSTestEc2Role",
            "InstanceProfileId": "AIPATILQWXT62BCWDUQCT",
        }
    ),
    "/latest/meta-data/identity-credentials/ec2/info": json.dumps(
        {
            "Code": "Success",
            "LastUpdated": "2023-09-13T13:13:39Z",
            "AccountId": ACCOUNT_ID,
        }
    ),
    "/latest/meta-data/identity-credentials/ec2/security-credentials/ec2-instance": json.dumps(
        {
            "Code": "Success",
            "LastUpdated": "2023-09-13T13:12:26Z",
            "Type": "AWS-HMAC",
            "AccessKeyId": "ASIATILQWXT67VGGR4O2",
            "SecretAccessKey": "SECRETEXAMPLE",
            "Token": "SECRETEXAMPLE",
            "Expiration": "2023-09-13T19:40:12Z",
        }
    ),
    "/latest/meta-data/public-keys/0/openssh-key": (
        "ssh-rsa "
        "AAAAB3NzaC1yc2EAAAADAQABAAAAgQC63mQI7eNK"
        "/f6ERi37TOvZxnyxfCOvkfFLKEHSh0Z1pR1elFx8aRAbBYJ7xPHBbGX"
        "+qJcld/3qGCDGvCHhnRyYr+7Q+kzK2TQo4"
        "+INIa35GBqjlKAO9Rr47eo1fiXIGSE8LfXrGHrKalnn"
        "+rADWn64IN4tOYA9k+4OSXpyxAOB8Q== test"
    ),
    "/latest/dynamic/instance-identity/document": json.dumps(
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
    "/latest/dynamic/instance-identity/pkcs7": (
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
    "/latest/dynamic/instance-identity/signature": (
        "Puc5GhTTOl31T9LTKTQE4fQLkeSr5sdV5dcXij6oiWlylfcJj2O/juf02ymbRbHDJq4TXdpRs693"
        "heLxjsofvG5cx/2SpnVbrzjn38xy8H3I2YyGbQgddDDDY04fxE9ETQXSNWAKuR2sOv2g+MuBAMc+"
        "paIyVxXMENVHsLehh10="
    ),
    # Azure
    "/metadata/instance": json.dumps(
        {
            "compute": {
                "azEnvironment": "AzurePublicCloud",
                "customData": "",
                "evictionPolicy": "",
                "isHostCompatibilityLayerVm": "true",
                "licenseType": "",
                "location": "westeurope",
                "name": "myVm",
                "offer": "0001-com-ubuntu-server-focal",
                "osProfile": {
                    "adminUsername": "testuser",
                    "computerName": "myVm",
                    "disablePasswordAuthentication": "true",
                },
                "osType": "Linux",
                "placementGroupId": "",
                "plan": {"name": "", "product": "", "publisher": ""},
                "platformFaultDomain": "0",
                "platformUpdateDomain": "0",
                "priority": "",
                "provider": "Microsoft.Compute",
                "publicKeys": [
                    {
                        "keyData": "ssh-rsa AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJQPr4RsDbaJdKPHl2gfCwiWcTRVEu0XlQvsPgdvCH/Io8Im1VfBMamtRhTIEqlEoTaRD8h9ETDQAPg7GUVkg07P3ZgDfFf94KePpxADso7GoqaPsGuL4OQpURa4DQCmf1Jw+kDg0TI1ERYIQoNOGduiS5cuB74A5BxcgW2A52ocVoiINS1tPudZBIvnr8iQXa6BhB5EgUVP0w+pGaOgI4jHga8ThT9weGqzBrtBcyiZ44jfT2Tg/AjI4GuXq14HdFEN0096vk= generated-by-azure",
                        "path": "/home/testuser/.ssh/authorized_keys",
                    }
                ],
                "publisher": "canonical",
                "resourceGroupName": "myVm_group",
                "resourceId": "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/myVm_group/providers/Microsoft.Compute/virtualMachines/myVm",
                "securityProfile": {
                    "secureBootEnabled": "true",
                    "virtualTpmEnabled": "true",
                },
                "sku": "20_04-lts-gen2",
                "storageProfile": {
                    "dataDisks": [],
                    "imageReference": {
                        "id": "",
                        "offer": "0001-com-ubuntu-server-focal",
                        "publisher": "canonical",
                        "sku": "20_04-lts-gen2",
                        "version": "latest",
                    },
                    "osDisk": {
                        "caching": "ReadWrite",
                        "createOption": "FromImage",
                        "diffDiskSettings": {"option": ""},
                        "diskSizeGB": "30",
                        "encryptionSettings": {"enabled": "false"},
                        "image": {"uri": ""},
                        "managedDisk": {
                            "id": "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/myVm_group/providers/Microsoft.Compute/disks/myVm_disk1_5e2103587ca646929255128ff64b5bdb",
                            "storageAccountType": "Premium_LRS",
                        },
                        "name": "myVm_disk1_5e2103587ca646929255128ff64b5bdb",
                        "osType": "Linux",
                        "vhd": {"uri": ""},
                        "writeAcceleratorEnabled": "false",
                    },
                    "resourceDisk": {"size": "34816"},
                },
                "subscriptionId": "11111111-1111-1111-1111-111111111111",
                "tags": "testtag:testvalue;testtag2:testvalue2",
                "tagsList": [
                    {"name": "testtag", "value": "testvalue"},
                    {"name": "testtag2", "value": "testvalue2"},
                ],
                "userData": "",
                "version": "20.04.202308310",
                "vmId": "e94f3f7f-6b23-4395-be46-ea363c549f71",
                "vmScaleSetName": "",
                "vmSize": "Standard_B1ls",
                "zone": "2",
            },
            "network": {
                "interface": [
                    {
                        "ipv4": {
                            "ipAddress": [
                                {
                                    "privateIpAddress": "10.0.0.4",
                                    "publicIpAddress": "20.242.32.12",
                                }
                            ],
                            "subnet": [{"address": "10.0.0.0", "prefix": "24"}],
                        },
                        "ipv6": {"ipAddress": []},
                        "macAddress": "AAAAAAAAAAAA",
                    }
                ]
            },
        }
    ),
    # GCP
    "/computeMetadata/v1/instance": json.dumps(
        {
            "attributes": {
                "ssh-keys": 'test:ecdsa-sha2-nistp256 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKgXTiO1+sSWCEsq/bWaLdY= google-ssh {"userName":"test@crashoverride.com","expireOn":"2023-10-14T15:11:57+0000"}\ntest:ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCvddnbJ/XWxMUPXOsDMNoRHJeaCgwqk6g7UYvrXqogwmJ1WpC1QPuG3mhDjmBOcjINi7TYsozDKZilL2BDu2i6CGC1s2Tokq41lsgnCePNdnYmPcA318PmuMmAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeT7R92kx google-ssh {"userName":"test@crashoverride.com","expireOn":"2023-10-14T15:12:12+0000"}'
            },
            "cpuPlatform": "Intel Broadwell",
            "description": "",
            "disks": [
                {
                    "deviceName": "instance-1",
                    "index": 0,
                    "interface": "SCSI",
                    "mode": "READ_WRITE",
                    "type": "PERSISTENT-BALANCED",
                }
            ],
            "guestAttributes": {},
            "hostname": "instance-1.europe-west1-b.c.test-chalk-402014.internal",
            "id": 133380848178631130,
            "image": "projects/debian-cloud/global/images/debian-11-bullseye-v20231010",
            "licenses": [{"id": "4324324324234234234"}],
            "machineType": "projects/11111111111/machineTypes/e2-micro",
            "maintenanceEvent": "NONE",
            "name": "instance-1",
            "networkInterfaces": [
                {
                    "accessConfigs": [
                        {"externalIp": "35.205.62.123", "type": "ONE_TO_ONE_NAT"}
                    ],
                    "dnsServers": ["169.254.169.254"],
                    "forwardedIps": [],
                    "gateway": "10.132.0.1",
                    "ip": "10.132.0.2",
                    "ipAliases": [],
                    "mac": "42:01:0a:84:00:02",
                    "mtu": 1460,
                    "network": "projects/11111111111/networks/default",
                    "subnetmask": "255.255.240.0",
                    "targetInstanceIps": [],
                }
            ],
            "partnerAttributes": {},
            "preempted": "FALSE",
            "remainingCpuTime": -1,
            "scheduling": {
                "automaticRestart": "TRUE",
                "onHostMaintenance": "MIGRATE",
                "preemptible": "FALSE",
            },
            "serviceAccounts": {
                "11111111111-compute@developer.gserviceaccount.com": {
                    "aliases": ["default"],
                    "email": "11111111111-compute@developer.gserviceaccount.com",
                    "scopes": [
                        "https://www.googleapis.com/auth/devstorage.read_only",
                        "https://www.googleapis.com/auth/logging.write",
                        "https://www.googleapis.com/auth/monitoring.write",
                        "https://www.googleapis.com/auth/servicecontrol",
                        "https://www.googleapis.com/auth/service.management.readonly",
                        "https://www.googleapis.com/auth/trace.append",
                    ],
                },
                "default": {
                    "aliases": ["default"],
                    "email": "11111111111-compute@developer.gserviceaccount.com",
                    "scopes": [
                        "https://www.googleapis.com/auth/devstorage.read_only",
                        "https://www.googleapis.com/auth/logging.write",
                        "https://www.googleapis.com/auth/monitoring.write",
                        "https://www.googleapis.com/auth/servicecontrol",
                        "https://www.googleapis.com/auth/service.management.readonly",
                        "https://www.googleapis.com/auth/trace.append",
                    ],
                },
            },
            "tags": [],
            "virtualClock": {"driftToken": "0"},
            "zone": "projects/11111111111/zones/europe-west1-b",
        }
    ),
}


app = FastAPI()


@app.get("/health")
def health():
    return


@app.put(f"/latest/api/token", response_class=PlainTextResponse)
def token():
    return TOKEN


def endpoint(url: str, value: str):
    app.get(url, response_class=PlainTextResponse)(lambda: value)


for key, value in RESPONSES.items():
    endpoint(f"{key}", value)
