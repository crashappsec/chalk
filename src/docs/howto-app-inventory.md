# How to build a real-time application inventory

## Just like putting GPS trackers on your software

## Summary

In software organizations, people lose plenty of time asking around
for information around software, because they don't have a good
real-time view of what they have.

For instance, when something breaks in production, ops people may not
know what software they're looking at, and often lose time trying to
figure out where the code lives and who owns it.

Similarly, developers often would like to know what versions of their
code are deployed where, especially when a bug report comes in.

In this recipe, we'll build a real-time asset inventory for our
software that ties together the repositories and code owners to what
we've deployed.

Not only will you spend less time thrashing around for information,
but other people will have a resource they can use to self-serve
without having to take more of your time.

## When to use this

This is applicable for most organizations deploying software in a
cloud environment, especially when that software is managed out of
version control systems (whether or not code tends to be written
in-house).

For this recipe, we do limit ourselves to workloads build via Docker.

## Solution

Wrap your Docker builds with Chalk to:

1. Automatically collect information about software in CI/CD.

2. Automatically Configure built containers to report information on
start-up.

Send the data to a web service (that we'll deploy via Docker) running
SQLite.

### Alernative solutions

Many companies have artifact repositories, but they don't do a good
job providing a clear line back to the repo, developer and version.

Some companies that require using a single build / deploy environment
can reliably find these answers without talking to people, though it
generally requires manually following a trail of breadcrumbs.

Many large enterprises have regulatory requirements to keep an
inventory like this, but do it manually (through spreadsheets), which
is slow and error prone.

## Prerequisites

This recipe does assume access to your build system, and assumes
tracked workloads are built through Docker (and therefore deployed as
container). Chalk can be used beyond that, but it's outside the scope
of this recipe.

It also assumes you have Chalk installed.

The easiest way to get Chalk is to download a pre-built binary from
our [release page](https://crashoverride.com/releases). It's a
self-contained binary with no dependencies to install.

## Steps

### Step 1: Load our `app-inventory` configuration

Chalk is designed so that you can easily pre-configure it for the
behavior you want, so that you can generally just run a single binary
with no arguments, to help avoid using it wrong.

We're going to download and install a chalk configuration that does
the following:

1. Sets up Chalk to be able to seamlessly wrap invocations of Docker
   via a global alias.

2. Configures Chalk to report not only build-time information, but
   runtime information when containers built with this recipe are run.

3. Has everything report back to a container we'll deploy in the next step.

The container we'll deploy is a simple Python-based HTTP server
integrated with SQLite. You'll be able to browse and search all the
info you collect with SQL, or by adding any frontend you desire.

Or, you can easily use any HTTP / HTTPS endpoint you like.

The base configuration for this recipe though, will assume the
reporting container is always running on 'localhost:7878'.

We can fix that after we get things up and running. For now, let's
just install the base.

Assuming that you've downloaded Chalk, and it's in your current
directory, you would simply run:

```
./chalk load https://chalkdust.io/app-inventory.c4m
```

This downloads our config, tests it, and loads it into the binary.

Note that Chalk reconfigures itself by editing its binary. So it's
best when configuring to have write access to the binary. If you do
not, then copy the binary and run it from someplace you do.

### Step 2: Set up the Inventory web service

We are going to set up two containers:

1. A simple Python-based API Server that will accept reports from the
chalk binary we're configuring, and stick things in the SQLite
database.

2. A container running an SQLite Web interface to give us a reasonable
GUI on top of it.

Both of these images will need to share a single SQLite database. The
API server we'll want to configure to listen for connections on
external interfaces.

Then, in the next step, we're going to want to re-configure our Chalk
binary to use the public IP address of the container.

Let's put our SQLite database in `~/.local/c0/chalkdb.sqlite`.

First, let's start up the API server, which will create our database
for us:

```
docker run --rm -d -w /db -v ${HOME}/.local/c0/:/db ghcr.io/crashappsec/chalk-test-server
```

This will set up an API server on port 8585 on your machine,
accessible from any interface. Note, it will run in the foreground, 

Now, let's start up the SQL browser container on port 8080:

```
docker run --rm -d -e SQLITE_DATABASE=/db/chalkdb.sqlite -v {$HOME}/.local/c0/:/db coleifer/sqlite-web
```

The database GUI will be available on port 8080. But, our database
will be empty until we start using Chalk, so let's come back to the
data after we've got a bit of it.

### Step 3: Reconfigure Chalk

Our Chalk binary just needs to point to our API server. Lets first
dump the configuration we loaded to a file:

`chalk dump app-inventory.c4m`

Now, open `app-inventory.c4m` in your favorite text editor.

You'll see the following:

```
sink_config output_to_http {
  enabled: true
  sink:    "post"
  uri:     "http://localhost:8080/report"
}
```

Edit the URI to point to your API container; you really just need to
replace `localhost` with your IP address (or a DNS name if you have
one).

Once you've saved your change, reconfigure your binary with:

`chalk load app-inventory.c4m`

### Step 4: Automate calling docker via `chalk` in your build environment. 

You *could* now deploy chalk and ask everyone to run it by invoking
`chalk` before their docker commands. But that's easy to forget. It's
really better to automatically call `chalk` when invoking Docker.

You can do this easily with a global alias. How this is done can
differ, but typically your systems will have a global file for bash
configuration, usually `/etc/bash.bashrc` (but less commonly
`/etc/bashrc`)

This runs when any bash shell starts. All you need to add to it is:

```
alias docker=chalk
```

Then, you need to move `chalk` to someplace that's going to be in the
default path (usually putting it in the same directory as your docker
executable is a safe bet).

> 💀 We do *not* recomment /etc/profile.d because some (non-login)
  shells will not use this.

Once you add this, you can log out and log back in to make the alias
take effect, our simply `source` the file:

```
source /etc/bash.bashrc
```

Now, whenever a new bash shell gets created that starts a `docker`
process, they'll be automatically configured to call `chalk`
instead. The way we've configured `chalk`, when it doesn't see any of
its own commands, it knows to use the Chalk `docker` command.

That command always runs the Docker command intended by the user, but
in our case:

1. Collects information about the build environment; and

2. Slightly adjusts the Docker input so that Chalk will also start up
with containers, and report to your Inventory web service.

### Step 5: Use it!

Build and deploy some workloads. Once you do, from the machine you
deployed the containers, browse to:

```
http://localhost:8080
```

The database will be capturing both the repositories you're using to
build, and the containers you deploy.

The `CHALK_ID` field is one field that ties them together-- it will be
unique per container, but be associated both with the repository
information AND the containers you deploy.

> ❗While you may be tempted to correlate by container ID, note that
  Docker `push` operations will generally result in the remote
  container being different, so running containers are very likely to
  report different image IDs. Chalk does capture the relationship when
  wrapping `docker push`, but you'll have to go through extra work to
  link them together; the CHALK_ID will work.

## Suggested Next Steps

- Ideally, the server would have a layer of authentication behind it.

- If you want to make sure to detect that containers you're reporting
  on haven't been modified since the build info being reported, you
  can turn on digital signing; see our compliance recipe for more
  info.

- You can hook up operational information to help automatically
  categorize workloads by their environment, so that people can easily
  pick out what's in prod and what's not. See our recipe on
  integrating with Cloud Custodian as an example.

- Make the query interface easily available to other people in your
  organization!

- Setup HTTPS, at least for the API server.

- Crash Override will soon be offering a service that includes a more
  polished interface around application inventory management, where
  you can give your dev teams a nicer view onto their apps, where
  they're deployed. Sign up for the waiting list!

### Background Information

Mark, please fill this one out!