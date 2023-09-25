# How to Know if a Repository is Deployed to Production Using Chalk and Cloud Custodian

## Summary

Understanding where code is deployed is non-trivial when we are dealing with
modern complex applications with multiple dependencies: different versions of
those dependencies could be deployed at different environments at any given
time. Tracking where code is deployed allows your team to prioritize work
appropriately and respond in a timely fashion to security vulnerabilities or
requests for new features.

In this tutorial, we will examine how chalk can be combined with [cloud
custodian](https://cloudcustodian.io/) to build a map of where services are
deployed. For the purposes of this tutorial, we will only focus on code deployed
to Amazon's Elastic Container Services (ECS),
however the logic of this tutorial applies to any type deployment in AWS or
other cloud provider.

Although this how-to involves serveral manual steps to achieve the desired
end-to-end functionality, we are providing an easy-to-use,
working-out-of-the-box overview of where your code is deployed in our freemium
version of the Crash Override Console (TBD), that requires minimal setup on
the user end: all you need to do is connect chalk to your deployment pipelines,
and set up integrations with your cloud providers, and you get the full map
of where your code is deployed without any additional work. For now, however,
let's see how you could set this up on your own, for a small-scale example

## Prerequisities

- A deployment pipeline that deploys docker containers to ECR, with those
  containers being used in ECS services, and working AWS credentials to query said deployments.
- A working installation of [cloud custodian](https://cloudcustodian.io/).
- A working chalk binary (see [here](./guide-user-guide) on setting that up).

## Steps

The steps overview for this how-to is as follows:

1. Generate Chalk marks for the repo and collect the image hashes for containers
   built
2. Connect to Cloud Custodian and collect the images hashes for deployed
   services
3. Compare the two sets of information to determine which repositories are
   deployed where

### Step 1: Build your repository's containers with chalk

Let's set up an S3 sink for our chalked container images using the following
config

```con4m
sink_config my_s3_config {
  enabled: true
  sink:    "s3"
  uri:     env("AWS_S3_BUCKET_URI")
  secret:  env("AWS_SECRET_ACCESS_KEY")
  uid:     env("AWS_ACCESS_KEY_ID")
}

log_level = "info"

ptr_url := ""

if env_exists("AWS_S3_BUCKET_URI") {
  if not env_exists("AWS_ACCESS_KEY_ID") {
     warn("To configure AWS must provide AWS_ACCESS_KEY_ID")
  } elif not env_exists("AWS_SECRET_ACCESS_KEY") {
     warn("To configure AWS must provide AWS_SECRET_ACCESS_KEY")
  } else {
    subscribe("report", "my_s3_config")
    configured_sink := true
    if ptr_url == "" {
      ptr_url := env("AWS_S3_BUCKET_URI")
    }
  }
}

```

Replace the above environment variables with the values for your deployment.

Add chalk to your CI/CD, and ensure `docker` containers are chalked as [per this
guide](./howto-app-inventory.md).

Once you have everything setup, ensure you get chalk marks reported in your
configured S3 bucket.

### Step 2: Make a deployment of a chalked container and scan your AWS resources using Cloud Custodian

Perform a deployment of the chalked container in some environment of your choice
in AWS (e.g., production / staging / test) For our demo purposes, we will deploy
a server as an ECS service called `backend` to an ECS cluster called `test`. The
container image for that service will be deployed in ECR, and an ECS task with
that service will be getting created in two separate clusters, one representing
"production", and another one representing "staging".

Scan all your ECS services ECS tasks with cloud custodian. For
instance, for getting ecs-services you can use the following policy:

```bash
cat <<EOF > /tmp/custodian.ecs-services.yaml

policies:
  - name: ecs-services
    resource: aws.ecs-service
    conditions:
      - region: us-east-1

EOF
```

and subsequently run `custodian run --output-dir ecs-services /tmp/custodian.ecs-services.yaml`,

whilst for getting aws-tasks you can use

```bash
cat <<EOF > /tmp/custodian.ecs-tasks.yaml

policies:
  - name: ecs-tasks
    resource: aws.ecs-task
    conditions:
      - region: us-east-1

EOF
```

and subsequently run `custodian run --output-dir ecs-tasks /tmp/custodian.ecs-tasks.yaml`.

Notice that JSONs are emitted under the ecs-services and ecs-tasks directories.
We can examine the JSON with the ecs-service information and get the arn of the
ecs-tasks for that service:

```json
  ...
  {
    "serviceArn": "arn:aws:ecs:us-east-1:<account_id>:service/test/test-backend",
    "serviceName": "test-backend",
    "clusterArn": "arn:aws:ecs:us-east-1:<account_id>:cluster/test",
    "loadBalancers": [
      {
        "targetGroupArn": "arn:aws:elasticloadbalancing:us-east-1:<account_id>:targetgroup/test-backend-api/f529240d6aa0961e",
        "containerName": "test-backend",
        "containerPort": 4001
      }
    ],
    "serviceRegistries": [
      {
        "registryArn": "arn:aws:servicediscovery:us-east-1:<account_id>:service/srv-6oitern2yi7oejdc"
      }
    ],
    "status": "ACTIVE",
    "desiredCount": 1,
    "runningCount": 1,
    "pendingCount": 0,
    "launchType": "FARGATE",
    "platformVersion": "LATEST",
    "platformFamily": "Linux",
    "taskDefinition": "arn:aws:ecs:us-east-1:<account_id>:task-definition/test-backend:6",
    "deploymentConfiguration": {
      "deploymentCircuitBreaker": {
        "enable": false,
        "rollback": false
      },
      "maximumPercent": 200,
      "minimumHealthyPercent": 100
    },
    "deployments": [
    ...
```

We notice that the service `test-backend` has a task deployed with arn `arn:aws:ecs:us-east-1:<account_id>:task-definition/test-backend:6"`.

Looking at the JSON emitted by cloud custodian for ecs-task we get:

```json

  {
    ...
    "availabilityZone": "us-east-1a",
    "clusterArn": "arn:aws:ecs:us-east-1:<account_id>:cluster/test",
    "connectivity": "CONNECTED",
    "connectivityAt": "2023-09-18T19:42:14.081000+03:00",
    "containers": [
      {
        "containerArn": "arn:aws:ecs:us-east-1:<account_id>:container/test/450d8c21f9dd4bd9902cd3e458d611f9/2a8ddc59-20eb-48b4-bce7-aec25b796222",
        "taskArn": "arn:aws:ecs:us-east-1:<account_id>:task/test/450d8c21f9dd4bd9902cd3e458d611f9",
        "name": "test-backend",
        "image": "<account_id>.dkr.ecr.us-east-1.amazonaws.com/co/schema/orchestrator:latest",
        "imageDigest": "sha256:89835d866c6157c6a21de9f25ac0701ecb173fc2e1fb17ef23c203317f73770a",
        "runtimeId": "450d8c21f9dd4bd9902cd3e458d611f9-1083846896",
        "lastStatus": "RUNNING",
        "networkBindings": [],
        "networkInterfaces": [
          {
            "attachmentId": "f6d45037-1317-4224-9e6f-b1f2a9d9ad5b",
            "privateIpv4Address": "10.1.134.95"
          }
        ],
        "healthStatus": "UNKNOWN",
        "managedAgents": [
          {
            "lastStartedAt": "2023-09-18T19:42:49.004000+03:00",
            "name": "ExecuteCommandAgent",
            "lastStatus": "RUNNING"
          }
        ],
        "cpu": "0"
      }
    ],
    "cpu": "1024",
    "createdAt": "2023-09-18T19:42:10.606000+03:00",
    "desiredStatus": "RUNNING",
    "enableExecuteCommand": true,
    "group": "service:test-backend",
    "healthStatus": "UNKNOWN",
    "lastStatus": "RUNNING",
    "launchType": "FARGATE",
    "memory": "4096",
    "overrides": {
      "containerOverrides": [
        {
          "name": "test-backend"
        }
      ],
      "inferenceAcceleratorOverrides": []
    },
    "platformVersion": "1.4.0",
    "platformFamily": "Linux",
    "pullStartedAt": "2023-09-18T19:42:23.043000+03:00",
    "pullStoppedAt": "2023-09-18T19:42:36.468000+03:00",
    "startedAt": "2023-09-18T19:43:25.617000+03:00",
    "startedBy": "ecs-svc/2384362026970367360",
    "taskArn": "arn:aws:ecs:us-east-1:<account_id>:task/test/450d8c21f9dd4bd9902cd3e458d611f9",
    "taskDefinitionArn": "arn:aws:ecs:us-east-1:<account_id>:task-definition/test-backend:6",
    "version": 5,
    "ephemeralStorage": {
      "sizeInGiB": 20
    },

```

Notice the `"imageDigest": "sha256:89835d866c6157c6a21de9f25ac0701ecb173fc2e1fb17ef23c203317f73770a"` for the
task. This image digest is a chalked image, with all the metadata we chose to
insert during CI/CD.

### Step 3: Combine Chalk and Custodian metadata

In the previous steps, we chalked a single repository that is deployed to a test
cluster. By comparing image hashes from within chalk and cloud custodian
metadata, we were able to verify that the image from our repository was deployed
to the `test` cluster. Nothing, however in the above process was specific to our
repository or deployment details. We could have
chalked an arbitrary number of repositories, and then determine which images get
propagated to what service by simply doing a lookup on the respective hashes.
Likewise, we could choose to do the `join` of data based on different chalk or
custodian metadata such as tags, naming conventions etc.

This process can be automated via scripting for you to monitor the deployment
status of your repositories across your different environments (e.g.,
test/staging/prod).

Integrations of chalk with AWS and other cloud providers will be made available
in our upcoming freemium release of the chalk console, which will make such
functionality readily available to users out of the box.
