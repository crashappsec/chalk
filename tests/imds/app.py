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
# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-metadata-endpoint-v4.html
# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-metadata-endpoint-v4-fargate.html
# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-metadata-endpoint-v3-fargate.html
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
    "/ecs": json.dumps(
        {
            "DockerId": "cd189a933e5849daa93386466019ab50-2495160603",
            "Name": "curl",
            "DockerName": "curl",
            "Image": "111122223333.dkr.ecr.us-west-2.amazonaws.com/curltest:latest",
            "ImageID": "sha256:25f3695bedfb454a50f12d127839a68ad3caf91e451c1da073db34c542c4d2cb",
            "Labels": {
                "com.amazonaws.ecs.cluster": "arn:aws:ecs:us-west-2:111122223333:cluster/default",
                "com.amazonaws.ecs.container-name": "curl",
                "com.amazonaws.ecs.task-arn": "arn:aws:ecs:us-west-2:111122223333:task/default/cd189a933e5849daa93386466019ab50",
                "com.amazonaws.ecs.task-definition-family": "curltest",
                "com.amazonaws.ecs.task-definition-version": "2",
            },
            "DesiredStatus": "RUNNING",
            "KnownStatus": "RUNNING",
            "Limits": {"CPU": 10, "Memory": 128},
            "CreatedAt": "2020-10-08T20:09:11.44527186Z",
            "StartedAt": "2020-10-08T20:09:11.44527186Z",
            "Type": "NORMAL",
            "Networks": [
                {
                    "NetworkMode": "awsvpc",
                    "IPv4Addresses": ["192.0.2.3"],
                    "AttachmentIndex": 0,
                    "MACAddress": "0a:de:f6:10:51:e5",
                    "IPv4SubnetCIDRBlock": "192.0.2.0/24",
                    "DomainNameServers": ["192.0.2.2"],
                    "DomainNameSearchList": ["us-west-2.compute.internal"],
                    "PrivateDNSName": "ip-10-0-0-222.us-west-2.compute.internal",
                    "SubnetGatewayIpv4Address": "192.0.2.0/24",
                }
            ],
            "ContainerARN": "arn:aws:ecs:us-west-2:111122223333:container/05966557-f16c-49cb-9352-24b3a0dcd0e1",
            "LogOptions": {
                "awslogs-create-group": "true",
                "awslogs-group": "/ecs/containerlogs",
                "awslogs-region": "us-west-2",
                "awslogs-stream": "ecs/curl/cd189a933e5849daa93386466019ab50",
            },
            "LogDriver": "awslogs",
            "Snapshotter": "overlayfs",
        }
    ),
    "/ecs/task": json.dumps(
        {
            "Cluster": "arn:aws:ecs:us-east-1:123456789012:cluster/clusterName",
            "TaskARN": "arn:aws:ecs:us-east-1:123456789012:task/MyEmptyCluster/bfa2636268144d039771334145e490c5",
            "Family": "sample-fargate",
            "Revision": "5",
            "DesiredStatus": "RUNNING",
            "KnownStatus": "RUNNING",
            "Limits": {"CPU": 0.25, "Memory": 512},
            "PullStartedAt": "2023-07-21T15:45:33.532811081Z",
            "PullStoppedAt": "2023-07-21T15:45:38.541068435Z",
            "AvailabilityZone": "us-east-1d",
            "Containers": [
                {
                    "DockerId": "bfa2636268144d039771334145e490c5-1117626119",
                    "Name": "curl-image",
                    "DockerName": "curl-image",
                    "Image": "curlimages/curl",
                    "ImageID": "sha256:daf3f46a2639c1613b25e85c9ee4193af8a1d538f92483d67f9a3d7f21721827",
                    "Labels": {
                        "com.amazonaws.ecs.cluster": "arn:aws:ecs:us-east-1:123456789012:cluster/MyEmptyCluster",
                        "com.amazonaws.ecs.container-name": "curl-image",
                        "com.amazonaws.ecs.task-arn": "arn:aws:ecs:us-east-1:123456789012:task/MyEmptyCluster/bfa2636268144d039771334145e490c5",
                        "com.amazonaws.ecs.task-definition-family": "sample-fargate",
                        "com.amazonaws.ecs.task-definition-version": "5",
                    },
                    "DesiredStatus": "RUNNING",
                    "KnownStatus": "RUNNING",
                    "Limits": {"CPU": 128},
                    "CreatedAt": "2023-07-21T15:45:44.91368314Z",
                    "StartedAt": "2023-07-21T15:45:44.91368314Z",
                    "Type": "NORMAL",
                    "Networks": [
                        {
                            "NetworkMode": "awsvpc",
                            "IPv4Addresses": ["172.31.42.189"],
                            "AttachmentIndex": 0,
                            "MACAddress": "0e:98:9f:33:76:d3",
                            "IPv4SubnetCIDRBlock": "172.31.32.0/20",
                            "DomainNameServers": ["172.31.0.2"],
                            "DomainNameSearchList": ["ec2.internal"],
                            "PrivateDNSName": "ip-172-31-42-189.ec2.internal",
                            "SubnetGatewayIpv4Address": "172.31.32.1/20",
                        }
                    ],
                    "ContainerARN": "arn:aws:ecs:us-east-1:123456789012:container/MyEmptyCluster/bfa2636268144d039771334145e490c5/da6cccf7-1178-400c-afdf-7536173ee209",
                    "Snapshotter": "overlayfs",
                },
                {
                    "DockerId": "bfa2636268144d039771334145e490c5-3681984407",
                    "Name": "fargate-app",
                    "DockerName": "fargate-app",
                    "Image": "public.ecr.aws/docker/library/httpd:latest",
                    "ImageID": "sha256:8059bdd0058510c03ae4c808de8c4fd2c1f3c1b6d9ea75487f1e5caa5ececa02",
                    "Labels": {
                        "com.amazonaws.ecs.cluster": "arn:aws:ecs:us-east-1:123456789012:cluster/MyEmptyCluster",
                        "com.amazonaws.ecs.container-name": "fargate-app",
                        "com.amazonaws.ecs.task-arn": "arn:aws:ecs:us-east-1:123456789012:task/MyEmptyCluster/bfa2636268144d039771334145e490c5",
                        "com.amazonaws.ecs.task-definition-family": "sample-fargate",
                        "com.amazonaws.ecs.task-definition-version": "5",
                    },
                    "DesiredStatus": "RUNNING",
                    "KnownStatus": "RUNNING",
                    "Limits": {"CPU": 2},
                    "CreatedAt": "2023-07-21T15:45:44.954460255Z",
                    "StartedAt": "2023-07-21T15:45:44.954460255Z",
                    "Type": "NORMAL",
                    "Networks": [
                        {
                            "NetworkMode": "awsvpc",
                            "IPv4Addresses": ["172.31.42.189"],
                            "AttachmentIndex": 0,
                            "MACAddress": "0e:98:9f:33:76:d3",
                            "IPv4SubnetCIDRBlock": "172.31.32.0/20",
                            "DomainNameServers": ["172.31.0.2"],
                            "DomainNameSearchList": ["ec2.internal"],
                            "PrivateDNSName": "ip-172-31-42-189.ec2.internal",
                            "SubnetGatewayIpv4Address": "172.31.32.1/20",
                        }
                    ],
                    "ContainerARN": "arn:aws:ecs:us-east-1:123456789012:container/MyEmptyCluster/bfa2636268144d039771334145e490c5/f65b461d-aa09-4acb-a579-9785c0530cbc",
                    "Snapshotter": "overlayfs",
                },
            ],
            "LaunchType": "FARGATE",
            "ClockDrift": {
                "ClockErrorBound": 0.446931,
                "ReferenceTimestamp": "2023-07-21T16:09:17Z",
                "ClockSynchronizationStatus": "SYNCHRONIZED",
            },
            "EphemeralStorageMetrics": {"Utilized": 261, "Reserved": 20496},
        }
    ),
    "/ecs/task/stats": json.dumps(
        {
            "3d1f891cded94dc795608466cce8ddcf-464223573": {
                "read": "2020-10-08T21:24:44.938937019Z",
                "preread": "2020-10-08T21:24:34.938633969Z",
                "pids_stats": {},
                "blkio_stats": {
                    "io_service_bytes_recursive": [
                        {"major": 202, "minor": 26368, "op": "Read", "value": 638976},
                        {"major": 202, "minor": 26368, "op": "Write", "value": 0},
                        {"major": 202, "minor": 26368, "op": "Sync", "value": 638976},
                        {"major": 202, "minor": 26368, "op": "Async", "value": 0},
                        {"major": 202, "minor": 26368, "op": "Total", "value": 638976},
                    ],
                    "io_serviced_recursive": [
                        {"major": 202, "minor": 26368, "op": "Read", "value": 12},
                        {"major": 202, "minor": 26368, "op": "Write", "value": 0},
                        {"major": 202, "minor": 26368, "op": "Sync", "value": 12},
                        {"major": 202, "minor": 26368, "op": "Async", "value": 0},
                        {"major": 202, "minor": 26368, "op": "Total", "value": 12},
                    ],
                    "io_queue_recursive": [],
                    "io_service_time_recursive": [],
                    "io_wait_time_recursive": [],
                    "io_merged_recursive": [],
                    "io_time_recursive": [],
                    "sectors_recursive": [],
                },
                "num_procs": 0,
                "storage_stats": {},
                "cpu_stats": {
                    "cpu_usage": {
                        "total_usage": 1137691504,
                        "percpu_usage": [
                            696479228,
                            441212276,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                        ],
                        "usage_in_kernelmode": 80000000,
                        "usage_in_usermode": 810000000,
                    },
                    "system_cpu_usage": 9393210000000,
                    "online_cpus": 2,
                    "throttling_data": {
                        "periods": 0,
                        "throttled_periods": 0,
                        "throttled_time": 0,
                    },
                },
                "precpu_stats": {
                    "cpu_usage": {
                        "total_usage": 1136624601,
                        "percpu_usage": [
                            695639662,
                            440984939,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                            0,
                        ],
                        "usage_in_kernelmode": 80000000,
                        "usage_in_usermode": 810000000,
                    },
                    "system_cpu_usage": 9373330000000,
                    "online_cpus": 2,
                    "throttling_data": {
                        "periods": 0,
                        "throttled_periods": 0,
                        "throttled_time": 0,
                    },
                },
                "memory_stats": {
                    "usage": 6504448,
                    "max_usage": 8458240,
                    "stats": {
                        "active_anon": 1675264,
                        "active_file": 557056,
                        "cache": 651264,
                        "dirty": 0,
                        "hierarchical_memory_limit": 536870912,
                        "hierarchical_memsw_limit": 9223372036854772000,
                        "inactive_anon": 0,
                        "inactive_file": 3088384,
                        "mapped_file": 430080,
                        "pgfault": 11034,
                        "pgmajfault": 5,
                        "pgpgin": 8436,
                        "pgpgout": 7137,
                        "rss": 4669440,
                        "rss_huge": 0,
                        "total_active_anon": 1675264,
                        "total_active_file": 557056,
                        "total_cache": 651264,
                        "total_dirty": 0,
                        "total_inactive_anon": 0,
                        "total_inactive_file": 3088384,
                        "total_mapped_file": 430080,
                        "total_pgfault": 11034,
                        "total_pgmajfault": 5,
                        "total_pgpgin": 8436,
                        "total_pgpgout": 7137,
                        "total_rss": 4669440,
                        "total_rss_huge": 0,
                        "total_unevictable": 0,
                        "total_writeback": 0,
                        "unevictable": 0,
                        "writeback": 0,
                    },
                    "limit": 9223372036854772000,
                },
                "name": "curltest",
                "id": "3d1f891cded94dc795608466cce8ddcf-464223573",
                "networks": {
                    "eth1": {
                        "rx_bytes": 2398415937,
                        "rx_packets": 1898631,
                        "rx_errors": 0,
                        "rx_dropped": 0,
                        "tx_bytes": 1259037719,
                        "tx_packets": 428002,
                        "tx_errors": 0,
                        "tx_dropped": 0,
                    }
                },
                "network_rate_stats": {
                    "rx_bytes_per_sec": 43.298687872232854,
                    "tx_bytes_per_sec": 215.39347269466413,
                },
            }
        }
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
