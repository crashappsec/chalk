---
title:
description:
---

# Chalk™ User Guide

## About This Guide

Chalk is like GPS for software, allowing you to easily see where
software comes from and where it is deployed. Chalk collects,
stores, and reports metadata about software from build to production.

The tie is generally made by adding an identifying mark (which we call
a _chalk mark_) into the artifact at build time, such that the mark is
easy to validate and extract.

This document is meant to be a guide for users and implementors both,
to help them understand core concepts behind Chalk and our
implementation. It should help you better understand Chalk's behavior
and some of the design decisions behind it.

This document is NOT intended to be a tutorial overview. For that, see
the [Getting Started Guide](../chalk/getting-started.md) for an easy
introduction to Chalk.

Similarly, this guide is more a reference to Chalk's behavior, not a
use-case-based HOW-TO guide. We will be publishing a separate set of
HOW-TO guides.

Beyond this document, there's an extensive amount of reference material for users:

| Name                                                                                 | What it is                                                                                                                         |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| [**Metadata Reference**](../chalk/config-overview/metadata.md)                       | Details what metadata Chalk can collect and report on, and in what circumstances                                                   |
| [**Command Line Reference**](../chalk/command-line.md)                               | Details command-line usage, including flags                                                                                        |
| [**Configuration Overview**](../chalk/config-overview.md)                            | Provides overview on Chalk configuration components                                                                                |
| [**The Chalk Configuration Options Guide**](../chalk/config-overview/config-file.md) | Details properties you can set in Chalk's configuration file, if you choose to use it over our command-line configuration wizard   |
| [**Output Configuration Reference**](../chalk/config-overview/output-config.md)      | Shows how to set up sending reports wherever you like, using the config file.                                                      |
| [**Metadata Report Configuration Guide**](../chalk/config-overview/metadata.md)      | Shows how to specify what data to collect, when, and how to report different things to different places, if using the config file. |
| [**Config File Builtins**](../chalk/config-overview/builtins.md)                     | Shows the functions you can call from within a configuration file                                                                  |
| [**Release Notes**](../chalk/release-notes.md)                                       | Includes key known issues in the current release of Chalk                                                                          |

We have provided chalk with sensible default configurations for demo and testing, as well as some sample configs for specific use cases available through the [Chalk Getting Started Guide](../chalk/getting-started.md) and the how-to guides.

## Source Code Availability

We will be making source code available at the time of our public launch. Instructions on how to build directly and building via docker file are available in the [Chalk Getting Started Guide](../chalk/getting-started.md), as well as instructions on how to download pre-built chalk binaries.

## Basic Concepts

##### Section Contents

- [Reports](#reports)
- [Configuration](#configuration)
- [Command Line Operations](#command-line-operations)
- [Basic Marking Experience](#basic-marking-experience)
- [Build Wrapping](#build-wrapping)
- [Basic Extraction Experience](#basic-extraction-experience)
- [On-demand Extraction](#on-demand-extraction)
- [Identifying Chalked Containers](#identifying-chalked-containers)
- [Using Chalk to Launch Processes](#using-chalk-to-launch-processes)
- [Metadata Keys](#metadata-keys)

Chalk operates on _software metadata_. Generally, it's most important
to run chalk during CI/CD so as to collect metadata on the build process
and insert an identifier into any built artifacts. The process of
adding metadata into an artifact is what we call _chalk marking_.

Chalk can also report on existing chalk marks in artifacts at any
other time. Of particular interest, it can be set up to launch a
program and, in parallel, report on that program and its operating
environment on a regular heartbeat interval.

There are lots of different kinds of metadata that chalk can report on and
inject into artifacts. Basic use would involve capturing enough
build-time info to be able to identify, when looking at a production
artifact, what code repository it came from and which specific build
it is.

But there is plenty of other data that chalk can collect, including
results from running analysis tools, such as security analysis or SBOM
(software bill of materials) generation tools. This flexibility can
help meet a wide variety of requirements (for instance, SLSA level 3
compliance if a customer is requesting it).

After chalk marks are added, the Chalk tool's focus is on both
reporting data about the existing mark (while validating its
integrity), as well as reporting basic environmental information about
the runtime environment.

The actual act of adding a chalk mark into software artifacts is key
to making it easy to trace software through its lifecycle. We add
identifiers into the mark that can be extracted easily, allowing us to
tie together metadata about the artifact whenever it was collected.

### Reports

Chalk reports are fully configurable. You can configure what metadata
gets added to reports, and in what circumstances. Reports can be sent
to the terminal, logged, posted to a web URL, or written to object
storage. You can make multiple reports for a single chalk operation,
and you individually control where data from those reports go.
Typically, we recommend sending the bulk of the metadata collected
directly to some kind of durable storage.

Generally, at least some metadata will get inserted into the artifact
itself to make it easy to tie artifacts in production to their
metadata. Chalk can then be used to find metadata in production
environments.

### Configuration

Chalk stores its own configuration inside its own binary. This configuration is
used to set up behavior and preferences for each command, including how marking
and reporting happens. For more information on how to write Chalk
configurations, see the [config overview](./config-overview.md).

### Command Line Operations

Chalk insertion operations attempt to add chalk marks to artifacts,
and then run any configured reporting. Currently, the `chalk insert`
subcommand and `chalk docker build` subcommand are insertion
operations.

Besides collecting and inserting metadata during CI/CD, there are
other things the chalk command can be used to do. Most other chalk
operations will _extract_ existing chalk marks, report what is
extracted, and also optionally report information from the time of
extraction. The other operations may generally perform other
operations, such as spawning a program in the case of `chalk
exec`. The most important of these operations are introduced below,
and more detail is provided in the [Chalk Command Line
Reference](../chalk/command-line.md).

There are a few chalk operations that do not report, including things
like `chalk help` and `chalk version`. These are also detailed in the
command line reference.

In the default shipped configuration, when you invoke `chalk` on the
command line, you will get a summary report to `stdout` and a full
report sent to a local log file. Chalk can be configured to send
reports elsewhere, such as a server endpoint or an s3 bucket.

In the default configuration, the log level for error messages
defaults to `info`. The log level is easily changed in the
configuration or with command line flags.

When you run in docker wrapping mode (described below), most console
logs are suppressed by default, unless the log level of the message is
`error`. However, more logs will be added to any reporting.

Below is a high-level overview of the most important commands. Note
that, by default, these commands will treat the current working
directory as the place to look for existing artifacts and will scan
recursively.

### Basic Marking Experience

Philosophically, chalk aims to make the actual deployment into the
CI/CD pipeline as easy as possible. While chalk is incredibly
flexible, the intent is to pre-configure behavior and embed that
configuration into the binary. That way, you can hand a binary to
someone else and say, “just run this after building your artifacts”,
and it should automagically work.

However, the software universe isn’t that simple. Different types of
artifacts can have different types of considerations. Currently, the
chalk binary works in two modes:

1. **Build wrapping**, in which it wraps the command that builds the
   artifact, adding a chalk mark into the artifact at build time.
2. **Stand-alone insertion**, in which it chalks the supported artifact
   types after the artifact has been built.

Currently, build wrapping only works with `docker`, and is introduced
below.

When inserting chalk marks into other software artifacts
(specifically, binaries, scripts, JAR files and similar), we use
stand-alone insertion, which, out of the box, can be invoked by
typing:

`chalk insert`

After running this command, the file system is scanned from the
current working directory, marking any runnable software (except for
any artifacts that live in hidden directories, such as scripts in
`${CWD}/.git`).

By default, chalk will try to collect basic metadata:

- It will look for a `.git` directory to associate a git repository.
- It will collect host information about the build environment such as
  environment variables and platform details.
- It will see if there's a local `CODEOWNERS` or `AUTHORS` file, and
  capture it, if so.
- It will generate identifiers for the artifact, including the
  `CHALK_ID` which uniquely identifies the unchalked artifact, and the
  `METADATA_ID` which uniquely identifies the artifact plus the
  metadata inserted into the chalk mark.

You can also configure chalk to do a static security analysis via
`semgrep`, or to create SBOMs via `syft`. Chalk also supports custom
metadata collection and digital signing. For some examples of what
you can do with config, see the how-to guides.

> ❗ You can configure chalk to use `insert` as the default command,
> in which case the binary can be deployed with no command line
> options whatsoever.

### Build Wrapping

The experience for chalking containers is different, as it leverages
build wrapping.

Currently, build wrapping is only supported for building docker
containers with `docker build`, although we are working on
other options. The deployment could take various forms, all of which
will work out of the box:

1. Put `chalk` in front of the build command. E.g.: `chalk docker
build -tsome:thing .`
2. Configure build systems to start up with global aliases, aliasing
   `docker` to `chalk`.
3. Rename the `chalk` binary to docker, and put it somewhere in the
   path that will generally show up before the actual docker command.

In all these cases, chalk will search the rest of the user's `PATH`
for docker (unless configured to look in a specific location).

Build wrapping is conservative in that if chalk cannot, for some
reason, be confident about adding a chalk mark to an artifact, it runs
the build process as if it hadn’t been invoked at all.

When wrapping docker, many docker commands are not affected, and are
passed through without Chalk taking action. However, for builds, Chalk
will, by default:

1. Add labels to the produced image with repository metadata.
2. Rewrite the Dockerfile to add a chalk mark.
3. Generate a chalk report with metadata on the build operation.

Chalk also reports a bit of metadata when pushing images to help
provide full traceability.

Chalk can also be configured to add build-time attestation when possible.

Because of the way Docker works, there's currently not a simple,
pre-defined algorithm for getting a repeatable hash of a container
image. As a result, the `CHALK_ID` will be based on a random value,
and there will be some validation considerations if not using
attestations.

### Basic Extraction Experience

The chalk command is capable of extracting full chalk marks, and can
report the presence of those chalk marks with the full flexibility of
insertion. That means you have full flexibility in selecting what to
report on and where to send reports. Additionally, on-demand
extraction can report metadata about the runtime environment.

During the extraction operation, chalk runs once, reports what it
finds (including information about the host environment), and then
exits. Unlike insertion, it does not accept exclusions like `.git`; if
there are chalk marks in specified paths, it will report them, even if
they perhaps never should have been added in the first place.

### On-demand Extraction

By default, running `chalk extract` recursively searches the current
directory for artifacts with chalk marks (_including_ any scripts that
live in the hidden directories such as `${CWD}/.git`).Directory
scanning is recursive unless specified otherwise with `recursive:
true` in the chalk config or `--no-recursive` on the command line.

If we want to extract chalk from a single artifact (or directory), we
can specify the target:

```bash
chalk extract testbinary
```

which will extract the chalk mark only from the target.

Running `chalk extract container` will search all running containers
for chalk marks; likewise, `chalk extract image` will search all
images for chalk marks (but be aware that chalk extraction from docker
images may take a long time, particularly if there are many images).

Similarly, to extract chalk marks from a specific container or image,
we can specify the image ID, image name, container ID, or container
name. For example:

```bash
chalk extract 0ed38928691b
```

Generally, when using chalk for container extraction, it is best to
run it in the context of the host OS, as non-privileged containers may
not have enough information to ensure which image is running.

In most cases, the container ID will be available from within the
container in the `HOSTNAME` environment variable. But there generally
won’t be any easy, ironclad way to tie that to the image from within
the container, short of integrity checking the entire file system
from the entry point.

### Identifying Chalked Containers

While containers do keep the chalk mark in a file on the root of their
file system, it can often be inconvenient, or even impossible, to get
access to the container.

However, there are plenty of monitoring tools (including CSPM tools in
the security space) that capture enough runtime metadata about
containers such that you can tie it back to the chalk mark via the
image hash of the container.

While not available by the time chalk marks are added (due to the
cryptographic one way function), the image hash is captured in the
chalk report in the `_CURRENT_HASH` key. Generally, you should have an
information trail with your tooling from the container ID to the image
ID.

For instance, if you were just using docker, and your container id
were `0ed38928691b`, you could generally retrieve the image ID simply
with:

```bash
docker inspect 0ed38928691b | grep -i sha256
"Image": "sha256:4ee5e79272183b8313e43921b3e46c1809399391535c0c044dd6f2230041eede",
```

Note that when Chalk is in Docker mode, it also wraps `docker push`,
which generally will result in a new image ID. Capturing that info on
push provides the needed breadcrumbs.

### Using Chalk to Launch Processes

If you want to better automate traceability across software's life cycle, you can configure chalk to run software (ideally, software that you've previously marked via `chalk insert` or `chalk docker build`). Chalk supports a `chalk exec` operation where it will run your process, as well as report on that process and the host environment.

The current default behavior for chalk is then to exit quietly, without impacting your process. Chalk can also be configured to continue running in the background and emit a periodic heartbeat report that is fully customizable.

<!-- TODO: getting started guide doesn't cover chalk exec, this should probably be a how-to
Setting up `chalk exec` to run your software is easy, and basic
examples are shown for both with and without docker in
[Getting Started Guide](../chalk/getting-started.md). -->

### Metadata Keys

Metadata is at the core of Chalk, which categorizes data into four types:

1. **Chalk-time artifact metadata**, which is data specific to a
   software artifact, collected when inserting chalk marks. This data can
   be put into a chalk mark, and it can also be separately reported
   without putting it in the chalk mark.

2. **Chalk-time host metadata**, which is data about the environment
   in which chalk ran in when inserting chalk marks. This data can also
   be added to the individual marks inserted, if desired.

3. **Run-time artifact metadata**, which is data about software
   artifacts that can be collected on any invocation of chalk, such as
   when launching a program you've previously marked, or when searching
   for chalk marks on a system.

4. **Run-time host metadata**, which is data about the host, captured
   for any chalk invocation.

Some things to note about metadata:

- Some metadata is inappropriate for those looking for fully
  reproducible builds, such as time-specific keys. The default is to
  include some of these items, which are useful to a different set of
  people who want to be able to track which build came from which
  environment. These concerns can be dealt with via the configuration
  by setting up custom reports for different consumers.
- Chalk-time keys can be reported at run-time if they're being
  extracted from a chalk mark, but they will always contain the values
  added at chalk time.
- Run-time keys cannot be added to chalk marks.
- If the implementation is unable to collect a piece of metadata, it
  is _not_ included in any reporting, no matter the configuration.

There's plenty of flexibility on when to collect and report on
metadata. This document covers some of the basics at a high
level. More detailed information on metadata keys is available through
the help documentation via `chalk help metadata`, or for information
on a single specific key, `chalk help metadata [keyname]`.

> ⚠️ It _is_ possible to create chalk marks without inserting
> identifiers into artifacts, called "virtual chalking". However, it
> is _not recommended_, and is intended primarily for testing. Doing
> so means that deployed software will need to be independently
> identified and correlated, negating a lot of the value of Chalk.

## Additional Detail and Specs

##### Section contents

- [Configuring Chalk](#configuring-chalk)
- [Chalk Mark Basics](#chalk-mark-basics)
- [Custom Keys](#custom-keys)
- [Marks Versus Reports](#marks-versus-reports)
- [Required Keys in Chalk Marks](#required-keys-in-chalk-marks)
- [Current Chalk Mark Insertion Algorithms](#current-chalk-mark-insertion-algorithms)
- [Future Insertion Algorithms](#future-insertion-algorithms)
- [Multiple Marks in an Artifact](#multiple-marks-in-an-artifact)
- [Replacing Existing Marks](#replacing-existing-marks)
- [Mark Extraction Algorithms](#mark-extraction-algorithms)
- [Mark Reporting](#mark-reporting)
- [Mark Validation](#mark-validation)
- [Mark Deletion](#mark-deletion)
- [Configuration File Syntax Basics](#configuration-file-syntax-basics)
- [Testing Configurations](#testing-configurations)
- [Overview of Reporting Templates](#overview-of-reporting-templates)
- [Reporting Templates for Docker Labels](#reporting-templates-for-docker-labels)

In this section, we will go into more detail on key Chalk concepts,
and give pointers to deeper reference material where appropriate.

While we have produced an additional implementation of Chalk that is
quite flexible, we designed it so that other people could build
implementations, including partial implementations, and easily achieve
interoperability across implementations.

For instance, it is easy to write a compliant chalk library that
allows programs to store their implementations inside their
executable, and retrieve them, while still inter-operating with other
programs that collect a wider range of metadata.

We certainly intend to allow other people to implement compatible
software, and if the software meets our requirements, call it a
_conforming Chalk implementation_. To that end, as we explain parts of
Chalk in this document, we will often indicate explicitly whether
something is necessary to be 'conformant' or not.

However, until we are confident that the we've been thorough enough at
specifying conformance to ensure interoperability, note that nobody
should use the Chalk trademark to describe an implementation of
anything without the project's express approval.

Currently, the project trademark is held by Crash Override,
Inc. However, once the project is sufficiently mature, we expect to
assign ownership of the trademark to a non-profit.

To help with interoperability and to help people to understand
capabilities of various implementations, Chalk is versioned -- not
just the reference software, but the information that is required for
compliance. Chalk versioning will follow the Semver standard.

Until Chalk is declared 1.0.0, new versions of the spec may contain breaking changes. We will document these as they happen.

### Configuring Chalk

Chalk stores its configuration inside its binary. Configurations can
be extracted from a binary with the `chalk dump` command, and new ones
loaded with the `chalk load` command, which loads from either a local
file or an https URL.

The actual configuration format is designed to be at least as simple as
the typical \*NIX config file whenever possible, while still supporting
advanced use cases. The configuration file format itself is mostly in
line with the NGINX family of configuration files, with sections and
key/value pairs. For those advanced use cases, the config file also
supports some limited programmability.

Generally, the average user shouldn't need such features (and we
expect the upcoming configuration wizard to fulfill most of their
needs), but the people who do should find the syntax to be
straightforward to anyone with basic programming experience.

For people who want to dig into the actual configuration file, we
provide an overview in [Config Overview](../chalk/config-overview.md),
and more details in the how-to guides for specific use cases. We also
provide documentation via the help in `chalk help config`.

Note that other implementations of Chalk are free to implement their
own configuration mechanisms.

### Chalk Mark Basics

Chalk writes arbitrary metadata into software artifacts. The metadata
written into a single artifact is called the **chalk mark**. The mark
itself is always a (utf-8 encoded) JSON object, where the first
key/value pair is always `"MAGIC" : "dadfedabbadabbed"`.

The presence of this value is required to consider data embedded into
an artifact a _chalk mark_.

Beyond the initial key pair, key/value pairs can appear in any order.

Key names beginning with a leading underscore `_` must never appear in
a chalk mark (as they denote reporting data that was collected at the
time a report was generated).

Key names beginning with a `$` are considered to be internal to chalk
implementations that add metadata, called _injectors_ in this
document. If an implementation uses such keys, then chalk marks using
that implementation must identify and test the injector by adding the
key `INJECTOR_NAME` to the chalk mark, which must be registered,
currently through the Chalk development team.

These keys should only ever be written into programs that themselves
modify chalk marks.

Starting with Chalk 0.1.1, Chalk mark injectors that find an existing
chalk mark in an artifact will, if replacing the chalk mark, keep `$`
keys they do not recognize, unless specifically configured to remove
them, while also considering them part of the previous chalk mark.

### Custom Keys

Users of the reference implementation of Chalk and other conforming
implementations of Chalk cannot add arbitrary chalkable keys or
arbitrary runtime keys, and the keys defined must conform. However, if
these keys don't meet your needs, you can add custom keys. Any key
starting with an `X_` is reserved for custom chalkable keys (both host
and artifact), and any key starting with `_X_` is reserved for custom
run-time keys.

### Marks Versus Reports

Marks are JSON objects inserted into a software artifact, or into a
`virtual-chalk.json` file if virtual chalking is enabled (not
recommended).

Chalk can also generate _reports_ that are separate from the
artifact. These reports can be generated at the time of chalking, but
they can also be generated at any point after a mark is added, such as
on `extract` or `exec` operations. Chalk reports are also structured
as JSON. The format and requirements around such reports are discussed
in [Overview of Reporting Templates](#overview-of-reporting-templates).

It's important to understand the basic semantics of reports and how
they differ from marks:

1. Reports can occur at any time, not just when inserting chalk marks.
2. When inserting chalk marks, if a report is also generated, the data in
   the mark and the data in the report can overlap, but does NOT need to
   be identical.

It will be common, at chalk insertion time, to add data about the
software artifact to a report that is _not_ added to the chalk mark
itself, as discussed shortly. In such a case, metadata keys can get
reported that are not in the mark. Similarly, it is fine for metadata
to be put into the mark that is not in the associated report.

When a report is generated because a chalk mark is seen in the field
(meaning not on an insertion operation), the report can report some,
all, or none of the information it finds in chalk marks. It may also
report new metadata that cannot be added to the chalk mark outside an
insertion operation.

Reported metadata keys starting with a leading underscore `_` are
never added to a chalk mark, and represent collected metadata at the
time the report was generated.

When reports contain metadata keys that do NOT start with an
underscore, they contain information from _the time of metadata
insertion_. If Chalk is not performing insertions at the time, such
keys will always be directly taken from the chalk mark. No keys
without the leading underscore can be reported for non-insertion
operations unless they are found in a chalk mark.

We do recommend, at chalk insertion time, to be thoughtful about
what metadata will be added to the chalk mark itself.

There are two key reasons for this:

1. **Privacy**. Depending on where the software is distributed and who
   has access to it, there may be information captured that people
   examining the artifact shouldn't see. In this case, there should be
   enough information stored in the mark to find the report record
   that was generated at the time of chalking without leaking
   sensitive data in the mark itself.

2. **Mark size**. Although size generally won't be much of a concern
   in practice, some metadata objects may be quite large, such as
   generated SBOMs or static analysis reports.

The first concern is, by far, the most significant. Even in cases where
software never intentionally leaves an organization, there can be
risks. For instance, if the chalk mark contains code ownership or
other contact information, while it does make life easier for
legitimate parties, it also could help an attacker who manages to get
onto a node and is looking to pivot.

### Required Keys in Chalk Marks

To be considered a valid chalk mark, the following keys must be present:

1. `MAGIC`. This key must be first, and must have the exact value
   `"dadfedabbadabbed"`. This is a strong requirement even though JSON
   object items do not require ordering. This is part of how we make
   chalk mark extraction easy to implement.
2. `CHALK_ID`. This value is an encoding of the first 100 bits of an
   artifact's unchalked SHA-256 hash, whenever such a hash can be
   unambiguously determined. Otherwise, it derived from 100 bits selected
   from a cryptographic PRNG.
3. `CHALK_VERSION`. This value is required so that extractors can
   unambiguously deal with future changes to Chalk.
4. `METADATA_ID`. In contrast to the `CHALK_ID`, this is a unique identifier for the _chalked_ artifact.

Details about what keys contain can be found in `chalk help
metadata`. Compliant implementations of Chalk must insert compatible
information.

If you're looking for more information on Chalk's use of SHA-256 and
the ways you can use hashes in identification, see `chalk help hashing`.

The JSON object representing the chalk mark can contain arbitrary
spaces that would otherwise be valid in JSON, but cannot contain
newlines (newlines in values are encoded). This requirement is only
for chalk marks stored in an artifact; there are no requirements on
presentation when displaying chalk marks.

### Current Chalk Mark Insertion Algorithms

How the chalk mark it is stored in the artifact varies:

| Software Type              | Storage Approach                                                                                                                                                    |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ELF Executables            | Added to its own `.chalk` section                                                                                                                                   |
| Container Images           | Adds `/chalk.json` file to the top layer of the image file system; soon will store an attestation with the mark, whenever supported.                                |
| JAR/WAR/EAR files          | A `.chalk.json` file at the top level of the archive                                                                                                                |
| ZIP files                  | A `.chalk.json` file at the top level of the archive                                                                                                                |
| Scripting Languages        | Placed in a comment, generally at the end of the file. Note that currently this requires a Unix shebang or a .py file extension to be identified as a valid script. |
| Byte-compiled Python       | Added to the end of the .pyc file                                                                                                                                   |
| Mach-O (MacOS) executables | Due to Apple restrictions, we automatically wrap the binary into a shell script, and mark the shell script.                                                         |

The implementation for scripting languages will do one of the following:

1. Replace an existing mark, wherever it is.
2. Place a mark in the first place in the file it finds a _chalk placeholder_.
3. Write the mark at the end of the file.

In the first case, the mark does NOT need to be at the end of the
file, due to the support for placeholders.

A valid placeholder consists of the JSON object `{ "MAGIC" :
"dadfedabbadabbed" }`. The presence of spaces and the number of spaces
is all flexible, but no newlines are allowed.

The intent here is to allow developers to specify where they want
marks to go, either so that they're the least in-the-way, or so that
they can include them as data, instead of a comment. This requires a
_normalization_ function for computing the `HASH` value, which is
described below.

Implementations won't insert potentially ambiguous chalk marks
relative to the current version of Chalk. For instance, it may soon be
possible to put ELF chalk marks in places other than the end of a
file, and older versions of Chalk would continue inserting to the same
place.

In such a case, the newer version must remove the older chalk
mark. However, the older version might be invoked after already being
marked by the new version.

The current version of Chalk will not deal with this issue, but
before version 1.0, we expect to define and implement a
solution. Currently, we're considering two approaches:

1. File-based artifacts will need to be scanned in their entirety
   before marking, and if a mark is found, the spot is reused. This would
   make things easier on implementors, but could impact performance for
   some larger artifacts.

2. We may require marking the locations that older versions would have
   selected with a mark that invalidates the location, and points to the
   correct location.This would allow for more efficient operation, but
   would make some parts of the implementation more difficult, especially
   around calculating the `CHALK_ID`, which is discussed below.

To be clear, while compliance for chalk implementations requires
adhering to the algorithms as defined by the reference, it does not
require implementing any specific algorithm for insertion or
extraction of marks, as long as it implements at least one. Nor does
an implementation need to be set up to chalk all possible artifacts.

For example, we expect to release small libraries for different
language environments that allow programs to chalk themselves. This
would allow them to easily load and store configuration information
without using external files (as Chalk itself currently
does). Similarly, we intend to use this to have programs automatically
add bash completion scripts on their first run, if such scripts aren't
found in an environment.

### Future Insertion Algorithms

We have approaches planned for roadmap executable types, including
in-browser Javascript, PE binaries, and more.

Generally, even going forward, anything in an image format will have
the mark stored in the root of its file system, either as `chalk.json`
or `.chalk.json`. Anything else will generally be stored in a way
where the raw JSON would be directly visible in the artifact's bytes.

We want marking strategies to be unambiguous to implement and easy to
extract, wherever possible. To that end, any algorithm that doesn't
meet the requirements laid out here should be brought to the project
to be considered for approval.

### Multiple marks in an artifact

Sometimes it might make sense for a software artifact to have multiple
Chalk marks. For instance:

- A zip file deployment might itself be marked, and contain multiple
  executables that also have marks.
- A single script-based program may consist of several files, all
  independently marked, particularly when an entry point cannot easily
  be programmatically determined.
- Individually compiled ELF objects could conceivably be marked
  independently, and then composed into an ELF object that is also
  marked.

In the first two cases, no changes need to be made; sub-items can be
marked unambiguously. Implementations can either:

- Leave sub-marks in place.
- Lift them into the top-level object in full, adding them to the
  `EMBEDDED_CHALK` key, in which case they should not be placed in the
  embedded objects, or should be removed from them if already there.

In the third case, allowing individual object marks to exist
independently in the artifact would make it harder to support simple
extraction. As of the current version, multiple marks independently
existing in a single document (such as executables) that is not a
well-defined image format is not allowed.

### Replacing existing marks

When a Chalk mark already exists in a document, it's up to the context
of the insertion whether the existing chalk mark should be
removed. In most cases, an existing chalk mark should be preserved. For
instance, when chalking during deployment, any previous chalk mark
from the build process should be preserved.

In such cases, there are three options:

1. The old chalk mark can be kept, in its entirety, in a key in the
   new chalk mark called `OLD_CHALK_MARK`.
2. If the user is confident that data about the chalk mark being
   replaced was captured, then the mark can be replaced with the
   single key `OLD_CHALK_METADATA_ID`, where the value of this key is
   the `METADATA_ID` of the mark being replaced.
3. Similarly, one can use the `OLD_CHALK_METADATA_HASH`, if full
   hashes are preferred to IDs.

Particularly in the latter two scenarios, note that if the old chalk
mark is not reported before being replaced, and then the mark is
replaced again, the link between marks will be lost. Therefore we
strongly discourage using those keys without reporting.

### Mark Extraction Algorithms

Extractors generally do not need to care about file structure for
non-image formats. It should be sufficient for them to scan the bytes
of such artifacts, looking for the existence of Chalk `MAGIC` key.

However, for image-based formats, the extractor needs to be aware
enough of the marking requirements for that format to be able to
unambiguously locate the primary mark.

### Mark Reporting

As mentioned in the section [Marks Versus
Reports](#marks-versus-reports), chalk reports do not have to contain
the same data as in chalk marks.

Currently, Chalk can generate reports when any of the following
operations are performed:

| Operation   | How to invoke the operation                                  | Description                                                                                                                                               |
| ----------- | ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `insert`    | `chalk insert`                                               | Adds chalk marks to non-container artifacts.                                                                                                              |
| `extract`   | `chalk extract`                                              | Scan an environment, looking for existing marks in software artifacts.                                                                                    |
| `build`     | `chalk docker ...` where the docker command leads to a build | Adds chalk marks while building a container.                                                                                                              |
| `push`      | `chalk docker ...` where the docker command leads to a push  | Report when pushing a container to a registry.                                                                                                            |
| `exec`      | `chalk exec`                                                 | Spawn a process, and perform reporting.                                                                                                                   |
| `heartbeat` | `chalk exec --heartbeat`                                     | Same as `exec`, but with heartbeat enabled.                                                                                                               |
| `delete`    | `chalk delete`                                               | Delete chalk marks from existing artifacts.                                                                                                               |
| `env`       | `chalk env`                                                  | Perform reporting on a host environment without performing a scan (as `chalk extract` does), and without spawning another process (as `chalk exec` does). |
| `load`      | `chalk load`                                                 | Replace a chalk executable's configuration.                                                                                                               |
| `dump`      | `chalk dump`                                                 | Output the currently loaded configuration.                                                                                                                |
| `setup`     | `chalk setup`                                                | Setup signing and attestation.                                                                                                                            |
| `docker`    | `chalk docker ...`, where chalk encounters an error.         | Still runs docker, but reports on cases where `insert` or `push` operations could not complete.                                                           |

The operation associated with a report is available via the `_OPERATION` key.

For more details on the command line usage of chalk, see the help documentation at `chalk help commands`.

Chalk reports can contain per-artifact information, as well as
information specific to the host environment.

A chalk report is output as an array of JSON objects that contains
the report, so in most cases the array will only have a single
object. However, when reports are sent, they're always sent in a JSON
array that may have multiple objects, in case an implementation has
cached reports that have not been delivered.

For each single report, the JSON keys that are valid in the top-level
report will NEVER be artifact-specific data. Only what we call 'host
data' is included at the top level, by which we mean data specific to
one run of chalk on one host.

For artifact data, there's a host-level metadata key called `_CHALKS`,
the value of which is an array of JSON objects, containing the
metadata specific to that artifact to be reported on. Each element in
the array corresponds to a single artifact's chalk information.

The data in a report contained in `_CHALKS` does not have to consist
of a full chalk mark; the user could choose to report on a subset of
keys, or no keys from the chalk mark at all. Furthermore, the artifact
data in a `_CHALKS` field will not consist solely of chalk-time
information; it can also contain information from the time the report
was run. For instance, a single artifact report could contain both the
filesystem path where the software lived when it was chalked in the
build environment, as well as the file system path for its current
location (`PATH_WHEN_CHALKED` vs `_OP_ARTIFACT_PATH` keys).

In all cases, the chalk-time keys at the top level of the report and
at the top level of the objects in the `_CHALKS` array _will not_
contain a leading underscore. The keys representing report-time
operations _will_ contain a leading underscore.

There are _no specific requirements_ about what keys must be contained
in a report; the user has the final say in what data gets reported on
and what does not. In fact, reports do not have to report the
`_CHALKS` field. However, removing that field does mean there will be
no artifact-specific information in the report, making it suitable for
host reporting and summary stats only.

Generally, if reporting on artifacts at all, we strongly recommend
configuring the reporting to include, at a bare minimum, the
`CHALK_ID` and `METADATA_ID` fields.

For each of the above operations, the chalk report allows you to
configure a primary report. That report can go to multiple different
places, including the terminal, log files, HTTPS URLs, and s3 buckets.

You can also define additional reports that get sent at the same time,
so that you can send different bits of data to different places. This
is done with Chalk's _custom reporting_ facility.

For more information, see the following:

- `chalk help metadata` contains documentation for what metadata keys
  are available in which operations, as well as the meaning of the
  fields. Documentation for keys will also include the conditions
  where the reference implementation can find them.
- [The Config Overview Guide](../chalk/config-overview.md) covers how
  to configure WHERE reports get sent.

Note that compliant insertion implementations do not require compliant
reporting implementations. But compliant chalk tools for other
operations MUST produce fully conformant JSON.

However, there are no requirements on how that JSON gets distributed
or managed, other than that compliant implementations must provide a
straightforward way to make the JSON available to users if desired.

A report not in the proper format, or with key/values pairs that are
not compliant, is not a Chalk report.

### Mark Validation

Any time a mark is extracted, Chalk must go through a validation process.

_IF_ the artifact isn't a container, extractors independently compute
the value of `HASH` for that artifact (the field isn't currently
computed for containers).

That value is then used to derive what we expect the `CHALK_ID` to
be. If it is not a valid value, we log an error, which may print to
the terminal depending on the log level, and will generally be added
to any chalk operation report under the top-level key `_OP_ERRORS`.

If the `CHALK_ID` validates, or if the artifact is a container, the we
must also validate the `METADATA_ID`.

The `METADATA_ID` requires independently recomputing the
`METADATA_HASH` by normalizing and encoding the fields explicitly
added into a chalk mark.

The normalization algorithm is as follows:

1. The following key/value pairs are removed: `MAGIC`,
   `METADATA_HASH`, `METADATA_ID`, `SIGN_PARAMS`, `SIGNATURE`,
   `EMBEDDED_CHALK`.
2. The following key/value pairs are encoded first, in order (whenever
   present; they are skipped if they were not added to the mark):
   `CHALK_ID`, `CHALK_VERSION`, `TIMESTAMP`, `DATE`, `TIME`,
   `TZ_OFFSET`, `DATETIME`.
3. The following key/value pair is encoded LAST, (whenever present):
   `ERR_INFO`.
4. The remaining keys are encoded in lexicographical order.
5. The encoding starts with the number of keys in the normalization,
   as a 32-bit little endian integer.
6. Each key/value pair is encoded in order by encoding the key, and
   then the value, using the item normalization algorithm below.

Individual items are conceptually normalized as follows:

- Strings are normalized by adding the byte `\x01`, followed by the
  length of the JSON-encoded string in bytes represented as a 32-bit
  little endian unsigned value, followed by the encoded string.
- Integers are normalized by adding the byte `\x02`, followed by the
  64-bit value of integer, when represented as a little-endian
  unsigned value.
- Booleans are represented as two bytes each: `\x03\x00` for `false`
  and `x03\x01` for `true`.
- Arrays are normalized by adding the byte `\x04`, followed by the
  number of items in the array encoded as a little endian 32-bit
  integer, followed by the normalized version of each item in order.
- Dictionaries / Json objects must be stored ordered in Chalk
  values.They are normalized by adding the byte `\x05`, followed by
  the number of key/value pairs in the dictionary encoded as a 32-bit
  little endian integer, followed by paired encodings for each pair,
  in their stored ordering.

The complete normalized string is hashed with SHA-256. The resulting
256-bit binary value is the base of both the `METADATA_HASH` field and
the `METADATA_ID` field. The entire value is hex-encoded to get the
`METADATA_HASH`, whereas the `METADATA_ID` is computed via the same
algorithm used to calculate `CHALK_ID` fields.

Remember that keys beginning with an underscore are never added to
chalk marks, and so are never considered in the normalization process
at all.

We omit the key `MAGIC` because it is always constant across all
invocations, and chalk marks will not even be recognized if it is
modified in any way.

We omit `METADATA_HASH` and `METADATA_ID` because they are the output
of the normalization process.

We omit `SIGNATURE` and `SIGNING` because they are further
validation discussed below built on top of the `METADATA_ID`.

We currently omit `EMBEDDED_CHALK`, instead allowing them to be
independently validated, if desired. While this does mean the
`EMBEDDED_CHALK` key can be excised without detection at validation
time, we expect that either the relevant sub-artifacts will have
embedded chalk marks themselves, or the server will have record of the
insertion.

Currently, this key is only used for ZIP files, and the `HASH` value,
which must be present for ZIP files, is used, meaning the integrity of
the underlying artifacts is guaranteed by this process.

This was initially done because there were some concerns about the
potential amount of processing, especially since our implementation
requires using the file system for ZIP files. But we have some
reservations, and will consider changing this in future versions.

This validation process only proves that the chalk mark's integrity is
intact from when it was written (and, if there is a `HASH` field, that
the core artifact _as normalized_ is intact). It does not validate
that the chalk mark was added by any particular party.

For that level of assurance, the `METADATA_ID` field reported at
extraction time should be cross-referenced against insertion-time
reports. When these IDs correlate, you can be confident that the
metadata is identical across reports (and the files in question as
well, as long as there is a `HASH` field).

In containers, where we do not have an easy, reliable hash, metadata
normalization and validation works the same way. But we strongly
recommend automatic digital signatures to ensure that you can detect
changes to the container.

Digital signing can be used both with containers and with other
artifacts. With containers, we use Sigstore with their In-Toto
attestations that we apply on `docker push`. The mark is replicated
in full inside the attestation.

For other artifacts, the signature is stored in the Chalk mark, but is
(necessarily) not part of the metadata hashing, since it needs to sign
that data.

### Mark Deletion

If needed, it's possible to delete chalk marks from most artifacts,
with containers being the exception (they should be rebuilt
instead). This can be done with the `chalk delete` command, which will
recursively delete chalk marks from all artifacts in the current
working directory, or with the `chalk delete [targetpath]` command,
which will delete chalk marks from the target artifact or
directory. The `delete` operation will produce a report where the
deleted chalk mark (if any) will be reported, along with run-time
environmental information.

### Configuration File Syntax Basics

Many of the things you might want to configure simply involve setting
configuration variables. For instance, we could create and load the
following configuration file:

```bash
color: false  # Also could set NO_COLOR env variable.
log_level: "error"  # Otherwise, defaults to 'warn' in non-docker cases
run_sbom_tools: true  # Run syft; off by default.
run_sast_tools: true  # Run semgrep; off by default.
# A backup; a self-truncating log file for reporting
use_report_cache: true
default_command: "docker"  # Defaults to "help".
report_cache_location: "/var/log/chalk-reports"
# When using docker, the prefix to add to auto-added labels
docker.label_prefix: "com.example."
```

In the configuration file, we can also set up environment variables for reporting, such as by defining new environment variables and using simple if / else logic to set a default if the environment variable is not set on the host. For example, the line `docker.label_prefix: "com.example."` in the sample config above can be changed to:

```bash
if env_exists("CHALK_LABEL_PREFIX") {
  docker.label_prefix: env("CHALK_LABEL_PREFIX")
} else {
  docker.label_prefix: "com.default."
}
```

In this case, if `CHALK_LABEL_PREFIX` is set on the host, then all
docker images built with chalk will have that label prefix; otherwise
the label prefix will be `com.default.`.

### Testing Configurations

When you load a new configuration, Chalk will test it
automatically. But you can generally test your configuration more
quickly by leaving it in an external file.

Out of the box, Chalk will search the current directory, `/etc/chalk`, `/etc/`, `~/.config/chalk/` and `~` for a file named `chalk.c4m` on startup. Or you can specify the specific file to use with `--config-file` (also `-f`).

> 👀 Note that running `chalk help commands` will show globally
> available flags, and `chalk config` shows common configuration
> variables and their current values.

By default, Chalk will happily evaluate the embedded configuration,
and then a configuration on disk. You can also force Chalk to skip one
or both with the flags: `--no-use-embedded-config` and
`--no-use-external-config`.

In fact, if you want to force Chalk to ignore any external
configuration file, you can set `use_external_config: false` in the
embedded configuration.

If a configuration has a syntax error, Chalk will _not_ run. For
instance, if we had our config file only set color to false, but we
forgot the `:` (or `=`, which also works for setting config
attributes), we would get:

```bash
**error: chalk**: ./chalk.conf: 1:7: Parse error: Expected an assignment, unpack (no parens), block start, or expression
  color false
**error:** Could not load configuration files. exiting.
viega@UpDog chalk %
```

### Overview of Reporting Templates

Reports and chalk marks decide which keys to add based on report
templates and mark templates, respectively. These are essentially
lists of keys to include or not include for a given situation.

While you can build your own templates, the easiest thing to do is to copy and paste the default templates into your new configuration file, change the defaults, and then load the config file. Defaults are available in `src/configs/base_report_templates.c4m` for report templates and in `src/configs/base_chalk_templates.c4m` for mark templates.

For more information on how templates can be configured manually in the configuration file, see the [Config Overview Guide](../chalk/config-overview.md).

### Reporting Templates for Docker Labels

The default configuration for what labels to output automatically are
kept in the `chalk_labels` mark template, which, by default is:

```bash
mark_template chalk_labels {
  key.COMMIT_ID.use                           = true
  key.COMMIT_SIGNED.use                       = true
  key.ORIGIN_URI.use                          = true
  key.AUTHOR.use                              = true
  key.DATE_AUTHORED.use                       = true
  key.COMMITTER.use                           = true
  key.DATE_COMMITTED.use                      = true
  key.TAGGER.use                              = true
  key.DATE_TAGGED.use                         = true
  key.BRANCH.use                              = true
  key.TAG.use                                 = true
  key.TAG_SIGNED.use                          = true
}
```

You can set additional chalkable keys in this template, and/or disable
reporting on any of those keys.

## Glossary

| Term               | Description                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Artifact           | Any software artifact handled by Chalk, which can recursively include other artifacts. For instance, a Zip file is an artifact type that can currently be chalked, which can contain ELF executables that can also be chalked.                                                                                                                                                                                          |
| Chalk Mark         | JSON containing metadata about a software artifact, generally inserted directly into the artifact in a way that doesn’t affect execution. Often, a chalk mark will be minimal, containing only small bits of identifying information that can be used to correlate the artifact with other metadata collected.                                                                                                          |
| Unchalked          | A software artifact that does not have a chalk mark embedded in it.                                                                                                                                                                                                                                                                                                                                                     |
| Metadata Key       | Each piece of metadata Chalk is able to collect (metadata being data about an artifact or a host on which an artifact has been found) is associated with a metadata key. Chalk reports all metadata in JSon key/value pairs, and you specify what gets added to a chalk mark and what gets reported on by listing the metadata keys you’re interested in via the report template and mark template.                     |
| Chalking           | The act of adding metadata to a software artifact. Aka, “insertion”.                                                                                                                                                                                                                                                                                                                                                    |
| Extraction         | The act of reading metadata from artifacts and reporting on them.                                                                                                                                                                                                                                                                                                                                                       |
| Report             | Every time Chalk runs, it will want to report on its activity. That can include information about artifacts, and also about the host. Reports are “published” to output “sinks”. By default, you’ll get reports output to the console, and written to a local log file, but can easily set up HTTPS post or writing to object storage either by supplying environment variables, or by editing the Chalk configuration. |
| Report Template    | You have complete flexibility over what goes into chalk reports. A report template is a specification of metadata keys that you want to report on. They’re used to configure reports, and also to configure things like which metadata items should be automatically added to a container as labels.                                                                                                                    |
| Mark Template      | Like report templates, you have complete flexibility over what goes into chalk marks. A mark template is a specification of metadata keys that you want to go into the chalk mark.                                                                                                                                                                                                                                      |
| Sinks              | Output types handled by Chalk. Currently, chalk supports JSON log files, rotating (self-truncating) JSON log files, s3 objects, http/https post, and stdin/stdout.                                                                                                                                                                                                                                                      |
| Chalk ID           | A value unique to an unchalked artifact. Usually, it is derived from the SHA-256 hash of the unchalked artifact, except when that hash is not available at chalking time, in which case, it’s random. Chalk IDs are 100 bits, and human readable (Base32).                                                                                                                                                              |
| Metadata ID        | A value unique to a chalked artifact. It is always derived from a normalized hash of all other metadata (except for any metadata keys involved in signing the Metadata ID). Metadata IDs are also 100 bits, and Base32 encoded.                                                                                                                                                                                         |
| Chalkable keys     | Metadata keys that can be added to chalk marks. When reported for an artifact (e.g., during extraction in production), they will always indicated chalk-time metadata.                                                                                                                                                                                                                                                  |
| Non-chalkable keys | Metadata keys that will NOT be added to chalk marks. They will always be reported for the current operation, and start with a `_`. There are plenty of metadata keys that have chalkable and non-chalkable versions.                                                                                                                                                                                                    |
