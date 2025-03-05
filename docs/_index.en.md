# Chalk Documentation

![Chalk Logo](../pages/img/documentation.png)

## About Chalk

Chalk is an open-source observability tool created by [Crash Override](https://crashoverride.com)
that provides full lifecycle visibility into your software development process. Chalk acts like GPS
for your software, allowing you to easily see where software comes from and where it gets deployed.

Chalk collects, stores, and reports metadata about software from build to production. The connection
is made by adding an identifying mark (which we call a _chalk mark_) into artifacts at build time,
ensuring they can be easily validated and extracted later.

### Core Capabilities

- **Chalk Mark Insertion**: Add chalk marks to software artifacts (binaries, containers, scripts)
  during build time
- **Extraction**: Extract marks from artifacts already in production
- **Reporting**: Generate comprehensive reports about artifacts and environments
- **Runtime Monitoring**: Configure heartbeat monitoring for deployed applications
- **Supply Chain Security**: Generate SBOMs, collect code provenance data, and provide digital
  signatures

## About Crash Override

Crash Override is a company that develops a cloud platform providing observability for the software
engineering lifecycle. Our flagship open-source project is Chalk. The platform is expected to be
generally available in early 2025.

You can register to use our cloud platform while it is in beta at
[crashoverride.com/signup](https://crashoverride.com/signup), or contact us at any time using
[crashoverride.com/contact-us](https://crashoverride.com/contact-us).

## Getting Started

New to Chalk? Start here to learn the basics:

- [Getting Started Guide](./chalk/getting-started.md) - A step-by-step introduction to Chalk
- [User Guide](./chalk/user-guide.md) - A comprehensive reference for users and implementors

## Core Documentation

- [Command Line Reference](./chalk/command-line.md) - Details all available commands and flags
- [Configuration Overview](./chalk/config-overview.md) - Learn how to configure Chalk
- [Configuration Options Guide](./chalk/config-overview/config-file.md) - Detailed reference for
  configuration properties
- [Metadata Reference](./chalk/config-overview/metadata.md) - Details what metadata Chalk can
  collect and report

## How-To Guides

Our How-To Guides provide recipes to solve specific problems:

- [Create a real-time application inventory](./how-to-guides/how-to-create-a-real-time-application-inventory.md)
- [Create software security supply chain compliance reports](./how-to-guides/how-to-create-software-security-supply-chain-compliance-reports-automatically.md)
- [Run SAST tools on build](./how-to-guides/how-to-automatically-run-sast-tools-on-build.md)
- [Deploy Chalk globally using Docker](./how-to-guides/how-to-deploy-chalk-globally-using-docker.md)
- [Run containers to browse Chalk data locally](./how-to-guides/how-to-run-containers-to-browse-chalk-data-locally.md)

## Configuration Deep Dives

- [Output Configuration](./chalk/config-overview/output-config.md) - Configure where reports get
  sent
- [Built-in Functions](./chalk/config-overview/builtins.md) - Functions available in configuration
  files
- [Custom Configurations](./chalk/config-overview/custom-config.md) - Writing your own
  configurations
- [FAQ](./chalk/config-overview/faq.md) - Common questions about configurations

## Advanced Topics

- [Hashing in Chalk](./chalk/hashing.md) - How Chalk uses cryptographic hashing
- [Heartbeat Configuration](./chalk/heartbeat.md) - Configure periodic reporting
- [Signing Key Provider](./chalk/signing-key-provider.md) - Information about the Chalk Signing Key
  Provider Service

## Release Information

- [Release Notes](./chalk/release-notes.md) - Details of latest releases and known issues

## Contributions

We welcome contributions to our open-source projects. Find more information at
[crashoverride.com/docs/other/contributing](https://crashoverride.com/docs/other/contributing) or
check our [contribution guidelines](./overview.md).

## Downloads

We provide binary releases for our open-source projects at [crashoverride.com/releases](https://crashoverride.com/downloads).

## Help and Support

If you need additional help, or would like a demo of the cloud platform, please contact us using
[crashoverride.com/contact-us](https://crashoverride.com/contact-us).

## Subscribe to Updates

We operate a newsletter that is sent periodically with information about new product features. You
can sign up from our homepage, [crashoverride.com](https://crashoverride.com). You can also follow
our blog at [crashoverride.com/blog](https://crashoverride.com/blog).
