# How to handle "supply chain" requests with minimal effort

## Tick those boxes FAST

## Summary

The US Government, several big corporations, and the Linux foundation
are all driving the industry to adopt a series of requirements around
"supply chain" security, including:

- SBOMs (Software Bills of Material) to show what 3rd party components
  are in the code.

- "Code provenance" -- data allowing you to tie software in the field
  to the commit it came from, and the build process that created it.

- Digital signatures on the above.

With almost no effort, you can be Level 2 compliant with the emerging
SLSA framework well before people start officially requiring Level 1
compliance!

## When to use this

If you're getting any asks from customers around supply-chain security
at all.

## Solution

Have Chalk automatically collect SBOMs and provenance data, then sign
it, as an automatic step in your build process.

Chalk will add a small data blob (the **chalk mark**) to your
artifacts to make the information easy to find.

### Alernative solutions

Right now, lots of people are scrambling to understand what they are
being asked to do, researching a vast maze of different tech-focused tools.

They're then left figuring out how to operationalize any of it
effectively, and make the data available to the people who need it.

## Prerequisites

This recipe does assume access to your build system, and assumes your
project successfully builds.

It also assumes you have Chalk installed.

The easiest way to get Chalk is to download a pre-built binary from
our [release page](https://crashoverride.com/releases). It's a
self-contained binary with no dependencies to install.

## Steps

### Step 1 - Load a `compliance` configuration

Chalk is designed so that you can easily pre-configure it for the
behavior you want, so that you can generally just run a single binary
with no arguments, to help avoid using it wrong.

Therefore, for this recipe, you should configure your binary with
either our `compliance-docker` configuration, or our
`compliance-other` configuration, depending on whether you're using
docker or not.

Assuming you've downloaded Chalk into your working directory, in the
docker case, you would run:

```
./chalk load https://chalkdust.io/compliance-docker
```

Otherwise, run:

```
./chalk load https://chalkdust.io/compliance-other
```

The profile we've loaded changes only three things from the default
behavior:

1. It enables collection of SBOMS (off by default because on large
   projects this can add a small delay to the build)

2. Specifies that any SBOM produced should be added to the chalk mark.

3. It configures the default action for the binary, when no specific
   command is applied (this is the only difference between the two
   configurations).

By default, Chalk is already collecting provenance information by
examining your project's build environment, including the .git
directory and any common CI/CD environment variables.

### 3 - Set up signing

Simply run:
```
./chalk setup
```

You'll get a link to connect an account for authentication, to be able
to use Crash Override's secret service for Chalk (the account is
totally free, and the account is only used to keep us from being an
easy Denial-of-Service target).

Once you successfully connect an account, you'll get a series of
success messages.

At this point, your Chalk binary will have re-written itself to
contain most of what it needs to sign, except for a `secret` that it
requests dynamically from our secret service.

### 4 - Chalk and Win

Now's that the binary is configured, you probably will want to move
the `chalk` binary to a system directory that's in your `PATH`.

How you run chalk depends on whether you're building via `docker` or not:

- *With docker*: You "wrap" your `docker` commands by putting the
  word `chalk` in front of them.

- *Without docker* : You simply invoke `chalk` in your build pipeline.

#### 4a - Docker

Your `build` operations will add a file (the *"chalk mark"*) into the
container with provenance info and other metadata, and any SBOM
generated. And, when you `push` containers to a registry, Chalk will
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

You'll see Docker run normally (It'll take a minute or so).  If your
permissions are right, it will also push to the registry. Once Docker
is finished, you'll see some summary info from Chalk on your command
line in JSON format, including the contents of the Dockerfile used.

If there's ever any sort of condition that Chalk cannot handle (e.g.,
if you move to a future docker upgrade without updating chalk, then
use features that `chalk` doesn't understand), the program will
*always* makes sure the original `docker` command gets run if it
doesn't successfully exit when wrapped.

#### 4b - when not using Docker

When you invoke Chalk as configured, it searches your working
directory for artifacts, collects environmental data, and then injects
a "chalk mark" into any artifacts it finds.

Chalk, therefore, should run after any builds are done, but it should
still have access to the repo you're building from. If you copy out
artifacts, then, instead of letting Chalk use the working directory as
the build context, you can supply a list of locations on the command
line.

The Chalk mark is always stored as a JSON blob, but how it's embedded
into an artifact varies based on the type of file. For example, with
ELF executables as produced by C, C++, Go, Rust, etc, Chalk creates a
new "section" in the binary; it doesn't change what your program does
in any way.

For scripting content, it just adds a comment to the bottom of the
file. JAR files (and other artifacts based on the ZIP format) are
handled similarly to container images, and there are marking
approaches for a few other formats, with more to come.

### 5 - Tell people where to look

As configured, anyone with access to the artifact can use Chalk to not
only see the chalk mark, but to validate the signature.

Any build of chalk can extract the chalk mark, and verify
everything. While we configured our binary to add marks by default,
the `extract` command will pull them out and verify them.

By default, it will look on the file system in the same way that
insertion did when we weren't using Docker. So:

```
chalk extract
```

Will report on anything it finds under your current working directory,
so would extract the mark from any artifacts you chalked that weren't
containerized. But if you built the example container, we can extract
from the example container easily just by providing a reference to it:

```
chalk extract ghcr.io/viega/wordsmith:latest
```

Either will pull all the metadata Chalk saved during the first
operation, and log it, showing only a short summary report to your
console. If the signature validation fails, then you'll get an obvious
error! So if anyone tampers with a mark, or changes a file after the
chalking, it's easily detected.

## Suggested Next Steps

- You can give people a web page to go to to see the compliance
  info. You can do this by configuring Chalk to send a copy of the
  relevent metadata somewhere else. Join the waiting list if you'd
  like to be able to have Crash Override handle this automatically for
  you.

- When using docker, you can easily ensure people don't forget about
  it by setting up an alias for `docker` that points to chalk (or,
  more robustly, you can rename `chalk` to `docker`, move docker out
  of the PATH, and configure `chalk` to know where to find the real
  `docker` command).

### Background Information

Below is a bit more information on supply chain security and the
emerging compliance environment around it, as well as some details on
how Chalk addresses some of these things under the hood.

#### SBOMs

Many organizations are already demanding SBOMs (software
bills-of-material) to understand open-source components in what they
consume, ideally so that they can use to monitor downstream
vulnerabilities in the software they use, even though the industry
really isn't good at operationalizing anything around this.

Unfortunately, there are two competing file formats for SBOM, SPDX and
CycloneDX. And, there are many, many different SBOM-related tools,
many of which only work in a subset of environments (e.g., tools that
only produce SBOMs for specific package envionments like npm). This
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

#### Provenance

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

#### Digital Signatures

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

So while automatic signing is susceptable to the attacker taking over
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

1. *chalk.pub* The public key you can give people out of band.
2 *chalk.pri* The ENCRYPTED private key (just in case you want to load
the same key into a future Chalk binary).

When you run `chalk setup`, we generate a keypair for you, and encrypt
the private key. The key is encrypted with a randomly generated
password (128 random bits encoded), and that password is escrowed with
our secret service.  The chalk binary receives a token that it can use
to recover the secret when it needs to sign.

The token and the private key are embedded into the Chalk binary, so
you won't have to keep a separate data file around to keep things
working. Your chalk binary can move from machine to machine no
problem.

Basically Chalk adds a `chalk mark` to itself, similarly to how it
will add one to containers. Chalk marks are essentially just JSON data
blobs added to software (or images containing software) in a way that
is totally benign.

Currently when signing, we're using the afforementioned In-Toto
standard. We are also leveraging the open source `cosign` tool, which
is also part of the Linux Foundation's SigStore project. We will
probably eventually incorporate the functionality directly into Chalk,
but for now, when Chalk cannot find cosign and you need it to sign or
validate, it will try to install the official binary, first via `go
get`, and, if that fails, via direct download.

#### SLSA

Part of the security industry have been hard at work on putting
together a standardized framework to capture all of the above
requirements, SLSA ("Supply-chain Levels for Software Artifacts").

The draft version was far-reaching and complicated, which clearly was
going to hinder adoption. Plus, due to much better marketing, security
teams started focusing on SBOMs. So SLSA has simplified dramatically.

With the new "1.0" standard, the imporant parts about SLSA basically
contain a few high-level asks. Nonetheless, even those high-level asks
can be very difficult for people to address, which the developers of
the framework did recognize. Thankfully, they made the wise decision
to frame their asks in tems of "Security Levels":

- *Level 0* means you're not doing anything to address provenance
   risks.

- *Level 1* compliance basically means that you'll provide people
   provenance information about how you built the package. This now no
   longer explicitly asks for SBOMs, but the need for component
   information is implicit, since they're asking for details on the
   build process.

- *Level 2* compliance primarily adds the requirement for the
   provenance information to be output at the end of your build
   process along with a digital signature of that information, which
   can absolutely be fully automated.

- *Level 3* compliance requires more hardening still; it's currently
   more ill-defined, but the gist is that they are hoping people will
   invest in demonstrating their build processes are 'tamper-evident'.

That goes back to our discussion on automated digital signatures
above. The SLSA designers realize that, in most domains, asking for
Level 3 compliance is unreasonable, at least at the moment.

So they're often not likely to be able to detect tampering with
software during the build process (which is the real goal of Level 3),
but they feel like being able to detect tampering AFTER the build
process should be a short-term realistic goal, which automated signing
does wlel enough (Level 2).

But they do clearly recognize that there hasn't been good tooling
around any of this yet, and that in many places, they'll be lucky to
get the basic info without the extra work of signatures.

But, in good news for everyone, Chalk gives you everything you need to
*easily* meet the Level 2 requirement for signed-provenance generated
by a hosted build platform.