# Deploy Chalk globally via Docker

### Automatically get visibility for every Docker build

## Summary

One of the biggest challenges to automatically tying together
information you have about production to information you have about
source code is the ease of deployment at scale.

Nobody wants to deploy one repository at a time, and if you do ask
people to add things to their pipelines, it will probably be forgotten
or misused.

With Chalk™, when your teams build via Docker, you can easily set up
Chalk on your build systems to automatically operate on every docker
build. All you need to do is:

1. Install a configured Chalk binary.
2. Set up a global alias for docker, having it call Chalk.

That's it. Chalk figures the rest out.

## Steps

### Step 1: Install a configured binary.

The easiest way to get Chalk is to download a pre-built binary from
our [release page](https://crashoverride.com/releases). It's a
self-contained binary with no dependencies to install.

Configuring Chalk is also easy. For the sake of example, we will use
our [compliance configuration](./compliance.md).

If Chalk is in your current directory, run:

```
./chalk load https://chalkdust.io/compliance-docker.c4m
```

When you install Chalk on your build systems, we recommend putting it
in the same directory where your docker executable is, though anywhere
in the default PATH is fine.

### Step 2: Add a global alias

You _could_ now deploy chalk and ask everyone to run it by invoking
`chalk` before their docker commands. But that's easy to forget. It's
really better to automatically call `chalk` when invoking Docker.

You can do this easily with a global alias. Your build systems will
have a global file for bash configuration, which, these days, is
almost always `/etc/bash.bashrc` (but if it's not there, then it
should be at`/etc/bashrc`).

This file runs when any bash shell starts. All you need to add to this
file is:

```bash
alias docker=chalk
```

> 💀 Some people add global aliases to /etc/profile.d, but we do _not_ recommend this, because some (non-login) shells will not use this.

Once you add this, you can log out and log back in to make the alias
take effect, our simply `source` the file:

```bash
source /etc/bash.bashrc
```

Now, whenever a new bash shell gets created that starts a `docker`
process, they'll be automatically configured to call `chalk`
instead. The way we've configured `chalk`, when it doesn't see any of
its own commands, it knows to use the Chalk `docker` command.

We always run the Docker command intended by the user, but we also
collect and report on environmental info.

You can also ask Chalk to add automatic data reporting on startup to
built containers ig you like, as described in [our how-to on building
an application inventory](./app-inventory.md)

## Our cloud platform

We have tried to make doing everything with Chalk as easy as possible, our cloud
platform makes it even easier. It is designed for enterprise
deployments, and provides additional functionality including prebuilt
configurations to solve common tasks, prebuilt integrations to enrich
your data, a built-in query editor, an API and  a lot more.

There are both free and paid plans. You can [join the waiting list](https://crashoverride.com/join-the-waiting-list) for early access.