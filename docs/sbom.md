# Create software security supply chain compliance reports automatically

### Use Chalk to fulfill pesky security supply chain compliance requests, and tick pesky compliance checkboxes fast and easy

## Summary

The US Government, several large corporations, and the Linux foundation with their
[SBOM Everywhere](https://openssf.org/blog/2023/06/30/sbom-everywhere-and-the-security-tooling-working-group-providing-the-best-security-tools-for-open-source-developers/)
initiative are all driving the industry to adopt a series of requirements
around "software supply chain security," including:

- SBOMs (Software Bills of Materials) to show what 3rd party components are in
  the code.

- **Code provenance** data that allows you to tie software in the field to the
  code commit where it originated from and the build process that created it.

- Digital signatures on the above.

This information is complex and tedious to generate and manage, but we can
easily automate this with Chalk™.

This how-to uses Chalk to automate supply chain compliance in three steps:

1. Configure Chalk to generate SBOMs, provenance data, and digital signatures.

1. Build software using Docker with compliance data built-in.

As a big bonus, with no extra effort, you can be
[SLSA](https://slsa.dev) [level 2](https://slsa.dev/spec/v1.0/levels)
compliant before people start officially requiring SLSA
[level 1](https://slsa.dev/spec/v1.0/levels) compliance.

## Steps

### Before you start

You should have a working installation of Chalk. If not, see
[Installation Guide](./install.md).

### Step 1: Configure Chalk to generate SBOMs, collect code provenance data

Chalk is designed so that you can easily pre-configure it for the behavior you
want, and then run a single binary with no arguments. It also allows you to
load and tweak configurations without having to manually edit a configuration
file.

Assuming you've downloaded Chalk into your working directory, you can load the
SBOM configuration file by running:

```bash
$ chalk load https://chalkdust.io/run_sbom.c4m
$ chalk load https://chalkdust.io/embed_sboms.c4m
```

By default, Chalk is already collecting provenance information by examining
your project's build environment, including the `.git` directory and any common
CI/CD environment variables. Loading above components will add two
key things to the default behavior:

- `run_sbom.c4m` - It will enable the collection of SBOMs (off by default
  because on large projects, this can add a small delay to the build)
- `embed_sboms.c4m` - For simplicity it will embed SBOM findings into
  the chalk mark which is going to be embedded into the artifact. Note that
  SBOM findings can be large and can increase the artifact size significantly.
  If that is a concern, we recommend shipping SBOM data to and external sink
  such as either S3 or an API.

You can check that the configuration has been loaded by running:

```bash
$ chalk dump
```

#### Step 2: Turn on digital signing

We still need to turn on digital signing, which is off by default. We will need
to generate signing keys. See [Attestation](./attestation.md) how to do that.
Here is the quick summary.

First you will need to generate a signing key for chalk:

```bash
$ chalk setup
```

Above will create `chalk.key` and `chalk.pub` as well as show value for .
`CHALK_PASSWORD` For simplicity we can export that as environment variable for.
future use In CI/CD environments we would recommend to store it as a secret .

```bash
export CHALK_PASSWORD=<value from above>
```

At this point, your Chalk binary will have re-written itself to contain most of
what it needs to sign, except for a `secret` that it reads from an environment
variable `CHALK_PASSWORD`.

### Step 3: Build software

Now that the binary is configured, you may want to move the `chalk` binary to a
system directory that's in your `PATH`.

How you run Chalk depends on whether you're building via `docker` or not:

- _With docker_: "Wrap" your `docker` commands by putting the word `chalk` in
  front of them, ex: `chalk docker build [...]`

- _Without docker_ : Invoke `chalk insert` in your build pipeline. It defaults
  to inserting marks into artifacts in the current working directory.

#### Step 3a: Docker

With docker wrapping enabled, your `build` operations will add a file (the
_"chalk mark"_) into the container, which will contain the provenance info
and other metadata, and any SBOMs generated. When you `push` containers to
a registry, Chalk will auto-sign the containers (including the entire chalk
mark) via `cosign`.

For instance, let's pick an off-the-shelf project and treat it like we're
building part of it in a build pipeline. We'll use a sample Docker project
called `wordsmith`.

We'll also need access to a Docker registry that can push our images. If you
have access to a registry where you have push permissions, ensure that you have
logged into the registry before continuing, and use that registry name in the
following examples.

If you don't have access or appropriate permissions to any registry,
you can set up a local registry by following the instructions
[here](https://www.docker.com/blog/how-to-use-your-own-registry-2/). In the
following examples we will be using a local registry at `localhost:5000`.

To clone and build the `wordsmith` project, run:

```bash
$ git clone https://github.com/dockersamples/wordsmith
$ cd wordsmith/api
$ chalk docker build -t localhost:5000/wordsmith:latest . --push
```

You'll see Docker run normally (it'll take a minute or so). If your permissions
are correct, it will also push to the registry. Once Docker is finished, you'll
see some summary info from Chalk on your command line in JSON format, including
the contents of the Dockerfile used.

The terminal report (displayed after the Docker output) should look like this:

```json
[
  {
    "_OPERATION": "build",
    "_CHALKS": [
      {
        "CHALK_ID": "GWWH8K-W4TW-GEVV-18JMKT",
        "METADATA_ID": "DZDT7N-4RP1-KGXM-7K27WY",
        "DOCKERFILE_PATH_WITHIN_VCTL": "api/Dockerfile",
        "DOCKER_BASE_IMAGE": "amazoncorretto:20@sha256:fa2019e772a5a5d21cb9b44165a919d74ae189405093caf89322a69f0aef0713",
        "ORIGIN_URI": "https://github.com/dockersamples/wordsmith",
        "COMMIT_ID": "23c61bba9a4c163e5011a7072cbdfd07128acec0",
        "COMMIT_SIGNED": true,
        "BRANCH": "main",
        "AUTHOR": "Bret Fisher <bret@bretfisher.com>",
        "COMMITTER": "GitHub <noreply@github.com>",
        "DATE_AUTHORED": "2024-02-24T14:57:25.000-05:00",
        "DATE_COMMITTED": "2024-02-24T14:57:25.000-05:00",
    [...]
```

To check that the container pushed has been successfully Chalked, we can run:

```bash
$ chalk extract localhost:5000/wordsmith:latest
```

The terminal report for the extract operation should look like this:

```json
[
  {
    "_OPERATION": "extract",
    "_DATETIME": "2023-10-30T12:36:32.760-04:00",
    "_CHALKS": [
      {
        "_OP_ARTIFACT_TYPE": "Docker Image",
        "_REPO_DIGESTS": {
          "localhost:5000": {
            "wordsmith": [
              "4a12fd9ca65dd21bf6a9416117ce94b986131787dfbcd3b1ead258170be16e69"
            ]
          }
        },
        "_CURRENT_HASH": "08b70fda0986feecf73e8c86b1156c5470abd23384268256c5fd88deed7f3aa3",
        "ORIGIN_URI": "https://github.com/dockersamples/wordsmith",
        "CHALK_ID": "GWWH8K-W4TW-GEVV-18JMKT",
        "METADATA_ID": "DZDT7N-4RP1-KGXM-7K27WY",
        [...]
      }
    ],
    [...]
```

In particular, note that the `METADATA_ID` for the build and extract operations
are the same -- this ID is how we will track the container.

Checking the raw Chalk mark, we can see the SBOM data has been embedded:

```json
$ docker run -it --rm --entrypoint=cat localhost:5000/wordsmith:latest /chalk.json | jq
{
  "CHALK_ID": "GWWH8K-W4TW-GEVV-18JMKT",
  "METADATA_ID": "DZDT7N-4RP1-KGXM-7K27WY",
  [...]
  "SBOM": {
    "syft": {
      "$schema": "http://cyclonedx.org/schema/bom-1.4.schema.json",
      "bomFormat": "CycloneDX",
      "specVersion": "1.4",
      "serialNumber": "urn:uuid:bbcecc86-342e-4550-a6ce-6f7ac359d8da",
  [...]
```

If the image we have built here is run as a container, the Chalk mark will be
included in a `/chalk.json` file in the root of the container file system.

If there's ever any condition that Chalk cannot handle (e.g., if you move to a
future Docker upgrade without updating Chalk, then use features that `chalk`
doesn't understand), Chalk will _always_ make sure the original `docker`
command gets run if the wrapped command does not exit successfully. This
ensures that adding Chalk to a build pipeline will not break any existing
workflows.

#### Step 3b: When Not Using Docker

When you invoke Chalk as configured, it searches your working directory for
artifacts, collects environmental data, and then injects a "chalk mark" into
any artifacts it finds.

Chalk, therefore, should run after any builds are done, but it should still
have access to the repository you're building from. If you copy out artifacts,
then instead of letting Chalk use the working directory as the build context,
you can supply a list of locations on the command line.

For example, let's make a copy of the `ls` binary into `tmp` called `ls-test`
and Chalk it:

```bash
$ cp $(which ls) /tmp/ls-test
$ chalk insert /tmp/ls-test
```

This will insert a Chalk mark into the `ls-test` binary, with environmental
data (and git data, if available) taken from the `/tmp` directory, instead of
the current working directory. You should see a terminal summary report like
this:

```json
[
  {
    "_OPERATION": "insert",
    "_DATETIME": "2023-10-30T17:17:55.287-04:00",
    "_CHALKS": [
      {
        "PRE_CHALK_HASH": "8696974df4fc39af88ee23e307139afc533064f976da82172de823c3ad66f444",
        "CHALK_ID": "CHJKGD-K569-K30D-SR60R3",
        "PATH_WHEN_CHALKED": "/tmp/ls-test",
        "ARTIFACT_TYPE": "ELF",
        "CHALK_VERSION": "0.2.2",
        "METADATA_ID": "2NQ40N-7T08-05MJ-30EXKZ",
        "SIGNATURE": "MEYCIQCjXwUttf2Lpx7PYx5QsFSCXqrpY4+1Q6vUWWz7ZEMl0QIhAN2whDM4WgzzrNcSVwWh7mfTcVtjgnumyxAzXkWbMp3J",
        "_VIRTUAL": false,
        "_CURRENT_HASH": "8696974df4fc39af88ee23e307139afc533064f976da82172de823c3ad66f444",
        [...]
      }
    ],
    [...]
```

To check that the Chalk mark has been correctly added, we can run:

```bash
$ chalk extract /tmp/ls-test
[
  {
    "_OPERATION": "extract",
    "_DATETIME": "2023-10-30T17:19:20.628-04:00",
    "_CHALKS": [
      {
        "CHALK_ID": "CHJKGD-K569-K30D-SR60R3",
        "CHALK_VERSION": "0.2.2",
        "ARTIFACT_TYPE": "ELF",
        "METADATA_ID": "2NQ40N-7T08-05MJ-30EXKZ",
        "_OP_ARTIFACT_PATH": "/tmp/ls-test",
        "_OP_ARTIFACT_TYPE": "ELF",
        "_CURRENT_HASH": "7cf6bd9e964e19e06f77fff30b8a088fbde7ccbfc94b9500c09772e175613def",
        [...]
      }
    ],
    [...]
```

The Chalk mark is always stored as a JSON blob, but how it's embedded into an
artifact varies based on the type of file.

For example, with ELF executables as produced by C, C++, Go, Rust, etc, Chalk
creates a new "section" in the binary; it doesn't change what your program
does in any way. For scripting content such as `.py` files, Chalk will add a
comment to the bottom of the file containing the Chalk mark. JAR files (and
other artifacts based on the ZIP format) are handled similarly to container
images.

There are marking approaches for a few other formats, with more to come.

### Chalk extraction and validation

The signing and provenance information will be embedded in non-executable data
within your artifact. Any `chalk` executable can then extract the Chalk mark
and verify everything by using the `extract` command.

By default, `chalk extract` will report on anything it finds under your current
working directory and will extract the Chalk marks from any artifacts that it
finds that weren't containerized. To extract Chalk marks from all images, we
can run `chalk extract images`; similarly, `chalk extract containers` will
extract Chalk marks from all running containers. (Warning: running extract
on all images or containers will take a long time, and is not generally
recommended.)

To extract on a specific artifact, you can pass a list of locations (or
image/container names) into the `extract` command as demonstrated above.

The `extract` operation will pull all the metadata that Chalk saved during the
`insert` or `docker build` operations and log it, showing only a short summary
report to your console.

If the signature validation fails, then you'll get an obvious error! If anyone
tampers with a mark or changes a file after the Chalking, it is clear in the
output.

### Background information

Below is a bit more information on supply chain security and the emerging
compliance environment around it, as well as some details on how Chalk
addresses some of these things under the hood.

#### Supply chain security and the US government

In May 2021, President Biden issued
[Executive Order 14028](https://www.nist.gov/itl/executive-order-14028-improving-nations-cybersecurity#:~:text=Assignments%20%7C%20Latest%20Updates-,Overview,of%20the%20software%20supply%20chain.)
to enhance cyber security and the integrity of the software supply chain. NIST
(the National Institute of Standards and Technology) published
[Security Measures for “EO-Critical Software” Use Under Executive Order (EO)](https://www.nist.gov/system/files/documents/2021/07/09/Critical%20Software%20Use%20Security%20Measures%20Guidance.pdf)
on July 2021 in response.

#### SBOMs

Many organizations are already demanding SBOMs (software bills-of-material) to
understand open-source components in what they consume, ideally so that they
can use it to monitor downstream vulnerabilities in the software they use, even
though the industry isn't good at operationalizing anything around this.

Unfortunately, there are two competing file formats for SBOM, SPDX and
CycloneDX. Furthermore, there are many, many different SBOM-related tools, many
of which only work in a subset of environments (e.g., tools that only produce
SBOMs for specific package environments like npm). This complexity doesn't make
anyone's lives easier outside the security community.

Chalk has a pluggable ability to run third-party tools. For SBOMs, the only
tool currently pre-configured is the open-source Syft (which will automatically
be installed when needed if it isn't found locally).

We've found it to be a good general-purpose tool, but we may add more
out-of-the-box SBOM integrations if contributed by the community; the general
tool facility does allow you to generate multiple SBOMs for the same project,
so we will likely provide multiple tools by default when turned on.

#### Code provenance

The desire to understand provenance in software builds is driven mostly by the
government and large Fortune 500 companies that have found that, historically,
many of their worst security incidents came because of a downstream vendor's
code, and have noticed that attackers in those environments often take
advantage of access to build environments to subtly trojan software.

Therefore, mature security programs in places with an acute awareness of risk
very much want the ability to monitor the integrity of builds throughout their
supply chain. Barring that, they are looking to get as much information as
possible, or at least some assurances of build practices.

In spending a great deal of time watching real people work, we have found that
most companies not in the Fortune 500 have much higher-priority problems than
improving visibility into their supply chain.

However, we have noticed many companies have an _INTERNAL_ provenance problem,
where they lose significant time because they don't have a good way to handle
the visibility of their own code. Operational teams often need to spend
time asking around to answer questions like, "There's a service that is
suddenly running up our AWS bill. Who owns it?" Then, it can take more time for
developers to extract info from the ops team about what version was deployed
and what else was going on in the environment.

Chalk was originally built for those internal use cases, getting people the
data they need to automate work that graphs out the relationships in their
software. However, our approach happens to give other companies exactly what
they're looking for.

#### Digital signatures

For companies that care about provenance data, they would definitely prefer
some level of assurance that they're looking at the _RIGHT_ data, untampered
with by an attacker -- no deletions, additions, or changes from the time it was
signed.

Traditional digital signatures for software aren't particularly helpful for
companies with these problems. They can easily ensure they are using the right
software via direct relationships with the vendor, all without signatures.

It's the metadata they're looking for on software components and the build
process where signatures gain utility. If there's no signature, there's no bar
for an attacker to simply forge information on the build process, making it
easy to cover their tracks.

Signing provides a bar, for sure. But to keep things scalable and affordable,
few developers would put a human in the loop to review and sign everything.
And even if they do, the attacker could still get those people to sign off on
changes the attacker made himself.

So, while automatic signing is susceptible to the attacker taking over the
signing infrastructure, such an attack takes much more work, raising the bar
significantly.

This community has put together a few standards on the logistics of signing
under the umbrella of the "Sigstore" project at the Linux Foundation. Chalk
uses their "In-Toto" standard internally.

The signature validation works automatically by adding the PUBLIC signing key
to the Chalk mark. For extra assurance, some users might want to compare the
embedded public key against a copy you provide out-of-band.

That's why, when you ran `chalk setup`, Chalk output two files to disk:

1. _chalk.pub_ The public key you can give people out of band.
2. _chalk.key_ The ENCRYPTED private key (just in case you want to load
   the same key into a future Chalk binary).

When you run `chalk setup` we generate a keypair for you and encrypt the
private key. The key is encrypted with a randomly generated password (128
random bits encoded) - the `CHALK_PASSWORD` value.

Both public and private keys are embedded into the Chalk binary, so
you won't have to keep a separate data file around to keep things
working. Your Chalk binary can move from machine to machine with no
problems. Only `CHALK_PASSWORD` will need to be provided.

Basically, Chalk adds a `chalk mark` to itself, similar to how it will add one
to containers or other artifacts. Chalk marks are, essentially, JSON data blobs
added to software (or images containing software) in a way that is totally
benign.

Currently, when signing, we're using the aforementioned In-Toto standard. We
are also leveraging the open-source `cosign` tool, which is also part of the
Linux Foundation's SigStore project. We will probably eventually incorporate
the functionality directly into Chalk, but for now, when Chalk cannot find
cosign and you need it to sign or validate, it will try to install the official
binary: first via `go get`, and, if that fails, via direct download.

#### SLSA

Part of the security industry has been hard at work putting together
a standardized framework to capture all of the above requirements,
[SLSA](https://slsa.dev) ("Supply-chain Levels for Software Artifacts").

The draft version was far-reaching and complicated, which would have hindered
adoption. Plus, due to much better marketing, security teams started focusing
on SBOMs. So, SLSA has simplified dramatically.

With the new "1.0" standard, the important parts of SLSA contain a few
high-level asks. Nonetheless, even those high-level asks can be very difficult
for people to address, which the framework developers did recognize.
Thankfully, they made the wise decision to frame their asks in terms of
"Security Levels":

- _Level 0_ means you're not doing anything to address provenance risks.

- _Level 1_ compliance means that you'll provide people provenance information
  about how you built the package. This now no longer explicitly asks for
  SBOMs, but the need for component information is implicit because they're
  asking for details on the build process.

- _Level 2_ compliance primarily adds the requirement for the provenance
  information to be output at the end of your build process along with a
  digital signature of that information, which can be fully automated.

- _Level 3_ compliance requires more hardening still; it's currently more
  ill-defined, but the gist is that they are hoping people will invest in
  demonstrating that their build processes are 'tamper-evident'.

That goes back to our discussion on automated digital signatures above. The
SLSA designers realize that, in most domains, asking for Level 3 compliance is
unreasonable, at least at the moment.

So they're often not likely to be able to detect tampering with software during
the build process (which is the real goal of Level 3), but they feel like
being able to detect tampering AFTER the build process should be a short-term
realistic goal, which automated signing does well enough (Level 2).

But they do recognize that there hasn't been good tooling around any of this
yet, and that in many places, they'll be lucky to get the basic info without
the extra work of signatures.

But, in good news for everyone, Chalk gives you everything you need to _easily_
meet the Level 2 requirement for signed-provenance generated by a hosted build
platform.

#### A List of well-known software supply chain attacks

##### Lodash

Lodash is a popular NPM library that was, in March 2021, found to have a
prototype pollution vulnerability. It was the most depended on package in NPM
meaning almost all applications built in Node.js were affected.

[Prototype Pollution in lodash](https://github.com/advisories/GHSA-p6mc-m468-83gw) - GitHub

##### Netbeans

In 2020, it was reported that a tool called the Octopus scanner was searching
GitHub and injecting malware into projects that were using the popular Java
development framework Netbeans and then serving up malware to all applications
built from those code repos.

[https://duo.com/decipher/malware-infects-netbeans-projects-in-software-supply-chain-attack](https://duo.com/decipher/malware-infects-netbeans-projects-in-software-supply-chain-attack) - Duo Research Labs

##### Log4j and Log4Shell

Log4J is a popular logging library for the Java programming language. In late
2021, a vulnerability was discovered that allowed hackers remote access to
applications using it. Several vulnerabilities followed the initial disclosure,
and attackers created exploits that were used in the wild. Variants included
names like Log4Shell and Log4Text.

[Apache Log4j Vulnerability Guidance](https://www.cisa.gov/news-events/news/apache-log4j-vulnerability-guidance) - CISA, Critical Infrastructure Security Agency

##### SolarWinds

The SolarWinds attack used an IT monitoring system, Orion, which had over
30,000 organizations, including Cisco, Deloitte, Intel, Microsoft, FireEye, and
US government departments, including the Department of Homeland Security. The
attackers created a backdoor that was delivered via a software update.

[The Untold Story of the Boldest Supply-Chain Hack Ever](https://www.wired.com/story/the-untold-story-of-solarwinds-the-boldest-supply-chain-hack-ever/) - Wired Magazine
