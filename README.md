# Status

[![Actions Status](https://github.com/crashappsec/chalk-internal/workflows/lint/badge.svg)](https://github.com/crash-research/playground/actions)
[![Actions Status](https://github.com/crashappsec/chalk-internal/workflows/tests/badge.svg)](https://github.com/crash-research/playground/actions)

# Chalk: Your Software is art. Make sure it gets seen.

Chalk is designed to make it incredibly easy to correlate knowledge about code in your dev environment to what's actually running in production.

Chalk can capture metadata at build time, and can, at that point, add a small 'chalk mark' to any artifacts, so they can be identified in production. Chalk can also extract chalk marks and collect metadata about the operating environment when it does so.

It's also very easy to collect custom metadata, and control where metadata goes.

This visibility can help people operationally-- security teams can find what they need and prioritize their work, without bugging developers unnecessarily. Finance can get visibility into who's spending money, without bugging developers unnecessarily.

Developers can better understand what builds are actually in production, etc.

Chalk comes with both a tool and a specification.

## Background

Last year, we went out and interviewed many dozens of people about their problems around application security. One thing we noticed is that MANY people suffer because they cannot easily look at software in production and tie it back to the repo it came from. That is, there's a software provenance problem.

For instance, I watched multiple people work from their cloud security posture management tool, and they all still had plenty of Log4J alerts, more than a year after that bomb dropped. I always heard the same story:

1. Often their CSPM sees Log4J in a container, but it isn't actually in use.
2. But they'd have to find the developers, which involves some asking around.
3. The deveolpers don't want to spend cycles on something that is probably not an issue at this point anyway.

I also saw the problem from the other direction:

1. "Our code analysis tools are reporting a ton of alerts across our repos".
2. "For many of the repos, we have no idea where and whether they're deployed, or whether vulnerable versions are deployed".
3. "We couldn't possibly tackle all this, but we also don't know how to prioritize".

Basic provenence is a straightforward problem, but we were surprised to learn it wasn't addressed well in most corners of the industry.

Everyone could see it would be great to attach metadata to software at build, yet very few people were doing anything effective. The real problem was that "developer friction" problem. Many people had tried to address the problem, but had always asked the developers to make a significant process change. That never seems to give good results.

##
