# Create software security supply chain compliance reports automatically

### Use Chalk to fulfil pesky security supply chain compliance requests, and tick pesky compliance checkboxes fast and easy

## Summary

The US Government, several big corporations, and the Linux foundation with their [SBOM Everywhere](https://openssf.org/blog/2023/06/30/sbom-everywhere-and-the-security-tooling-working-group-providing-the-best-security-tools-for-open-source-developers/) initiative, are all driving the industry to adopt a series of requirements around
"software supply chain security", including:

- SBOMs (Software Bills of Materials) to show what 3rd party components
  are in the code.

- **Code provenance** data that allows you to tie software in the field

  to the code commit where it originated from, and the build process that created it.

- Digital signatures on the above.

This information is complex and tedious to generate, and manage.

This how-to uses Chalk™ to automate this in two steps:

1. Load our basic compliance configuration.

2. Turn on signing.

3. Build software using Docker.

As a big bonus, with no extra effort, you can be [SLSA](https://slsa.dev) [level 2](https://slsa.dev/spec/v1.0/levels) compliant, before people start officially requiring SLSA [level 1](https://slsa.dev/spec/v1.0/levels)
compliance.

## Steps

### Before you start

The easiest way to get Chalk is to download a pre-built binary from
our [release page](https://crashoverride.com/releases). It's a
self-contained binary with no dependencies to install.

### Step 1: Configure chalk to generate SBOMs, collect code provenance data, and digitally sign it

Chalk is designed so that you can easily pre-configure it for the
behavior you want, and so that you can generally just run a single binary
with no arguments, to help avoid using it wrong.

Assuming you've downloaded chalk into your working directory, you just
need to run:

```
./chalk load https://chalkdust.io/compliance_docker.c4m
```

The profile we've loaded changes two key things from the default
behavior:

1. It enables the collection of SBOMS (off by default because on large
   projects this can add a small delay to the build)

2. Specifies that any SBOM produced should be added to built
artifacts.

By default, chalk is already collecting provenance information by
examining your project's build environment, including the .git
directory and any common CI/CD environment variables.

### Step 2: Turn on signing

To setup digital signing we have built yet another easy button.

Simply run:

```
./chalk setup
```

You'll get a link to connect an account for authentication, to be able
to use Crash Override's secret service for chalk. The account is
totally free, and the account is only used to keep us from being an
easy Denial-of-Service target.

Once you have successfully connect an account, you'll get a series of
success messages.

At this point, your chalk binary will have re-written itself to
contain most of what it needs to sign, except for a `secret` that it
requests dynamically from our secret service.

### Step 3: Build software

Now that the binary is configured, you probably may want to move the
`chalk` binary to a system directory that's in your `PATH`. If you're
running Docker, we recommend adding a global alias, so that Chalk
always runs, See the [howto for docker deployment](./howto-deploy-chalk-globally-using-docker.md)

How you run chalk depends on whether you're building via `docker` or not:

- _With docker_: You "wrap" your `docker` commands by putting the
  word `chalk` in front of them. That's it.

- _Without docker_ : You simply invoke `chalk insert` in your build
  pipeline. It defaults to inserting marks into artifacts in your
  current working directory.

#### Step 3a: Docker

Your `build` operations will add a file (the _"chalk mark"_) into the
container with provenance info and other metadata, and any SBOM
generated. And, when you `push` containers to a registry, chalk will
auto-sign them, including the entire mark.

For instance, let's pick an off-the-shelf project, and treat it like
we're building part of it in a build pipeline. We'll use a sample
Docker project called `wordsmith`.

Then, let's login to a docker registry where we push our images. For
me, that'd be ghcr.io; update the repo info below to wherever you push
things, and make sure you have permission to push, then do:

```
git clone https://github.com/dockersamples/wordsmith
cd wordsmith/api
chalk docker build -t ghcr.io/viega/wordsmith:latest . --push
```

You'll see Docker run normally (It'll take a minute or so). If your
permissions are right, it will also push to the registry. Once Docker
is finished, you'll see some summary info from chalk on your command
line in JSON format, including the contents of the Dockerfile used.

If there's ever any sort of condition that chalk cannot handle (e.g.,
if you move to a future docker upgrade without updating chalk, then
use features that `chalk` doesn't understand), the program will
_always_ makes sure the original `docker` command gets run if it
doesn't successfully exit when wrapped.

#### Step 3b: When Not Using Docker

When you invoke chalk as configured, it searches your working
directory for artifacts, collects environmental data, and then injects
a "chalk mark" into any artifacts it finds.

Chalk, therefore, should run after any builds are done, but it should
still have access to the repo you're building from. If you copy out
artifacts, then, instead of letting chalk use the working directory as
the build context, you can supply a list of locations on the command
line.

The chalk mark is always stored as a JSON blob, but how it's embedded
into an artifact varies based on the type of file. For example, with
ELF executables as produced by C, C++, Go, Rust, etc, chalk creates a
new "section" in the binary; it doesn't change what your program does
in any way.

For scripting content, it just adds a comment to the bottom of the
file. JAR files (and other artifacts based on the ZIP format) are
handled similarly to container images, and there are marking
approaches for a few other formats, with more to come.

### What to tell other people

Any `chalk` executable can extract the chalk mark, and verify
everything.  While we configured our binary to add marks by default, the
`extract` command will pull them out and verify them.

Chalk extract will report on anything it finds under your current
working directory, And so will extract the mark from any artifacts you
chalked that weren't containerized. But if you built the example
container, we can extract from the example container easily (or any
other container you have a local copy of) by just by providing a
reference to it:

```
chalk extract ghcr.io/viega/wordsmith:latest
```

Either will pull all the metadata chalk saved during the first
operation, and log it, showing only a short summary report to your
console. If the signature validation fails, then you'll get an obvious
error! If anyone tampers with a mark, or changes a file after the
chalking, it is clear in the output.

## Our cloud platform

While creating compliance reports with chalk is easy, our cloud
platform makes it even easier. Not only can you collect software
compliance information automatically, you can easily share it with
anyone who needs it.

There are both free and paid plans. You can [join the waiting
list](https://crashoverride.com/join-the-waiting-list) for early
access.

### Background information

Below is a bit more information on supply chain security and the
emerging compliance environment around it, as well as some details on
how chalk addresses some of these things under the hood.

#### Supply chain security and the US government

In May 2021, President Biden issued [Executive Order 14028](https://www.nist.gov/itl/executive-order-14028-improving-nations-cybersecurity#:~:text=Assignments%20%7C%20Latest%20Updates-,Overview,of%20the%20software%20supply%20chain.) to enhance cyber security and the integrity of the software supply chain. NIST or the National Institute for Standards published [Security Measures for “EO-Critical Software” Use Under Executive Order (EO)](https://www.nist.gov/system/files/documents/2021/07/09/Critical%20Software%20Use%20Security%20Measures%20Guidance.pdf) on July 2021 in response.

#### SBOMs

Many organizations are already demanding SBOMs (software
bills-of-material) to understand open-source components in what they
consume, ideally so that they can use to monitor downstream
vulnerabilities in the software they use, even though the industry
really isn't good at operationalising anything around this.

Unfortunately, there are two competing file formats for SBOM, SPDX and
CycloneDX. And, there are many, many different SBOM-related tools,
many of which only work in a subset of environments (e.g., tools that
only produce SBOMs for specific package environments like npm). This
complexity doesn't really make anyone's lives easier outside the
security community.

Chalk has a pluggable ability to run third party tools. For SBOMs,
currently, the only tool pre-configured is the open source Syft (which
again, automatically be installed when needed, if it isn't found
locally).

We've found it to be a good general-purpose tool, but we may add more
out-of-the-box SBOM integrations if contributed by the community; the
general tool facility does allow you to generate multiple SBOMs for
the same project, so we will likely provide multiple tools by default
when turned on.

#### Code provenance

The drive to understand the provenance in software builds is highest
from the government and from large F500 companies, who have found
that, historically, many of their biggest security incidents came
because of a downstream vendor's code, and have noticed that attackers
in those environments often take advantage of access to build
environments to subtly trojan software.

Therefore, very mature security programs in places with an acute
awareness of wisk, very much want the ability to monitor the integrity
of builds throughout their supply chain. And, baring that, they'd are
looking to get as much information as possible, or at least some
assurances of build practices.

In spending a lot of time watching real people work, we have found
most companies not in the F500 have much higher priority problems than
improving visibility into their supply chain.

HOWEVER! We have noticed many companies have an INTERNAL provenance
problem, where they lose significant time because they don't have a
good way to handle the same kinds of things internally just with their
own code. Operational teams often need to spend time "asking around"
to answer questions like, "There's a service that is suddenly running
up our AWS bill. Who owns it?" And then it can take more time for
developers to extract info through those ops people about what version
was deployed and what else was going on in the environment.

Chalk was built originally for those internal use cases, to get people
the data they need to be able to automate the work they do to graph
out the relationships in their software. However, the exact same
approach turns out to give other companies extactly what they're
looking for.

#### Digital signatures

For companies that care about provenance data, they would definitely
prefer some level of assurance that they're looking at the RIGHT data,
untampered with by an attacker. No deletions, adds or changes from the
time it was signed.

Traditional digital signatures for software aren't that interesting
for companies with these problems. They can pretty easily make sure
they are using the right software via direct relationships with the
vendor, all without signatures.

It's the metadata they're looking for on software components and the
build process where signatures become interesting. If there's no
signature, there's no bar for an attacker to just make up whatever
information they want on the build process, making it easy to cover
their tracks.

Signing provides a bar, for sure. But, to keep things scalable and
affordable, few people are going to put a human in the loop to review
and sign everything. And even if they do, the attacker could still get
those people to sign off on changes the attacker himself made.

So while automatic signing is susceptible to the attacker taking over
the signing infrastructure, it's more work that does raise the bar
significantly.

This community has put together a few standards on the logistics of
signing, under the umbrella of the "Sigstore" project at the Linux
foundation. Chalk uses their "In-Toto" standard internally.

The signature validation works automatically because we add the PUBLIC
signing key to the chalk mark. For extra assurance, some users might
want to compare the embedded public key against a copy of it you
provide out-of-band.

That's why, when you ran `chalk setup`, Chalk output to disk two files:

1. _chalk.pub_ The public key you can give people out of band.

2 _chalk.pri_ The ENCRYPTED private key (just in case you want to load
   the same key into a future chalk binary).

When you run `chalk setup`, we generate a keypair for you, and encrypt
the private key. The key is encrypted with a randomly generated
password (128 random bits encoded), and that password is escrowed with
our secret service. The chalk binary receives a token that it can use
to recover the secret when it needs to sign.

The token and the private key are embedded into the chalk binary, so
you won't have to keep a separate data file around to keep things
working. Your chalk binary can move from machine to machine no
problem.

Basically chalk adds a `chalk mark` to itself, similarly to how it
will add one to containers. Chalk marks are essentially just JSON data
blobs added to software (or images containing software) in a way that
is totally benign.

Currently when signing, we're using the aforementioned In-Toto
standard. We are also leveraging the open source `cosign` tool, which
is also part of the Linux Foundation's SigStore project. We will
probably eventually incorporate the functionality directly into Chalk,
but for now, when chalk cannot find cosign and you need it to sign or
validate, it will try to install the official binary, first via `go
get`, and, if that fails, via direct download.

#### SLSA

Part of the security industry have been hard at work on putting
together a standardized framework to capture all of the above
requirements, [SLSA](https://slsa.dev) ("Supply-chain Levels for Software Artifacts").

The draft version was far-reaching and complicated, which clearly was
going to hinder adoption. Plus, due to much better marketing, security
teams started focusing on SBOMs. So SLSA has simplified dramatically.

With the new "1.0" standard, the important parts about SLSA basically
contain a few high-level asks. Nonetheless, even those high-level asks
can be very difficult for people to address, which the developers of
the framework did recognize. Thankfully, they made the wise decision
to frame their asks in terms of "Security Levels":

- _Level 0_ means you're not doing anything to address provenance
  risks.

- _Level 1_ compliance basically means that you'll provide people
  provenance information about how you built the package. This now no
  longer explicitly asks for SBOMs, but the need for component
  information is implicit, since they're asking for details on the
  build process.

- _Level 2_ compliance primarily adds the requirement for the
  provenance information to be output at the end of your build
  process along with a digital signature of that information, which
  can absolutely be fully automated.

- _Level 3_ compliance requires more hardening still; it's currently
  more ill-defined, but the gist is that they are hoping people will
  invest in demonstrating their build processes are 'tamper-evident'.

That goes back to our discussion on automated digital signatures
above. The SLSA designers realize that, in most domains, asking for
Level 3 compliance is unreasonable, at least at the moment.

So they're often not likely to be able to detect tampering with
software during the build process (which is the real goal of Level 3),
but they feel like being able to detect tampering AFTER the build
process should be a short-term realistic goal, which automated signing
does well enough (Level 2).

But they do clearly recognize that there hasn't been good tooling
around any of this yet, and that in many places, they'll be lucky to
get the basic info without the extra work of signatures.

But, in good news for everyone, chalk gives you everything you need to
_easily_ meet the Level 2 requirement for signed-provenance generated
by a hosted build platform.

#### A List of well known software supply chain attacks

##### Lodash

Lodash is a popular NPM library that was, in March 2021 found to have a prototype pollution vulnerability. It was the most depended on package in NPM meaning almost all applications built in Node.js were affected.

[Prototype Pollution in lodash](https://github.com/advisories/GHSA-p6mc-m468-83gw) - Github

##### Netbeans

Ih 2020 it was reported that a tool called the Octopus scanner was searching Github and injecting malware into projects that were using the popular Java development framework Netbeans and then serving up malware to all applications built from those code repos.

[https://duo.com/decipher/malware-infects-netbeans-projects-in-software-supply-chain-attack](https://duo.com/decipher/malware-infects-netbeans-projects-in-software-supply-chain-attack) - Duo Research Labs

##### Log4j and Log4Shell

Log4J is a popular logging library for the Java programming language. In late 2021 a vulnerability was discovered that allowed hackers remote access to applications using it. Several vulnerabilities followed the initial disclosure and attackers created exploits that were used in the wild. Variants included names like Log4Shell and Log4Text.

[Apache Log4j Vulnerability Guidance](https://www.cisa.gov/news-events/news/apache-log4j-vulnerability-guidance) - CISA, Critical Infrastructure Security Agency

##### SolarWinds

The SolarWinds attack used an IT monitoring system, Orion, which which had over 30,000 organizations including Cisco, Deloitte, Intel, Microsoft, FireEye, and US government departments, including the Department of Homeland Security. The attackers created a backdoor that was delivered via a software update.

[The Untold Story of the Boldest Supply-Chain Hack Ever](https://www.wired.com/story/the-untold-story-of-solarwinds-the-boldest-supply-chain-hack-ever/) - Wired Magazine