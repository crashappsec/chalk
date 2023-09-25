# Chalk™: observability for the software lifecycle

![Chalk](./img/co-chalk-diagram-hero.png)

## About Chalk™

Chalk™ connects knowledge about code in your dev environment to what's
actually running in production.

Chalk™ can capture metadata at build time, and can, at that point, add a small
'chalk mark' to any artifacts, so they can be identified in production. Chalk™
can also extract chalk marks and collect metadata about the operating
environment at run time.

It's also very easy to collect custom metadata, and control where that metadata
goes.

This is all geared to help people connect the dots much more quickly and easily:

- When there's any kind of production issue, you can easily figure out exactly which build you're dealing with (down to the commit).
- If you don't own the software, but have to investigate an incident, you can easily figure out where the code lives, how it was built, and who owns it.
- You can come into a code base, and easily understand the environments where particular repositories and branches are running.

For developers, security and DevOps engineers, this is useful not only
during incident investigation, but to answer broader sets of questions
(patching and health status, whether security tools and monitoring are actually
in place in different repositories and environments etc.), without having to
come to you for knowledge.

For instance, security teams often attempt to understand who owns a piece of
software, and then, to do their jobs, generally need help understanding where
it's deployed, how it relates to other software, how it was built, and so on.
This not only can help with their incident response, but can keep them from
pursuing false "incidents" on repos that security tools are flagging that
aren't even in use.

Additionally, Chalk™ aims to shelter developers from having to spend unnecessary
time on emerging security requirements. The security team feels you need to
collect SBOMs or produce attestations on the build provenance? They can do the
work to set it up, and it can all be transparent to everyone else.

In short:

1. Chalk™ collects metadata about software during the build process. _What
   exactly is being collected_ is easily extensible and customizable. You
   control where collected metadata goes.

2. You can use Chalk™ to add metadata to anything - even existing binaries or
   other artifacts whose build systems might be your control but which are used
   in your environment.

3. Chalk™ makes it easy to tell what collected metadata is tied to what
   artifacts. It does so by adding a 'chalk mark' to software (which does not
   affect execution in any way). This chalk mark is easy to grep for; the Chalk™
   tool can also extract marks.

4. Chalk™, on release, ships with an API server backed by a database, so that
   you can easily spin up a central repository of information for your
   software.

## Data Collection

By default, Chalk™ collects information about the repository a piece of software
is built from, as well as basic information on the artifacts produced during
the build process. For instance, if a Docker image gets pushed, the chalk mark
collects the info for the new image and where it got pushed to.

You can also turn on third party CI/CD-time integrations, like Semgrep (a
static security analysis tool), or SBOM generation tools.

Additionally, if you use Chalk™ to extract chalk marks from production, it can
report basic information about the host operating environment. If you like, you
can configure Chalk™ in `exec` mode, where you have it be your entry point: it
starts your process, then in the background ships metadata back to you. Or you
can just have your software run a Chalk™ report whenever you like as an easy
push-based health check (and you can easily configure it to send back custom
app data).

## Configuration Options

Chalk™ comes with a configuration tool (separate of the Chalk™ binary) which you
can run as a container or standalone binary. You can just have it give you a
default configuration, or you can do light customization. If you want to do
more advanced customization, you can create your own Chalk™ configuration file
manually, and have Chalk™ inject it into itself. That will be covered in
upcoming tutorials for advanced use cases.

As part of the configuration, you can choose to send data to any HTTPS endpoint
that accepts JSON, to files, or to an S3 bucket. And, we will soon give a
couple of additional options:

1. You will be able to send data to Crash Override's service. You'll be
   enrolled in the free tier as part of the process. Note that at this time,
   being pre-release, there is ONLY a free tier. Our intent is to layer
   additional enterprise functionality on top of this; we'd love to make basic
   Chalk™ management easy and free, wherever we can reasonably afford to assume
   the cost!

2. If you don't want to use the Crash Override service, we'll bundle a
   container image with an open source app server which will be compatible with
   the Chalk™ API, which can be deployed locally to your environment and be
   configured in conjunction with our configuration tool.

See the [Getting Started](./getting-started.md) section for an introductory
overview in running Chalk™ under different configurations, accessing chalk marks
and using the Chalk™ configuration tool, and the
[Chalk™ User Guide](./user-guide.md) for more information on available
customization options.

## CI/CD Integration

Our goal for using Chalk™ in CI/CD is to never make the process harder than "run
this binary after artifacts are built". Sometimes, it can be even easier than
that. For instance, for builds involving Docker, Chalk™ supports a wrap mode
where you can globally alias 'docker' to 'chalk'; Chalk™ will do its data
collection and reporting, and can mark containers, but always makes sure the
docker command executes (even if Chalk™ cannot process the image for whatever
reason).

To add the single-binary, pain free applications of Chalk™, the configuration
tool is used and produces different self-contained configurations of a single
Chalk™ binary that can be deployed.

For serverless, you'll need to manually add Chalk™ in `exec` mode. Note
you can configure Chalk™ to probabilistically submit reports in case of
functions that get used at massive volumes.

## Known Issues

Chalk™ is currently in an early alpha preview mode. Documentation and
features are expected to be getting modified frequently over the next
months and until the first (1.0) release. We will be keeping a
publicly available list of known issues [here](./known-issues.md).
