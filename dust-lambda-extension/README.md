# Dust Lambda Extension

## Overview

The `dust` is an AWS [Lambda Extension] meant to be used with zip archive
deployments that have been had both a chalk mark and a chalk binary injected:

```sh
chalk insert --inject-binary-into-zip *.zip
```

which will inject both into the archive:

- `chalk` - chalk binary itself
- `chalk.json` - chalk mark which will include build-time metadata such as repo
  origin, commit id, etc

The extension can then execute `chalk env` on function start to allow `chalk`
to report metadata about Lambda deployment. This can allow to link build
metadata to deployments (e.g. which build is deployed in prod).
This brings zip-based lambda deployments to parity with docker-based functions
which rely on image `ENTRYPOINT` overwrite for similar reporting capability.

## Getting Started

The extension by itself is just a [shell script](./extensions/dust) which uses
[Lambda Extensions API] to execute `chalk env` on start of a function.
The extension itself is added to a Lambda function via [Lambda Layer] ARN.

## Crash Override Public ARNs

For easy deployment, Crash Override publishes its public ARNs of the
extension layer for common regions. To get them use the URL:

```sh
$ curl -fsSL "https://dl.crashoverride.run/dust/$REGION/extension.arn"
```

### Terraform

There is also a [terraform module](https://github.com/crashappsec/terraform-modules/tree/main/aws/dust)
to easily reference the ARN:

```terraform
module "dust" {
  source = "github.com/crashappsec/terraform-modules//aws/dust?ref=main"
}
resource "aws_lambda_function" "example" {
  filename      = "function.zip"
  function_name = "example"
  layers        = [module.dust.arn]
  ...
}
```

## Own AWS Account

`make` can be used to deploy extension directly into any AWS account.
To see all main targets:

```sh
make help
```

### Dependencies

- `make`
- `zip`
- `jq`
- `chalk` should be on `PATH`
- working `aws` profile with IAM permission to publish lambda layer:
  - `lambda:PublishLayerVersion`
  - `lambda:AddLayerVersionPermission`

### Deploy

To deploy layer:

```sh
$ REGIONS=us-east-1 \
  PUBLIC=true \
  make deploy-layer
```

This will publish layer into all regions and will write a place a few files
in `dist` folder:

```
$ tree dist
dist
├── dust-0.0.0.zip
├── dust-0.0.0.zip.sha256
├── extensions
│   └── dust
└── us-east-1
    ├── extension.arn
    ├── extension.json
    └── extension.public
```

You can reference `dist/<REGION>/extension.arn` to get the layer ARN
for that region.

Above Crash Override URL for the public ARN is actually published `dist` folder
from the `make` output.

To customize functionality these environment variables can be provided:

| Environment Variable       | Required | Description                                                                     |
| -------------------------- | -------- | ------------------------------------------------------------------------------- |
| `REGIONS`                  | required | comma (,) delimited list of regions where to publish layer                      |
| `PUBLIC=true`              | optional | whether to make the layer public (can be used by other AWS accounts/principles) |
| `LAYER_NAME`               | optional | name of the layer (this will show up in ARN)                                    |
| `DESCRIPTION`              | optional | layer description                                                               |
| `COMPATIBLE_RUNTIMES`      | optional | which runtimes extension supports                                               |
| `COMPATIBLE_ARCHITECTURES` | optional | which architectures extension supports                                          |

[Lambda Extension]: https://docs.aws.amazon.com/lambda/latest/dg/lambda-extensions.html
[Lambda Extensions API]: https://docs.aws.amazon.com/lambda/latest/dg/runtimes-extensions-api.html
[Lambda Layer]: https://docs.aws.amazon.com/lambda/latest/dg/chapter-layers.html
