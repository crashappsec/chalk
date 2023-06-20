# Chalk: GPS for Software.

Chalk is designed to make it incredibly easy to correlate knowledge about code in your dev environment to what's actually running in production.

Chalk can capture metadata at build time, and can, at that point, add a small 'chalk mark' to any artifacts, so they can be identified in production.  Chalk can also extract chalk marks and collect metadata about the operating environment when it does so.

It's also very easy to collect custom metadata, and control where metadata goes.

This is all geared to help people connect the dots much more quickly:

- When there's any kind of production issue, you can easily figure out exactly which build you're dealing with (down to the commit).
- If you don't own the software, but have to investigate an incident, you can easily figure out where the code lives, how it was built, and who owns it.
- You can come into a code base, and easily understand the environments where particular branches are running.

For developers / DevOps types, this can not only be useful when there are incidents, but it can help other functions get the answers they need, without having to come to you for knowlege.

For instance, security teams often look to understand who owns software, and then, to do their jobs, generally need help understanding where it's deployed, how it relates to other software, how it was built, and so on. This not only can help with their incident response, but can keep them from pursuing "incidents" on repos that security tools are flagging that aren't even in use.

Additionally, Chalk aims to shelter developers from having to spend unnecessary time on emerging security requirements.  The security team feels you need to collect SBOMs or produce attestations on the build provenance?  They can do the work to set it up, and it can all be transparent to everyone else.

## Overview
1. Chalk collects metadata about software during the build process. It's easily extensible what's collected.  You control where that metadata goes.

2. Chalk makes it easy to tell what collected metadata ties to what artifacts.  It does this by adding a 'chalk mark' to software (which does not affect execution in any way).  This chalk mark is easy to grep for; the chalk tool can also extract marks.

3. Chalk, on release, will ship with an API server with an attached SQLLite database, so that you can get started easily with a central repository for information on software.

### Data collection Capabilities

By default, Chalk collects information about the repository software is built from, and basic information the artifacts produced.  That can include, for instance, if a Docker image gets pushed, the info for the new image, and to where it got pushed.

You can also turn on third party CI/CD-time integrations, like Semgrep (static security analysis), or SBOM generation tools.

Additionally, if you use Chalk to extract marks from production, it can report basic information about the host operating environment.  If you like, you can configure Chalk in 'exec' mode, where you have it be your entry point; it starts your process, then in the background ships metadata back to you.  Or you can just have your software run a chalk report whenever you like as an easy push-based health check (and you can easily configure it to send back custom app data).

## Getting Started

The way to get started is to pull and run our Chalk configuration tool (or, download and run it).  You can just have it give you a default configuration, or you can do light customization. If you want to do more advanced customization, you can create your own configuration file manually, and have Chalk inject it into itself.  That will be covered in coming tutorials for advanced use cases.

As part of the configuration, you can choose to send data to any HTTPS endpoint that accepts JSON, to files, or to an S3 bucket. And, we will soon give a couple of additional options:

1. You will be able to send data to Crash Override's service. You'll be enrolled in the free tier as part of the process.  Note that at this time, being pre-release, there is ONLY a free tier.  Our intent is to layer additional enterprise functionality on top of this; we'd love to make basic chalk management easy and free, wherever was can reasonably afford to eat the cost!

2. If you don't want to do that, we'll bundle a container image with an open source app server solution with our Chalk API that will 'just work' out of the box, in conjunction with our configuration tool.

Specific instructions are coming soon.

### CI/CD integration

For getting Chalk integrated into CI/CD, part of the goal of having the configuration tool is so you can produce different self-contained configurations of a single chalk binary that make chalk easy for DevOps to integrate, never harder than, "run this binary after artifacts are built".

Sometimes, it can be even easier than that.  For instance, for builds involving Docker, chalk supports a wrap mode, where you can globally alias 'docker' to 'chalk'; Chalk will do its data collection and reporting, and can mark containers, but always makes sure the docker command executes (even if it's not a sub-command that we care about for reporting purposes).

For serverless, you'll need to manually add Chalk in 'exec' mode.  Note you can configure Chalk to probabilistically report when you've got functions that gets used at massive volumes.

## Learn More

More resources are coming soon.