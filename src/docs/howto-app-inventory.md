# Create a real-time application inventory

### Use Chalk to create an always up-to-date database of what code is where, and who owns it

## Summary

In software organizations, people lose plenty of time asking around
for information around software, because they don't have a good
real-time view of what they have.

For instance, when something breaks in production, ops people may not
know what software they're looking at, and often lose time trying to
figure out where the code lives and who owns it.

Similarly, developers often would like to know what versions of their
code are deployed where, especially when a bug report comes in.

This how-to uses Chalk™ to automate this easily:

1. Start a web service to collect data (via docker)
2. Load our `app-inventory` configuration
3. (Optional) Start up a service to let us browse collected data.

Each of the steps involves running only a single command.

### Before you start

The easiest way to get Chalk is to download a pre-built binary from
our [release page](https://crashoverride.com/releases). It's a
self-contained binary with no dependencies to install.

Additionally, the reporting web service we'll install by running two
docker containers, one for collecting logs, and the other to give us a
web frontend to browse them.

### Step 1: Set up the Inventory web service

We've put together a simple Python-based API Server that will accept
reports from the chalk binary we're configuring, and stick things
in an SQLite database.

The SQLite database will live in `~/.local/c0/chalkdb.sqlite`.

To start up the API server, which will create our database, run:

```bash
docker run --rm -d -w /db -v $HOME/.local/c0/:/db -p 8585:8585 --restart unless-stopped  ghcr.io/crashappsec/chalk-test-server
```

This will set up an API server on port 8585 on your machine,
accessible from any interface. Note, it will run in the background.
```

### Step 2: Load our `app-inventory` configuration

Chalk can load remote modules to reconfigure functionality. Even if
you've already configured Chalk, you should simply just run:

```
./chalk load https://chalkdust.io/app_inventory.c4m
```

You will be prompted to enter the IP address for the server we set up
in the previous step. The default will be your personal IP
address. For instance, I get:

![Output 1](../img/appinv-ss1.png)

Generally, the default should work just fine. 

After accepting the binary, it'll prompt you one more time to finish
the setup. The resulting binary will be fully configured, and can be
taken to other machines, as long as your server container stays up.

There's nothing else you need to do to keep this new configuration--
Chalk rewrites data fields in its own binary when saving the
configuration changes.

### Step 3: Browse some data!

Now, we should build and deploy some containers using Chalk, so you
can see real data in the database.

As a really simple example, let's build a container that prints load
averages once a minute to stdout.

First, we'll write a script for this:
```bash
cat > example.sh <<EOF
#!/bin/sh
while true
  do
    uptime
    sleep 60
  done
EOF
```

Now, let's create the Dockerfile:
```bash
cat > Dockerfile <<EOF
FROM alpine
COPY example.sh /
ENTRYPOINT ["/bin/sh", "example.sh"]
EOF
```

Now, build the container with chalk:
```bash
./chalk docker build -t loadavg:current .
```

You can then run the container:

```
./chalk docker run -it loadavg:current
```

As run, this will block our terminal until will hit CTRL-C.

If you're not an SQLite expert, we can run a web service that points
to the same database, that makes it a bit easier to browse. 
Let's set it up on port 8080:

```bash
docker run -d -p 3000:3000 -p 3001:3001 -v $HOME/.local/c0/chalkdb.sqlite:/chalkdb.sqlite  lscr.io/linuxserver/sqlitebrowser:latest
```

The database GUI will be available on port 3000. But, our database
will be empty until we start using Chalk, so definitely use chalk to
build and deploy some workloads.


Now, you can browse your SQLite database at
[http://localhost:8080](http://localhost:8080).

The database will be capturing both the repositories you're using to
build, and the containers you deploy.

The `CHALK_ID` field is one field that ties them together-- it will be
unique per container, but be associated both with the repository
information AND the containers you deploy.

> ❗While you may be tempted to correlate by container ID, note that
> Docker `push` operations will generally result in the remote
> container being different, so running containers are very likely to
> report different image IDs. Chalk does capture the relationship when
> wrapping `docker push`, but you'll have to go through extra work to
> link them together; the CHALK_ID will work.

If you like Chalk, you can easily deploy across your docker builds and
deploys by adding a global alias. See the [howto for docker deployment](./howto-deploy-chalk-globally-using-docker.md)

## Warning

This how-to was written for local demonstration purposes only.There is
no security for this how-to. You should always have authn, authz and
uses SSL as an absolute minimum.

## Our cloud platform

While creating a basic app inventory with Chalk is easy, our cloud
platform makes it even easier. It is designed for enterprise
deployments, and provides additional functionality including prebuilt
configurations to solve common tasks, prebuilt integrations to enrich
your data, a built-in query editor, an API and more.

There are both free and paid plans. You can [join the waiting
list](https://crashoverride.com/join-the-waiting-list) for early
access.

### Background Information

Traditionally IT departments maintained list of their hardware and
software assets in a CMDB or [configuration management data
base](https://en.wikipedia.org/wiki/Configuration_management_database). These
systems were not designed for modern cloud based software and the
complexity of code that they are made from.

Spotify created a project called [Backstage](https://backstage.io) to
centralise developer documentation. Many companies now use it as a
source of truth for their development teams.

Many companies create application inventories using spreadsheets.