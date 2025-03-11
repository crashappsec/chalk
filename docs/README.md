# Chalk Documentation

## About Chalk

Chalk is an open-source observability tool created by
[Crash Override](https://crashoverride.com) that provides full lifecycle
visibility into your software development process. Chalk acts like GPS for your
software, allowing you to easily see where software comes from and where it
gets deployed.

Chalk collects, stores, and reports metadata about software from build to
production. The connection is made by adding an identifying mark (which we
call a _chalk mark_) into artifacts at build time, ensuring they can be easily
validated and extracted later.

### Core Capabilities

- **Chalk Mark Insertion**: Add chalk marks to software artifacts (binaries,
  containers, scripts) during build time
- **Extraction**: Extract marks from artifacts already in production
- **Reporting**: Generate comprehensive reports about artifacts and environments
- **Runtime Monitoring**: Configure heartbeat monitoring for deployed applications
- **Supply Chain Security**: Generate SBOMs,
  collect code provenance data, and provide digital signatures

## Getting Started

New to Chalk? Start here to learn the basics:

- [Getting Started Guide](./guide-getting-started.md) - A step-by-step introduction to Chalk
- [Installing](./install.md) - How to install chalk.
- [Quick Start Guide](./guide-quick-start.md) - Quick guide covering chalk basics.
- [Glossary](./glossary.md) - Important chalk terms.
- [Using in CI/CD](./guide-ci-cd.md) - How to install and use chalk in CI/CD.
- [Exec reporting](./guide-exec.md) - How to use exec and heartbeat reports.h
- [User Guide](./guide-user.md) - A comprehensive reference for users and implementers

## Chalk Features

- [Attestation](./attestation.md) - Enabling and using automatic attestations in chalk
- [Docker Wrapping](./docker-wrapping.md) - How chalk wraps docker builds.
- [k8s Docker ENTRYPOINT Wrapping](./docker-k8s.md) - How to use chalked containers in k8s.
- [Custom Configurations](./config-overview.md) - Writing your own configurations
- [Custom Keys](./config-custom-keys.md) - Collecting your own custom keys
- [Configuration FAQ](./config-faq.md) - Common questions about configurations

## Release Information

- [Release Notes](../CHANGELOG.md) - Details of latest releases

<!--
## Contributions

TODO

We welcome contributions to our open-source projects. Find more information at
[crashoverride.com/docs/other/contributing](https://crashoverride.com/docs/other/contributing)
or check our [contribution guidelines](./overview.md).
-->

## Downloads

We provide binary releases for our open-source projects at
[crashoverride.com/downloads](https://crashoverride.com/downloads).

## Help and Support

If you need additional help, get in touch at
[crashappsec/chalk](https://github.com/crashappsec/chalk).
