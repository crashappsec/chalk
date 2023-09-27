# Create and maintain an SBOM registry

### Use Chalk to automatically generate SBOMs in your build process for every code repo, and send this data to a central location for further analysis

## Summary

SBOMs or Software Bills Of Materials have become a popular way of describing the contents of a code repo, and are now mandated by the US government, and required by many software consumers.

Generating an individual SBOM is not hard, but automatically creating them with each build, and storing them in a central location that you can use for further analysis, requires a lot of setup.

This how-to uses Chalk™ to automate this in two steps:

1. Configure chalk to generate SBOMs
2. Configure chalk to generate SBOM reports

## Steps

### Before you start

You should have a working installation of chalk. See the [Getting Started Guide](./guide-getting-started.md).

You should have a working installation of
[`git`](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git). This
is required to follow this how-to, and not needed for a
production build installation.

Optionally the [jq](https://jqlang.github.io/jq/download/) utility is helpful for pretty-printing
JSON throughout this how-to. For instance, `tail -1 ~/.local/chalk/chalk.log | jq` will parse a
the last entry in chalk.log (a JSON object) and will display it in the terminal. If you don't
have / would rather not have `jq` installed, you can omit `| jq` (pipe-to-jq) from the corresponding commands in this guide.

### Step 1 - Configure chalk to generate SBOMs

Chalk doesn't collect SBOMs by default.

Create a working folder like chalk-test ad clone a test application such as [https://github.com/crashappsec/github-analyzer](https://github.com/crashappsec/github-analyzer).

In your terminal type:

`git clone https://github.com/crashappsec/github-analyzer.git`

To generate an SBOM simply type:

`chalk insert --run-sbom-tools`

That is it, quite literally it. Without any additional configuration, chalk has created an SBOM using
the built-in SBOM generation tool
[Syft](https://github.com/anchore/syft), in the
[CycloneDX](https://www.cyclonedx.org) SBOM specification.

When using `--run-sbom-tools`, chalk adds the SBOM to a chalk report, rather than to the chalk mark. This is because SBOMs can be very large documents and would affect global performance. See the [Chalk User Guide](./guide-user-guide.md) to understand more about chalk marks and chalk reports. This is because SBOMs can be very
large documents and would affect global performance.

To view the SBOM that chalk created, you can look in the chalk report, by default in local filesystem.

In your terminal type:

`tail -1 ~/.local/chalk/chalk.log | jq`

You will see the a JSON blob, the chalk report, including the SBOM. These can be very large depending on the complexity of your software project, and so the example below is truncated very early in the file for illustrative purposed only.

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

<truncated>

```

> ❗ By default, when you run `chalk extract` to view a chalk report, it will not show all the contents, just a small summary. You
> must inspect the chalk report in the chalk.log file.

Chalk uses configuration files written using [con4m](https://github.com/crashappsec/con4m), a configuration language we created to make it easy to setup metadata collection. You can read about chalk configuration files in the [Configuration Guide](./guide-config-overview.md).

Simply add the following line to your configuration file, and time you run chalk, you will now automatically generate an SBOM.

`run_sbom_tools=true`

You can read the [Configuration Guide](./guide-config-overview.md) to learn how to run your own SBOM generation tools, and create other SBOM specifications like SPDX.

### Step 2 -Configure chalk to generate SBOM reports

Chalk also uses the notion of chalk reports that contains detailed information collected when chalk runs. Chalk puts this information into chalk reports rather than the chalk marks to avoid chalk marks growing and creating potential performance hots when builds jobs run.

Chalk reports are created in the local file system by default, but can be configured to be sent to any sink you define. By defining a sink for your chalk executions that generated an SBOM, you are effectively creating a chalk report repository, that will contain all the SBOMS you generate, for all the builds you run. This is effectively an SBOM registry.

For an enterprise scale production SBOM registry that will grow significantly over time, we recommend using an AWS S3 bucket rather than the local file system.

To send the SBOM contained in the chalk report to the report sink, you simply include `key.SBOM.use = true` in your chalk
reports template See the [Chalk configuration overview](./guide-config-overview.md) to learn about report templates.

To test this locally, all chalk reports containing the SBOMs from any local chalk run, to a shared local folder.

Save the following config in your current working folder.

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
    filename: "sbom_report.log"
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

Using this configuration, each time chalk runs, it will generate a chalk report containing the CycloneDX SBOM, and store it to local folder.

You can test this by typing the following in your terminal:

```bash
chalk --config-file=custom_report_sbom.con4m insert
```

## Our cloud platform

While creating a SBOM registry locally with Chalk is easy, our cloud platform makes it even easier. It is designed for enterprise deployments, and provides additional functionality including prebuilt configurations to solve common tasks, prebuilt integrations to enrich your data, a built-in query editor, an API and more.

There are both free and paid plans. You can [join the waiting list](https://crashoverride.com/join-the-waiting-list) for early access.

## Related how-tos

[Create software security supply chain compliance report requests, automatically](./howto-compliance.md)

## Background information

Software Composition Analysis or SCA is a term used to describe tools that collect and report on the software inside of a project, normally the list of third-party open-source packages. These tools have become a standard part of the appsec and DevSecOps tool chains, since the rise of software security supply chain attacks.

SBOMs or [Software Bills of Materials
(SBOMs)](https://www.cisa.gov/sbom) have gained significant traction
in the security and developer community over the past years.

There are two main formats for SBOMs. [CycloneDX](https://cyclonedx.org/) is the most widely adopted and most comprehensive specification. CycloneDX is a BOM or Bill of Materials that has sub specifications including the SBOM or Software Bill Of Materials. [SPDX](https://spdx.org) is a specification maintained by the Linux Foundation that has its roots in software license compliance.

## Related docs and references

- https://crashoverride.com/blog/the-sbom-frenzy-is-premature/
