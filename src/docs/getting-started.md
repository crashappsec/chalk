# Getting Started with Chalk

A design goal for chalk is that people deploying it shouldn't have to
do more than drop in a single chalk binary in the right place in their
CI/CD pipeline. And in many cases, it can be completely transparent
to them.

Any configuration should be done up-front by whoever needs the data
from chalk. And while it's designed to be deeply customisable, we also
worked hard to make out-of-the-box configurations useful, and to make
it very easy to configure common usecases.

First, let's do some basics to get up and running, both with
chalking artifacts, and reporting on them in production.

> ⚠️ Currently, we have only released a Linux-x86 binary for Chalk.

## First Run

First, let's checkout a demo repository:

```bash
git clone https://github.com/crashappsec/chalktest.git && cd chalktest
```

Among other things, this directory contains C source code for a
"Hello, World!" program. Let's build it and test it with:

```bash
make && ./hi
```

If you don't have a C compiler, the `higen` script will output the
Linux x86 binary:

```bash
./higen && ./hi
```

Also in the repository is `calcite`, a simple bash script that manages
downloading chalk and installing configs. When running our tooling
locally, it will echo its commands.

Let's just check out the help:

```bash
./calcite
```

We're primarily going to use calcite to manage installing particular
chalk configuration. `calcite switch [config]` will:

1. Download an unconfigured version of chalk, if not present.
2. Create a version of chalk where the desired configuration is loaded, if needed.
3. Make sure that `./bin/chalk` is the desired version.

Let's start by installing the `cli` option:

```bash
./calcite switch cli
```

This will fetch the proper chalk binary for your platform, and install
it in `./bin/chalk`, keeping a copy of the binary that indicates what
configuration it is.

Let's run our first chalk command by simply typing:

```bash
./bin/chalk
```

You should see a JSON blob in stdout, called the Chalk Report. This is metadata
collected about the artifacts that have been chalked, and the host
environment. Here are a few important things to note for now:

1. We've captured basic information about the build environment, including our repo, branch and commit ID.
2. We actually have added chalk marks to three things: the `hi` program, the `higen` script, and the `calcite` script.
3. The `CHALK_ID` key is unique to the \_unchalked\* executable, and is just an
   encoding of 100 bits of the `HASH` field.
4. Chalk did _not_ chalk itself. It did, however, chalk the version of itself that didn't have an installed configuration.

We can have Chalk report on what it inserted into artifacts:

```bash
./bin/chalk extract
```

Here, you'll get some warnings on stderr about items in .git not being
chalked. By default, Chalking doesn't go into .git directories for
insertion, but it does for reporting, just to avoid missing items that
are chalked when we're reporting.

Some of the things reported on were found in the actual artifacts.
But a lot of the reporting is about the operational environment at the
time of the extract. For instance, each program's HASH field is the
hash of the _unchalked_ program, but the `_CURRENT_HASH` field is the
SHA-256 value of the artifact on disk, after the chalk mark is added.

In all contexts, metadata keys starting with an underscore (`_`)
indicate metadata associated with the current operation we're
performing. Without the underscore, it refers to info from the time
of chalking.

If we want to see how the chalk marks look in our software, run the command:

```bash
strings hi | grep MAGIC
```

You'll see there's an embedded JSON string in the `hi` binary. Chalk
marks are just data blobs that don't impact the binary, and don't run
in any way.

If you grep the same thing on the `higen` script:

```bash
grep MAGIC higen
```

you will notice the
output has a hash mark (`#`) at the front. Scripts using the Unix
"shebang" (i.e., the #! at the top) are marked by adding a comment
on the last line of the script.

If you were to change the 'higen' script and re-run `./bin/chalk
extract`, Chalk would complain that the extracted CHALK_ID didn't
match the calculated one-- it validates files when extracting.

## Sending the Data Somewhere

In this example, there's more metadata in the artifact than we'd
typically store. Chalk put more data into the mark itself, because it
didn't send its reports anywhere (except stdout). If we're sending
data somewhere, it really only needs to insert enough data to look up
the artifact in a database.

We've provided a test server that uses an SQLite database in the
backend that you can use. This can be downloaded and run through the
`calcite` tool.

**Please Note - it does NOT run in the background, so you should
either start a second shell, or manually background the server
process. Starting in a separate shell is recommended so that you can
observe the server output**.

The below command will run the server on port 8585. If the server
isn't found locally, will first download it, and the docs directory it
needs (installed to ./site).

```bash
./calcite server
```

Note that the server can be configured to use HTTPS, yet we've left it
unconfigured for demo simplicity. Please be mindful of this when
testing.

Now that we have our server running, we need to configure Chalk to use
that server.

We have a couple of options for this. First, let's do so by setting an
environment variable.

In the shell where you will execute subquent chalk commands,
run:

```bash
export CHALK_POST_URL=http://localhost:8585/report
```

From that terminal, let's delete existing chalk marks with:

```bash
./bin/chalk delete
```

You'll notice we no longer get a chalk report. Instead, _on the terminal where we run our chalk command_, we see:

```
info: Post 202 Accepted (sink conf='my_https_config')
```

Also, the web server should show some debug output with chalk have a final `/report` entry as follows:

```
INFO:     127.0.0.1:58166 - "POST /report HTTP/1.1" 202 Accepted
```

![server1](./img/serverout1.png){ loading=lazy }

### Viewing chalk data

Let's go ahead and re-chalk things:

```bash
./bin/chalk
```

On submission of new chalks, your server should now report:

```
INFO:     127.0.0.1:59274 - "POST /report HTTP/1.1" 200 OK
```

Those chalk marks have been recorded in our SQLite database. You can
connect to the database with any SQLite shell, but we have an endpoint
that will allow you to dump the server's info from the chalk insertion
operation. To see this pretty-printed:

```bash
curl http://127.0.0.1:8585/chalks | jq
# Drop the | jq if you don't have it installed, but then it'll be ugly!
curl http://127.0.0.1:8585/chalks
```

### Basic Configurations

Using an environment variable to confugre the server is flexible, but
could end up error prone. We might prefer for the `configs` directory:

```bash
ls configs
```

The contents of that directory are all Chalk configuration files; the
configuration language is called
[con4m](https://github.com/crashappsec/con4m). `cli.c4m` was the
configuration we first installed above, and is basically the
'out-of-the-box' configuration, except for the first line which tells
chalk to assume the `insert` command if no other command is given on
the command line:

```con4m
default_command: "insert"
```

When someone takes that particular binary and passes it no arguments,
it trys to add chalk marks to everything in the current working
directory. That makes it decent for plopping into traditional CI/CD
pipelines, to run after artifacts are built.

But, that configuration only prints reports to stdout, unless you set
environment variables. Instead, we're going to switch to the
`server.c4m` config, which is the same as the `cli` config except
that:

1. It adds a 'sink configuration', specifying where to post (e.g., to a web endpoint, an S3 bucket, or a rotating log file).
2. It subscribes this configuration to the Chalk report.
3. It removes the builtin subscription that causes the default report to go to
   the console.

The entire difference between the two configurations is just the following:

```con4m
sink_config demo_http_config {
  # The 'post' sink type is for HTTP and HTTPS posting.
  # Note that all the below quotes are required.
  sink: "post"
  uri:  "http://localhost:8585/report"
}
subscribe("report", "demo_http_config")
unsubscribe("report", "json_console_out")
```

To load this configuration, we can use chalk's `load` command, which
will test the config and show us what it installed. However, let's
let `calcite` do it; it'll show us the command we ran, but pipe the
output to `/dev/null` to not spam your terminal.

Let's load a chalk binary with the desired configuration to talk to
our server:

```bash
./calcite switch http
```

This yields the following output:

```
Switching to configuration: http
Loading configuration from: /home/viega/chalktest/configs/http.c4m
+ cp /home/viega/chalktest/bin/chalk-0.1-download /home/viega/chalktest/bin/chalk
+ /home/viega/chalktest/bin/chalk load --log-level=error --skip-command-report /home/viega/chalktest/configs/h
ttp.c4m
+ cp /home/viega/chalktest/bin/chalk /home/viega/chalktest/bin/chalk-0.1-http
SUCCESS: Switched to the http demo config.
```

Both configurations of our binary are in the `bin` directory, but
`calcite` always leaves your most recent configuration as `bin/chalk`.

You might notice that, when `chalk load` ran above, the web server
reported some results.

The `chalk load` command is implemented by a chalk binary chalking
itself. And, the `CHALK_POST_URL` environment variable sets us up to
report.

In fact, our newly configured binary will _double-report_ if we don't
clear the environment variable first. Configurations generated by our
beta configuration tool will avoid the double reporting, having the
env variable take priority, when present.

But for now, let's just run:

```bash
unset CHALK_POST_URL
```

## Chalking a Container

You'll notice we have a Dockerfile in our repository. We can use
Chalk to mark container images by using chalk to wrap our docker
commands. Assuming you have docker installed and configured, you can run:

```bash
./bin/chalk docker build -t chalk-demo:latest .
```

The report went to our server and chalking happend on top of normal
docker execution.

We can make the chalking process completely invisible to the user, so
they don't even have to know they're running the `chalk`
command. Let's configure a binary to make `docker` the default
command. It will have the same configuration as last time, reporting
to the local server, except the default Chalk command will be `docker`
instead of `insert`:

```bash
./calcite switch docker
```

You can see that `calcite` applied the demo docker configuration, and
it _also_ copied the binary to bin/docker. Chalk is smart about
masquerading as docker; so long as long as it appears in your path
higher up than the actual Docker command, it will seamlessly wrap
docker.

Let's ensure that's the case by adding our binary directory to the
front of our current PATH:

```bash
export PATH=$PWD/bin:$PATH
```

Now, if you run:

```bash
docker build -t chalk-demo:latest .
```

A Chalk report will get sent to the SQLite database:

```
INFO:     127.0.0.1:37870 - "POST /report HTTP/1.1" 200 OK
```

But from the point of view of the person running docker, it looks like
a normal docker command ran. Though, if you look closely at the steps,
though, we did automatically add container labels with the build-time
info, and added the chalk mark.

Chalk really only monitors a subset of docker commands, but when
wrapping docker, it will absolutely pass through docker commands, even
if it doesn't do any of its own processing on them.

## Run-time reporting

So far, we've focused on ease of adding chalk marks. But Chalk's goal
is to bridge code managed in repositories to what's running in
production. Let's change our container to use Chalk to launch our
workload, and report on the launch.

For this example, we leave the server config the same, and change the
default command to `exec`. We also add configuration to set the
executable to `/bin/hi` (which is where our `hi` command is placed in
the container).

Apply this config automatically with:

```bash
./calcite switch entry
```

To be clear, all we've changed from the default config that chalk ships with is:

```con4m
default_command: "exec"
exec.command_name: "/bin/hi"

sink_config demo_http_config {
  # The 'post' sink type is for HTTP and HTTPS posting.
  # Note that all the below quotes are required.
  sink: "post"
  uri:  "http://localhost:8585/report"
}
subscribe("report", "demo_http_config")
unsubscribe("report", "json_console_out")
```

Now, let's edit our Dockerfile. Comment out the first `ENTRYPOINT`
line, and uncomment the two lines at the bottom, then resave it.

Your Dockerfile should now look like this:

```dockerfile
FROM alpine
RUN apk add --no-cache pcre gcompat
WORKDIR /
COPY hi /bin/hi

# ENTRYPOINT ["/bin/hi"]
COPY bin/chalk /bin/chalk
ENTRYPOINT ["/bin/chalk"]
```

We need to rebuild the container, so that it picks up our new entry point:

```bash
docker build -t chalk-demo:latest .
```

Now, let's finally run the container. We'll have to add a flag to explicitly
allow it to connect back to localhost for this demo.

```bash
docker run --rm  --network="host" chalk-demo:latest
```

We get our 'hello world':
![hello](./img/hello.png){ loading=lazy }

Feel free to run it again to add some arguments, to see that they get
passed all the way through to the `hi` executable.

You should see that every time the container starts, the server gets a
report! Let's see what it gives us. We have a second endpoint in the
demo server to make it easy to see reported executions:

```bash
curl http://127.0.0.1:8585/execs
# for pretty json output if you have jq installed
curl http://127.0.0.1:8585/execs | jq
```

![serverout](./img/execout.png){ loading=lazy }

You can see that, in addition to artifact information, there is also
information about the operating environment, including the container
ID (the \_INSTANCE_ID key). We can also see a bunch of data about the
running executable prefixed with \_PROCESS.

And, in the near future, we'll be making it possible to configure
chalk to report runtime info on-demand, or on a pre-configured period
(right now, `chalk exec` reports at startup, and then exits).

Note that, in the default configuration for `chalk exec`, chalk
launches your process as the parent, and becomes the child. That
means, in a container, your workload is PID 1.

The downside there, is that when PID 1 dies, all processes in the
container die too. So if your workload is short-lived, `chalk` might
not report (this is why our demo program sleeps for a second before
exiting).

You can configure Chalk to be the parent if you like (which, might be
useful for getting your chalk reporter more permissions to the data
you want). We'll produce a document covering common configuration
options soon, where we will cover this.

You also can run 'chalk exec' outside of a container, if you want to
wrap stuff that doesn't run in a container to report on their
environment on startup.

You can configure a chalk binary to run one particular program by
default, but you can also specify a program on the command line. For
instance, let's run our `hi` binary from outside the container, but
using `chalk exec`:

```
./bin/chalk exec --exec-command-name=hi patient reader
```

Note that, any flags not explicitly recognized by chalk will get
passed on to the spawned process, as will any arguments.  But the
command name does need to be passed either in the --exec-command-name
flag, or in the config file.

Plus, note that 'chalk exec' does *not* invoke a command shell. It
leverages execve() under the hood, so if you feel you need shell
evaluation, you should exec the shell and pass any arguments you need.

## Coming Soon

We've got a significant roadmap in the works for Chalk. In the near
future, we'll make it so that you can automatically wrap container
entry points, instead of having to manually do it.

There's plenty more to come, including features specifically aimed to
help make it easier for developers to get the info they need about
their production environments when bugs get reported.

Meanwhile, have fun chalking.
