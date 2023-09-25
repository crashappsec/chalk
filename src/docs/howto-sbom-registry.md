# Create And Maintain An SBOM Registry Using Chalk

### Automatically Generate SBOMs In Your Build Process For Every Code Repo, And Send This Data To A Central Location For Further Analysis

## Summary

By adding one line to your CI/CD build script, you can automatically
create an SBOMs or software bill of materials, when each code repo
that is built. You can use your existing SCA or Software Composition
Analysis tools, or fall back to Chalk™ built-in defaults.

After automatically sending the SBOMs to a central location using chalk, you can then query all of your SBOMs across your environment
to solve additional problems including understanding where you have
specific 3rd party libraries, which ones may have vulnerabilities, or
which ones have licenses that are not compatible with your company
policy.

By using chalk and following this how to, instead of alternative
methodologies, you are able to automatically add additional valuable
metadata that chalk collects or generates, so that you can
prioritise what to work on - Now, next or Never.

By using chalk and following this how-to, instead of alternative
methodologies, you are able to automatically use metadata that chalk
collects or generates, and combine it with data from your existing
developer, security and infrastructure tools such as the
CloudCustodian CSPM, so you can prioritise what to work on - Now, next
or Never.

If you do not understand how Chalk works we recomend reading the
[Chalk overview](./guide-overview.md).

## When to use this

SBOMs can be used to understand the components that are in a
build. They can also be used to check components against known
vulnerabilities such as CVEs. You should always maintain a current
list of SBOMs for every code repo so you can investigate issues in
production applications when they occur. In a term building
distributed software, creating and maintaining a central SBOM registry
allows you to analyse and understand your software across your
environment.

## Alternative solutions

You could achieve the same results by manually scanning each code repo
with commercial or open source software composition analysis tools,
and writing a script to send the data to a central location.

This how-to saves you significant time and work, by doing all of
the steps above out of the box but importantly is enables you to
enrich the central SBOM registry with valuable metadata from chalk and
other tools.

## Prerequisites

### Required

- You must have a working installation of chalk.

The easiest way to get chalk is to download a pre-built binary from
our [release page](https://crashoverride.com/releases). It's a
self-contained binary with no dependencies to install.

- We also assume working installation of
  [`git`](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git). This
  is only required to follow the step here and not needed for a
  production build installation, depending on your set up.

### Optional

- The [jq](https://jqlang.github.io/jq/download/) utility is helpful for pretty-printing
  JSON throughout this guide. For instance, `tail -1 ~/.local/chalk/chalk.log | jq` will parse a
  the last entry in chalk.log (a JSON object) and will display it in the terminal. If you don't
  have / would rather not have `jq` installed, you can omit `| jq` (pipe-to-jq) from the corresponding commands in this guide.

## Steps

### Before you start

#### Test your Chalk installation

```bash
chalk --version
```

You should expect the output to be something like:

```bash
┏┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┳┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┓
┋ Chalk version ┋ 0.1.1                                    ┋
┋ Commit ID     ┋ 6b943b6d9c2a08b55d0b1c4610aef1aeaa6b481a ┋
┋ Build OS      ┋ macosx                                   ┋
┋ Build CPU     ┋ arm64                                    ┋
┋ Build Date    ┋ 2023-09-24                               ┋
┋ Build Time    ┋ 19:37:36                                 ┋
┗┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┻┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┉┛
```

But, probably in color, and with a different commit ID.

You should now have a working installation of chalk. You should now
test that your chalk installation will create valid chalk
marks. In the example below we have created a simple Node project but
you can easily substitute this with your own code repo.

In your terminal type

```bash
mkdir -p ~/chalk-test && cd ~/experiments && git clone https://github.com/crashappsec/chalk-test-demo.git
```

This will create a local directory called chalk-test-demo, and use Git
to clone the chalk-test-demo repo from Github.

In your terminal type

```bash
cd chalk-test && chalk insert
```

This injects chalk metadata and create a `Chalk` report in the local folder. To view the report, in your terminal type

```bash
tail -1 ~/.local/chalk/chalk.log | jq
```

You are now able to successfully generate chalk marks.

### Step 1 - How to generate the SBOM

Chalk doesn't collect SBOMs by default, but getting it to do so is
easy. For instance, in your terminal and existing chalk-test-demo
directory type

```bash
chalk insert --run-sbom-tools
```

Without optional configuration chalk has now created the SBOM using
the built-in SBOM generation tool
[Syft](https://github.com/anchore/syft) and created a
[CycloneDX](https://www.cyclonedx.org) SBOM.

When using `--run-sbom-tools`, chalk added the SBOM to a chalk report
rather than to the chalk mark. This is because SBOMs can become very
large documents and would affect global performance. Chalk reports are
sent to a destination location, by default the local filesystem.

To view the local chalk report containing the SBOM, in your terminal type

```bash
tail -1 ~/.local/chalk/chalk.log | jq
```

You will see the a big JSON blob, including an SBOM. It's large, so
we'll emit a lot of it, but you should see something like:

```json
{
  ...
  "PLATFORM_WHEN_CHALKED": "GNU/Linux x86_64",
    "SBOM": {
      "syft": {
        "$schema": "http://cyclonedx.org/schema/bom-1.4.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": "1.4",
        "serialNumber": "urn:uuid:1e2374e3-1d13-4d46-b160-44f8e18ec443",
        "version": 1,
        "metadata": {
          "timestamp": "2023-09-17T09:35:11-04:00",
          "tools": [
            {
              "vendor": "anchore",
              "name": "syft",
              "version": "0.90.0"
            }
          ],
          "component": {
            "bom-ref": "27b419ad7279686a",
            "type": "file",
            "name": "github-analyzer",
            "version": "sha256:sha256:9c8ff699d54cc04c50522681b43e0e1a8e533c53aaae7a9c67b8891e87937f16"
          }
        },
        "components": [
          {
            "bom-ref": "pkg:golang/command-line-arguments@v0.1.0-alpha-8-g04133d2?package-id=7119c1a579f3696b",
            "type": "library",
            "name": "command-line-arguments",
            "version": "v0.1.0-alpha-8-g04133d2",
            "purl": "pkg:golang/command-line-arguments@v0.1.0-alpha-8-g04133d2",
            "properties": [
              {
                "name": "syft:package:foundBy",
                "value": "go-module-binary-cataloger"
              },
              {
                "name": "syft:package:language",
                "value": "go"
              },
              {
                "name": "syft:package:metadataType",
                "value": "GolangBinMetadata"
              },
              {
                "name": "syft:package:type",
                "value": "go-module"
              },
              {
                "name": "syft:location:0:path",
                "value": "/github-analyzer"
              },
              {
                "name": "syft:metadata:architecture",
                "value": "amd64"
              },
              {
                "name": "syft:metadata:goBuildSettings:-compiler",
                "value": "gc"
              },
              {
                "name": "syft:metadata:goBuildSettings:-ldflags",
                "value": "-X main.version=v0.1.0-alpha-8-g04133d2"
              },
              {
                "name": "syft:metadata:goBuildSettings:CGO_ENABLED",
                "value": "1"
              },
              {
                "name": "syft:metadata:goBuildSettings:GOAMD64",
                "value": "v1"
              },
              {
                "name": "syft:metadata:goBuildSettings:GOARCH",
                "value": "amd64"
              },
              {
                "name": "syft:metadata:goBuildSettings:GOOS",
                "value": "linux"
              },
              {
                "name": "syft:metadata:goCompiledVersion",
                "value": "go1.19.8"
              },
              {
                "name": "syft:metadata:goCryptoSettings:0",
                "value": "standard-crypto"
              },
              {
                "name": "syft:metadata:mainModule",
                "value": "command-line-arguments"
              }
            ]
          },
          {
            "bom-ref": "pkg:golang/github.com/puerkitobio/goquery@v1.8.0?package-id=b1a759d8f0ba87ec",
            "type": "library",
            "name": "github.com/PuerkitoBio/goquery",
            "version": "v1.8.0",
            "cpe": "cpe:2.3:a:PuerkitoBio:goquery:v1.8.0:*:*:*:*:*:*:*",
            "purl": "pkg:golang/github.com/PuerkitoBio/goquery@v1.8.0",
            "properties": [
              {
                "name": "syft:package:foundBy",
                "value": "go-module-binary-cataloger"
              },
              {
                "name": "syft:package:language",
                "value": "go"
              },
              {
                "name": "syft:package:metadataType",
                "value": "GolangBinMetadata"
              },
              {
                "name": "syft:package:type",
                "value": "go-module"
              },
              {
                "name": "syft:location:0:path",
                "value": "/github-analyzer"
              },
              {
                "name": "syft:metadata:architecture",
                "value": "amd64"
              },
              {
                "name": "syft:metadata:goCompiledVersion",
                "value": "go1.19.8"
              },
              {
                "name": "syft:metadata:goCryptoSettings:0",
                "value": "standard-crypto"
              },
              {
                "name": "syft:metadata:h1Digest",
                "value": "h1:PJTF7AmFCFKk1N6V6jmKfrNH9tV5pNE6lZMkG0gta/U="
              },
              {
                "name": "syft:metadata:mainModule",
                "value": "command-line-arguments"
              }
            ]
          },
          ...
}
```

> ❗ By default, when you run `chalk extract` on an artifact to report
> on it, it will not show all the contents, just a small summary. You
> must inspect the chalk report in the chalk.log file.

### Step 2 - Configuring Your SBOM Registry Destination

You can also read the complete help guide, [Configuring Chalk Reports](./guide-config-overview.md).

To send the SBOM metadata to a data destination or sink of your
choice, you simply include `key.SBOM.use = true` in your chalk
[reports template](./guide-config-overview.md) and set
`run_sbom_tools=true` in the corresponding [config
file](./guide-config-overview.md).

<!--- JV: These should probably link into the user guide? Or the gen'd
sections? --->

To create a central SBOM registry we recommend sending all of your
SBOMs to an Amazon Web Services or AWS S3 bucket.

For this how to we will can send chalk reports containing the SBOMs
from any local chalk event, to a shared local folder.

To create that folder type the following in your terminal `mkdir -p ~/chalk-sbom-registry`

Save the following config in your current folder (chalk-test-demo) by running:

<!--- JV: This is no longer valid with the switch to `report_template`  -->

```bash

cat > custom_report_sbom.con4m << EOF

report_template sbom_report_sample {
    key.SBOM.use                = true
    key.CHALK_ID.use            = true
    key.DATE_CHALKED.use        = true
    key.PATH_WHEN_CHALKED.use   = true
}

sink_config local_log {
    sink: "file"
    filename: "~/chalk-sbom-registry/custom_report.log"
    enabled: true
}

custom_report my_sbom_report {
  report_template: "sbom_report_sample"
  sink_configs: ["local_log"]
  use_when: ["insert", "extract", "exec"]
}

run_sbom_tools = true

EOF
```

Using this configuration, each time chalk runs, it will generate a
chalk report, containing an SBOM and send it to the central folder.

Try the above using

```bash
chalk --config-file=custom_report_sbom.con4m insert
```

and verify that custom_report.log was created under ~/chalk-sbom-registry

We recommend sending SBOMs to an AWS S3 bucket, where you can connect
them to data analysis tools of your choice.

## Next Steps
Our cloud hosted platform is built using Chalk. It makes enterprise deployment easy, and provides additional functionality including prebuilt integrations to enrich your data, a built-in query editor, an API and more.

There are both free and paid plans. You can [join the waiting list](https://crashoverride.com/join-the-waiting-list) for early access.

## Related How tos

<!-- How to enrich SBOMs with CSPM data using Chalk, to make better security decisions -->

[How-to Handle "Software Security Supply Chain" Requests With Minimal Effort](howto-compliance.md)

## Background Information

Software Composition Analysis or SCA is a term used to describe tools that collect and report on the software inside of a project, normally the list of third-party open-source packages. These tools have become a standard part of the appsec and DevSecOps tool chains, since the rise of software security supply chain attacks. 

SBOMs or [Software Bills of Materials
(SBOMs)](https://www.cisa.gov/sbom) have gained significant traction
in the security and developer community over the past years.

There are two main formats for SBOMs. [CycloneDX](https://cyclonedx.org/) is the most widely adopted and most comprehensive specification. CycloneDX is a BOM or Bill of Materials that has sub specifications including the SBOM or Software Bill Of Materials. [SPDX](https://spdx.org) is a specification maintained by the Linux Foundation that has its roots in software license compliance. 


## FAQ

- Q: **How do I send SBOM metadata without actually chalking?**

  A: You can emit SBOMs without actually embedding chalk metadata by passing
  `--virtual` as a chalk argument.

- Q: **How do I send SBOM metadata to S3 or other endoint?**

  A: The report can be attached to any number of sinks, using appropriate filters.

- Q: **How can we embed SBOM metadata to the chalked artifact?**

  A: SBOMs can get fairly large, but we do show how to do this in our [How-to Handle "Software Security Supply Chain" Requests With Minimal Effort](howto-compliance.md)

## Related Docs and References

- https://crashoverride.com/blog/the-sbom-frenzy-is-premature/
