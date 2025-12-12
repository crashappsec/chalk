![Chalk Logo](https://chalkproject.io/logo.svg)

[![tests](https://github.com/crashappsec/chalk/actions/workflows/tests.yml/badge.svg?branch=main&event=push)](https://github.com/crashappsec/chalk/actions/workflows/tests.yml?query=branch%3Amain)

## About Chalk

Chalk™ captures metadata at build time, and can add a small 'chalk mark' (metadata) to any
artifacts, so they can be identified in production. Chalk can also extract chalk marks and collect
additional metadata about the operating environment when it does this.

Using Chalk, you can build a graph connecting people, development, builds and production, so that
devops engineers understand what is happening in the development process, and so that developers
can understand what is happening in the infrastructure.

## How-tos

You can use Chalk to solve a variety of specific use cases such as:

### Create software security supply chain compliance reports automatically

Many companies and the US Government are now mandating suppliers to provide supply chain statements
when delivering software. This how to is an easy button to deliver the
[software bill of materials (SBOM)](https://www.cisa.gov/sbom), code and
builds provenance and supports [SLSA](https://www.slsa.dev), Supply-chain Levels for Software
Artifacts, [level 2](https://slsa.dev/spec/v1.0/levels) compliance (an emerging supply chain
standard) before SLSA [level 1](https://slsa.dev/spec/v1.0/levels) has been mandated. Follow this
how-to on our docs site [here](https://chalkproject.io/docs/advanced-topics/sbom/).

### Gathering runtime information using exec reports

From a code base, easily understand the environments where code and even particular branches are
running. Gather code owners for the applications and code repos. Follow this how-to on our docs
site [here](https://chalkproject.io/docs/getting-started/exec/).

### Deploy Chalk globally using Docker

You can deploy Chalk by setting a global symlink for Docker and having it call Chalk, so that every
build that runs through your build server using Docker, will automatically be 'chalked'. It's a
technique that can be combined with chalks ability to deploy tools and configure monitoring, to
automatically add security controls and collect information for every application. Follow this
how-to on our docs site [here](https://chalkproject.io/docs/getting-started/ci-cd/)]

## Getting started

We recommend following the [getting started guide](https://chalkproject.io/docs/getting-started/)
on our documentation web site. Full documentation is also available directly inside the CLI.

We provide free binary downloads on our [release page](https://chalkproject.io/download/).

## Issues

If you encounter any issues with Chalk please submit a GitHub issue to
[this repo](https://github.com/crashappsec/chalk/issues).

## Ideas and feedback

We are constantly learning about emerging use cases for Chalk, and are always interested in hearing
about how others are using it. We are also interested in ideas and feature requests.If you would
like to talk, please get in touch using hello@crashoverride.com.

## Making contributions

We welcome contributions but do require you to complete a contributor license agreement or CLA. You
can read the CLA and about our process [here](https://crashoverride.com/docs/other/contributing).

## Getting additional help

If you need additional help including a demo of the cloud platform, please contact us using
hello@crashoverride.com

## License

Chalk is licensed under the GPL version 3 license.

## Try our cloud platform.

Our cloud hosted platform is built using Chalk. It makes enterprise deployments easy, and provides
additional functionality including prebuilt integrations to enrich your data.

You can learn more at [crashoverride.com](https://crashoverride.com/).
