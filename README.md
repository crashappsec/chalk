![Chalk Logo](https://chalkproject.io/logo.svg)

![tests](https://github.com/crashappsec/chalk/actions/workflows/tests.yml/badge.svg?branch=main&event=push)

## Software provenance and attestation made easy

Chalk gives you a cryptographically verifiable chain of custody from build through production, with minimal configuration, and no changes to how your software is run.

### Overview

Chalk seamlessly handles provenance and attestation for production software, collecting detailed environmental info about software being built or run, cradle to grave.

Correlating all that provenance information is the hard part. We handle this by adding a tamperproof identifier into all artifacts (the _chalk mark_). The identifier is inert JSON; we can auto-insert into a containers, executables, JARs (and other ZIP-based archives), shell scripts and source for nearly all interpreted languages. Chalking never impacts execution.

Automatically chalking software during the build process makes it trivial to do two things that can be a large source of enterprise pain:

1. Easily determine the integrity of individual artifacts.
2. Automatically correlate information collected about those artifacts at any point.

When collecting attestation information, we handle a lot of plumbing transparently. For instance, we automatically apply Docker’s SBOM tooling when available, but will fall back to using a stand-alone OSS tool (Syft) when not available. Similarly, we collect cloud-specific metadata, probing for common cloud metadata interfaces.

If you set up build signature mode, the build attestation will be signed using a Sigstore _[in-toto_ attestation](https://docs.sigstore.dev/cosign/verifying/attestation/), and automatically pushed to the container registry when your image is pushed.

In a build environment, Chalk can be set up to “wrap” container entry points and lambdas, changing them to fire off a background process to collect provenance information at startup.

All collected data can automatically be written to files, REST APIs, S3 buckets, or even into the embedded artifact metadata.

Chalk is already used at scale in enterprises of varying sizes, including multiple Fortune 50 companies.

## Use Cases

- **Incident response.** When there’s a production incident, you will already have all the key information authoritatively connected, such as the branch, commit, package changes, committers, and container base.
- **Tech stack visibility.** Keep track of software as it changes, and have answers about what’s actually true right now. For supply chain poisoning, you’ll have all the data to be able to automatically find any affected production systems.
- **Compliance.** SLSA Level 2 compliance is trivial; you don’t need to select a patchwork of tools, nor do you have to worry about how to map artifacts to attestations (the needed identifying info is embedded directly into the artifact).
- **Audit.** Chalk’s continuous attestation model makes it easy to validate whether appropriate controls were applied.

## Design Goals

- **Ease of use.** Our internal mantra is “give engineers value, not work.” It’s straightforward to integrate with your existing CI/CD, and then operates transparently as your build and deploy software.
- **Minimal overhead.** Chalk collects only “cheap” data during builds and deployments, and is deployed as a statically linked executable.
- **Safety**. Chalk “fails open”; if a build fails, Chalk reruns the original build without itself in the path. Your pipeline should never break due to Chalk. Additionally, Chalk’s written in a type-safe language with full bounds checking.
- **Flexibility**. Chalk collects a lot of cheaply available data when it runs. It gives you control over what data goes where, and supports custom data collection.

## Quick start
1. Download a pre-compiled executable from our release page, or:
```shell
   VERSION=$(curl -fsSL https://dl.crashoverride.run/chalk/current-version.txt)
   curl -Lo chalk https://dl.crashoverride.run/chalk/chalk-$VERSION-$(uname -s)-$(uname -m)
   chmod +x chalk
   ```
2. (optional) Set up full Sigstore signing
```shell
./chalk setup
```
```shell
 ------------------------------------------
 CHALK_PASSWORD=p66oICCD8ME7xdjcClWEQg==
 ------------------------------------------
 Write this down. In future chalk commands, you will need
 to provide it via CHALK_PASSWORD environment variable.
```
The setup process generates a key pair, and embeds them in your Chalk binary. The embedded private key is encrypted, so you will need to provide the secret via the `CHALK_PASSWORD` environment variable once you've done this.

3. Add chalk marks!
For chalking executables and shell scripts, you can just use the `chalk insert` command:
```shell
echo '#include<stdio.h>
int main() {
  printf("Hello world!\n");
  return 0;
}' > hello.c
$ gcc -o hello hello.c
CHALK_PASSWORD=p66oICCD8ME7xdjcClWEQg== ./chalk insert ./hello 2>/dev/null | jq '.[]|._CHALKS[]|.'
```
Remember here to use _your_ generated password if signing. After insertion, you should see something like:

```json
{
 "CHALK_ID": "6RW6AD-1SCM-T3CE-3561JP",
 "PRE_CHALK_HASH": "2796945bbcbd5ce33d1833d6b49569e9d4035322aabf6f772d2e49be65d327c2",
 "PATH_WHEN_CHALKED": "/home/admin/hello/hello",
 "ARTIFACT_TYPE": "ELF",
 "CHALK_VERSION": "1.0.0",
 "METADATA_ID": "RQCGKG-M8CK-FG5Z-2YHSSW",
 "SIGNATURE": "MEUCIHD8ev5tijJ/m8U7c0U5pXNpE/OYTr2sfGEv6BqNja9lAiEA3eMTPU0Pj78NNcinM83wEZ46tqmHlol9yvCoQSH25kc=",
 "_VIRTUAL": false,
 "_CURRENT_HASH": "2796945bbcbd5ce33d1833d6b49569e9d4035322aabf6f772d2e49be65d327c2"
}
```

Without the filtering, you'll also see all the metadata collected about the host node.

## Resources

- Our [getting started guide](https://chalkproject.io/docs/getting-started/) covers how to chalk mark your own binaries and Docker images.
- See how to hook Chalk up to your build environment with [our CI/CD guide](https://chalkproject.io/docs/integration/ci-cd/).
- You can learn more about our [automatic tracking of program execution](https://chalkproject.io/docs/use-cases/exec/).
- [Set up Sigstore](https://chalkproject.io/docs/integration/attestation/) for more detail on adding full provenance attestations to container manifests.

If you’re not familiar with the in-toto format, there is an overview [here](https://docs.sigstore.dev/cosign/verifying/attestation/).

## Bugs + Feature Requests

Please create a [GitHub issue](https://github.com/crashappsec/chalk/issues) for any bugs or feature requests.

## Contributions

Chalk is maintained by [Crash Override](https://crashoverride.com/). Outside contributions are welcome. The CLA process is [here](https://crashoverride.com/docs/other/contributing).

## License

Chalk is licensed under the GPL version 3 license.
