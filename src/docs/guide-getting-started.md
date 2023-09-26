# Getting Started with Chalk

Chalk is an observability tool that provides full lifecycle visibility
into your development process. Generally, you apply it at build time,
where it adds informational marks to software (`chalk marks`) and
reports about the software and the build environment. You can also
configure it to wrap workloads to report on them in production.

A design goal for chalk is that people deploying it shouldn't have to
do more than drop in a single chalk binary in the right place in their
CI/CD pipeline. In many cases, it can be completely transparent to
the user.

Any configuration should be done up-front by whoever needs the data
from chalk. While chalk is designed to be deeply customisable, we also
worked hard to make out-of-the-box configurations useful, and to make
it very easy to configure common usecases.

First, let's do some basics to get up and running, both with
chalking artifacts, and reporting on them in production.

## Chalk Binary

There are several ways to get the chalk binary.

### Downloading Chalk

The easiest way to get Chalk is to download a pre-built binary from
our [release page](https://crashoverride.com/releases). It's a
self-contained binary with no dependencies to install.

For this tutorial, please put it somewhere in your path where you have
write access. For example, if you downloaded chalk to your current
directory, you could do:

```bash
mkdir -p ~/.local/bin
mv chalk ~/.local/bin
export PATH=$PATH:~/.local/bin
```

This will put `chalk` in your path until you log out.


### Building From Source

Alternatively, you can build chalk from source. First, let's checkout the chalk repository:

```bash
git clone https://github.com/crashappsec/chalk.git && cd chalk
```

The easiest way to build Chalk requires docker and docker compose, and
will produce a Linux binary for your underlying architecture (so this
method will not produce a native binary on a Mac). First build the
image with:

```bash
docker compose build chalk
```

Then build chalk:
```bash
make chalk
```
(or `make debug` for a debug version).

There should now be a binary `chalk` in the current directory. Ensure
that it has built properly by running `./chalk` (moving it to a Linux
machine first if needed), which should open up the chalk help
documentation.

### Source Builds Without Docker

Currently, Chalk expects a Posix-compliant environment, and we
currently only develop and test on Linux and MacOS (though other
modern Unixes should work fine). We also only support amd64 and arm64.

On those environments, to build without Docker, you must have a C
compiler toolchain installed.

The only other dependency is Nim 2.0, which can be easily installed
via the `choosenim` installer:

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

Once you've done that, you will need to add the toolchain to your
path, and then should be able to build chalk:

```bash
export PATH=$PATH:~/.nimble/bin
nimble build
```

## First Run

In this section, we will run `chalk` to insert a chalk mark on a
sample binary and then examine the results.

### Creating A Local Repository

Let's try to give this as much of the flavor of a real project as
possible, by creating a local repository:

```bash
mkdir chalktest
cd chalktest
git init
```

We will populate `chalktest` with a binary to use for testing, which will need a C compiler. If you don't have one, skip to [Copying A Sample Binary](#copying-a-sample-binary).

#### Creating a Sample Binary

Now, if you've got a C compiler, let's add some source code for our
implementation of `ls`, which will do nothing but call out to the
real `ls` command:

```bash
export LSPATH=`which ls`
cat > lswrapper.c << EOF
#include <unistd.h>
int
main(int argc, char *argv[], char *envp[]) {
  execve("${LSPATH}", argv, envp);
  return -1;
}  

EOF
printf 'all:\n\tcc -o ls lswrapper.c\n' > Makefile
```

You can, if you like, commit our project:

```bash
git add *
git commit -am "Chalk demo 1"
```

Now, assuming you have a C compiler, build and run your `ls` command:

```bash
make
./ls
```

You should see:
```bash
Makefile	ls		lswrapper.c
```

#### Copying a Sample Binary

If you're on a Linux system without a C compiler, that's okay,
too. For the sake of example, instead of actually running the build,
you can pretend we did one by copying over the system binary:

```
cp `which ls` .
```

### Chalk Insertion

Now that we have a reasonable test environment, let's add our first
chalk mark:

```bash
chalk insert ls
```

We should see something like the following output:
```bash
warn:  Code signing not initialized. Run `chalk setup` to fix.
info:  /home/liming/workspace/chalktest/ls: chalk mark successfully added
info:  /home/liming/.local/chalk/chalk.log: Open (sink conf='default_out')
info:  Full chalk report appended to: ~/.local/chalk/chalk.log
[
  {
    "_OPERATION": "insert",
    "_DATETIME": "2023-09-23T12:42:02.326-04:00",
    "_CHALKS": [
      {
        "PRE_CHALK_HASH": "c96756d855f432872103f6f68aef4fe44ec5c8cb2eab9940f4b7adb10646b90a",
        "CHALK_ID": "64V66C-V36G-TK8D-HJCSHK",
        "PATH_WHEN_CHALKED": "/home/liming/workspace/chalktest/ls",
        "ARTIFACT_TYPE": "ELF",
        "ORIGIN_URI": "local",
        "COMMIT_ID": "5f89bf133d4ca803f2b5ed24ccfe1feff7e11f6b",
        "BRANCH": "main",
        "CHALK_VERSION": "0.1.1",
        "METADATA_ID": "XYJKNQ-DRYK-181P-YS3S7R",
        "_VIRTUAL": false,
        "_CURRENT_HASH": "c96756d855f432872103f6f68aef4fe44ec5c8cb2eab9940f4b7adb10646b90a"
      }
    ],
    "_ENV": {
      "PWD": "/home/liming/workspace/chalktest",
      "XDG_SESSION_TYPE": "wayland",
      "AWS_SECRET_ACCESS_KEY": "<<redact>>",
      "USER": "liming",
      "PATH": "/home/liming/workspace/chalktest/config-tool/dist:/home/liming/workspace/chalktest/bin:/home/liming/workspace/chalktest:/home/liming/.local/bin:/home/liming/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin:/snap/bin:/usr/local/go/bin:/usr/local/go/bin"
    },
    "_OP_ARGV": [
      "/home/liming/workspace/chalktest/chalk",
      "insert",
      "ls"      
    ],
    "_OP_CHALKER_VERSION": "0.1.1",
    "_OP_CHALK_COUNT": 1,
    "_OP_UNMARKED_COUNT": 0
  }
]
```

By default, `chalk` will print an abbreviated "summary" chalk report
to terminal (the JSON blob seen above), and the full chalk report to
the log file specified at `~/.local/chalk/chalk.log`. Both the
contents of the chalk reports and the locations to which they are sent
are highly customizable, and more information on custom configurations
can be found in our configuration guide.

Compare the default summary chalk report to the default chalk report
in the log file, which is a bit more verbose. We can view the log by
running:

```bash
cat ~/.local/chalk/chalk.log
# If you have jq, pretty print w/ cat ~/.local/chalk/chalk.log | jq
```

The chalk report is metadata collected about the artifact(s) that have
been chalked and the host environment. Here are a few important things
to note for now:

1. We've captured basic information about the build environment,
including our repo, branch and commit ID. If you pull a repo remotely
from Github or Gitlab, the "ORIGIN_URI" key will give the URL where
the repository is hosted, instead of `local`.

2. In addition to the report, we inserted a JSON blob into our
executable, the _chalk mark_. We'll look at it in a minute.

3. The `CHALK_ID` key is unique to the _unchalked_ executable, and is just an encoding of 100 bits of the `HASH` field.

If we had left off the file name, chalk would have attempted to insert
chalk marks on all eligible artifacts in the current directory
(recursively).

Git it a shot:

```bash
chalk insert
```

You'll see the output is very similar. However, if you created a git
project, the `.git` directory will actually have some shell scripts
added to it, and they did NOT get chalked.

That's because, by default, `chalk` will skip all dot directories in
your current directory, and will refuse to chalk itself.

### Chalk Extraction

Let's see what's actually in that `ls` binary we just added. We can
have chalk report on what it inserted into artifacts:

```bash
./chalk extract ls
```

This will output a chalk report on `ls`:
```json
liming@liming-virtual-machine:~/workspace/chalktest$ ./chalk extract ls
warn:  Code signing not initialized. Run `chalk setup` to fix.
info:  /home/liming/workspace/chalktest/ls: Chalk mark extracted
info:  /home/liming/.local/chalk/chalk.log: Open (sink conf='default_out')
info:  Full chalk report appended to: ~/.local/chalk/chalk.log
[
  {
    "_OPERATION": "extract",
    "_DATETIME": "2023-09-23T12:42:28.654-04:00",
    "_CHALKS": [
      {
        "CHALK_ID": "64V66C-V36G-TK8D-HJCSHK",
        "CHALK_VERSION": "0.1.1",
        "ARTIFACT_TYPE": "ELF",
        "BRANCH": "main",
        "COMMIT_ID": "5f89bf133d4ca803f2b5ed24ccfe1feff7e11f6b",
        "ORIGIN_URI": "local",
        "METADATA_ID": "XYJKNQ-DRYK-181P-YS3S7R",
        "_OP_ARTIFACT_PATH": "/home/liming/workspace/chalktest/ls",
        "_OP_ARTIFACT_TYPE": "ELF",
        "_CURRENT_HASH": "3c8f7e50fe9d640a1409067bb9f3888f5d5aa9aeca02cbb1db4617d47866505d"
      }
    ],
    "_ENV": {
      "PWD": "/home/liming/workspace/chalktest",
      "XDG_SESSION_TYPE": "wayland",
      "AWS_SECRET_ACCESS_KEY": "<<redact>>",
      "USER": "liming",
      "PATH": "/home/liming/workspace/chalktest/config-tool/dist:/home/liming/workspace/chalktest/bin:/home/liming/workspace/chalktest:/home/liming/.local/bin:/home/liming/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin:/snap/bin:/usr/local/go/bin:/usr/local/go/bin"
    },
    "_OP_ARGV": [
      "/home/liming/workspace/chalktest/chalk",
      "extract",
      "ls"
    ],
    "_OP_CHALKER_VERSION": "0.1.1",
    "_OP_CHALK_COUNT": 1,
    "_OP_UNMARKED_COUNT": 0
  }
]
```

And the full report is once again in `~/.local/chalk/chalk.log`.

Alternatively, to extract all chalk marks from the artifacts in the
directory, we can run:

```bash
./bin/chalk extract
```

Here, you'll get some warnings on stderr about items in .git not being
chalked. By default, chalk doesn't go into .git directories for
insertion, but it does for reporting, just to avoid missing items that
are chalked when we're reporting.

Some of the things reported on were found in the actual artifacts. But
a lot of the reporting is about the operational environment at the
time of the extract. For instance, the `_ENV` field is an array of the
environment variables present in the host a the time of extraction.

In all contexts, metadata keys starting with an underscore (`_`)
indicate metadata associated with the current operation we're
performing. Without the underscore, it refers to info from the time of
chalking.

### Raw Chalk Marks

If we want to see how the chalk marks look in our software, run the command:

```bash
strings ls | grep MAGIC
```

You'll see there's an embedded JSON string in the `ls` binary, which is the chalk mark:
```json
{ "MAGIC" : "dadfedabbadabbed", "CHALK_ID" : "64V66C-V36G-TK8D-HJCSHK", "CHALK_VERSION" : "0.1.1", "TIMESTAMP_WHEN_CHALKED" : 1695487268282, "DATETIME_WHEN_CHALKED" : "2023-09-23T12:41:08.124-04:00", "ARTIFACT_TYPE" : "ELF", "BRANCH" : "main", "CHALK_RAND" : "049d278b2137c27d", "CODE_OWNERS" : "* @viega\n", "COMMIT_ID" : "5f89bf133d4ca803f2b5ed24ccfe1feff7e11f6b", "HASH" : "16c3c45462fc89d7fcc84c3749cb0900bdd1052f760ebd7cea1ab3956ad7326f", "INJECTOR_COMMIT_ID" : "f48980a19298ce27d9584baa1f7dd0fed715ef56", "ORIGIN_URI" : "local", "PLATFORM_WHEN_CHALKED" : "GNU/Linux x86_64", "METADATA_ID" : "WFAEY0-D2S3-WK98-SEAV85" }
```

Chalk marks are data segments that are safely inserted into the binary
that don't impact it in any way. Note that the `CHALK_ID` in the chalk
mark is the same as the one from the `insert` and `extract`
operations; the `CHALK_ID` can be used to correlate chalk marks across
reports.

## Sending the Data Somewhere

In this example, there's more metadata in the chalk mark than we'd
typically store. Chalk put more data into the mark itself, because it
didn't send its reports anywhere (except stdout). If we're sending
data somewhere, it really only needs to insert enough data to look up
the artifact in a database.

We've provided a test server that uses an SQLite database in the
backend that you can use. This can be built and run from the
repository root.

First build the server image with docker compose:
```bash
docker compose build server
```

The server will run on port 8585 by default, so ensure that this port
is not taken by another process before running the server. To start
the server, run:
```bash
make server
```

**Please Note - it does NOT run in the background, so you should
  either start a second shell, or manually background the server
  process. Starting in a separate shell is recommended so that you can
  observe the server output**.

Note that the server can be configured to use HTTPS, yet we've left it
unconfigured for demo simplicity. Please be mindful of this when
testing.

Now that we have our server running, we need to configure chalk to use
that server. We can do this by loading a chalk configuration file that
has an http sink configured. We have a sample that configures chalk to
output to localhost:8585, which you can load via:

```bash
chalk load https://chalkdust.io/demo-http.c4m
```

Now, let's delete existing chalk marks with:

```bash
chalk delete
```

On the terminal where we run our chalk command, we see:

```bash
info:  Post 200 OK (sink conf='demo_http_config')
```

Also, the web server should show a successful POST to `/report` as follows:

```bash
INFO:     uvicorn.access       172.19.0.1:40466 - "POST /report HTTP/1.1" 200
```

### Viewing chalk data

Let's go ahead and re-chalk our test binary:

```bash
chalk insert ls
```

On submission of new chalks, your server should now report:

```bash
INFO:     uvicorn.access       172.19.0.1:39582 - "POST /report HTTP/1.1" 200
```

Those chalk marks have been recorded in our SQLite database. You can connect to the database with any SQLite shell, but we have an endpoint that will allow you to dump the server's info from the chalk insertion operation. To see this pretty-printed:

```bash
curl http://127.0.0.1:8585/chalks | jq
# Drop the | jq if you don't have it installed, but then it'll be ugly!
curl http://127.0.0.1:8585/chalks
```

The latest insertion will be at the bottom:
```json
  {
    "CHALK_ID": "64V66C-V36G-TK8D-HJCSHK",
    "HASH": "16c3c45462fc89d7fcc84c3749cb0900bdd1052f760ebd7cea1ab3956ad7326f",
    "PATH_WHEN_CHALKED": "/home/liming/workspace/chalktest/ls",
    "ARTIFACT_TYPE": "ELF",
    "CODE_OWNERS": "* @viega\n",
    "VCS_DIR_WHEN_CHALKED": "/home/liming/workspace/chalktest",
    "ORIGIN_URI": "local",
    "COMMIT_ID": "5f89bf133d4ca803f2b5ed24ccfe1feff7e11f6b",
    "BRANCH": "main",
    "CHALK_VERSION": "0.1.1",
    "CHALK_RAND": "02fb17e5e1694baf",
    "METADATA_HASH": "f2a1fc1300e98d61674f6a06144125901134f6c34748a8b6b5aa37bf9d911ef0",
    "METADATA_ID": "YAGZR4-R0X6-6P2S-TFD831",
    "_VIRTUAL": false,
    "_OP_ARTIFACT_TYPE": "ELF",
    "_CURRENT_HASH": "c96756d855f432872103f6f68aef4fe44ec5c8cb2eab9940f4b7adb10646b90a",
    "_OPERATION": "insert",
    "_TIMESTAMP": 1695487471882,
    "_DATETIME": "2023-09-23T12:44:31.882-04:00",
    "INJECTOR_ARGV": [
      "ls"
    ],
    "INJECTOR_COMMIT_ID": "f48980a19298ce27d9584baa1f7dd0fed715ef56",
    "INJECTOR_ENV": {
      "PWD": "/home/liming/workspace/chalktest",
      "XDG_SESSION_TYPE": "wayland",
      "AWS_SECRET_ACCESS_KEY": "<<redact>>",
      "USER": "liming",
      "PATH": "/home/liming/workspace/chalktest/config-tool/dist:/home/liming/workspace/chalktest/bin:/home/liming/workspace/chalktest:/home/liming/.local/bin:/home/liming/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin:/snap/bin:/usr/local/go/bin:/usr/local/go/bin"
    },
    "INJECTOR_VERSION": "0.1.1",
    "PLATFORM_WHEN_CHALKED": "GNU/Linux x86_64",
    "_ACTION_ID": "8c87b883793695a1",
    "_ARGV": [
      "ls"
    ],
    "_ENV": {
      "PWD": "/home/liming/workspace/chalktest",
      "XDG_SESSION_TYPE": "wayland",
      "AWS_SECRET_ACCESS_KEY": "<<redact>>",
      "USER": "liming",
      "PATH": "/home/liming/workspace/chalktest/config-tool/dist:/home/liming/workspace/chalktest/bin:/home/liming/workspace/chalktest:/home/liming/.local/bin:/home/liming/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin:/snap/bin:/usr/local/go/bin:/usr/local/go/bin"
    },
    "_OP_ARGV": [
      "/home/liming/workspace/chalktest/chalk",
      "insert",
      "ls"
    ],
    "_OP_CHALKER_COMMIT_ID": "f48980a19298ce27d9584baa1f7dd0fed715ef56",
    "_OP_CHALKER_VERSION": "0.1.1",
    "_OP_CMD_FLAGS": [],
    "_OP_EXE_NAME": "chalk",
    "_OP_EXE_PATH": "/home/liming/workspace/chalktest",
    "_OP_HOSTINFO": "#32~22.04.1-Ubuntu SMP PREEMPT_DYNAMIC Fri Aug 18 10:40:13 UTC 2",
    "_OP_HOSTNAME": "liming-virtual-machine",
    "_OP_NODENAME": "liming-virtual-machine",
    "_OP_PLATFORM": "GNU/Linux x86_64",
    "_OP_SEARCH_PATH": [
      "ls"
    ],
    "_OP_CHALK_COUNT": 1,
    "_OP_UNMARKED_COUNT": 0
  }
```

### Basic Configurations

Let's examine the configuration file we have loaded for the server output.

First, we can write the configuration to a file can view it:

```bash
chalk dump demo-http.c4m
cat demo-http.c4m
```

You should see:
```
sink_config demo_http_config {
  # The 'post' sink type is for HTTP and HTTPS posting.
  # Note that all the below quotes are required.
  sink: "post"                  
  uri:  "http://localhost:8585/report"
}

subscribe("report", "demo_http_config")
unsubscribe("report", "default_out")
```

The configuration language is called [con4m](https://github.com/crashappsec/con4m).

In this case, the http config does three things:
1. It adds a 'sink configuration', specifying where to post (e.g., to a web endpoint, an S3 bucket, or a rotating log file).
2. It subscribes this configuration to the primary report produced by the command (the report that has been going to our log file).
3. It removes the builtin subscription that causes the default report to go to the log file (note that this is different from the terminal summary report, which should still display).

If we want to make changes to the configuration (for instance, you
might change 'localhost' to a valid host name so you can push to your
server from other machine) we can use chalk's `load` command, passing
it the file name of our edited config. That will test the config and
show us what it installed (or throw an error if the config is not
valid).

When in doubt, we can always return chalk to its default configuration. Let's try that now by running:
```bash
chalk load default
```

You might notice that, when `chalk load` ran above, the web server
reported a POST action. This is because he `chalk load` command is
implemented by a chalk binary chalking itself, and the previous
configuration (`demo-http.c4m`) had the http sink still enabled for
reporting. Note that any further chalk operations, now that the
default configuration is loaded, will NOT show up on the server, as
the default configuration does not have the http sink enabled.

But if we really want to validate that we have the correct
configuration loaded, we can run `chalk dump` again, but this time
without specifying a file name (which will just print to stdout):

```bash
chalk dump
```

Youu should see:

```bash
# The default config is empty. Please see chalk documentation for examples.
```

Let's reload the http config so that we can send chalks to the server
again, but from our local file (especially if you changed the
configuration at all):

```bash
chalk load demo-http.c4m
```

## Chalking a Container

We can use chalk to mark container images by using chalk to wrap our
docker commands. For this one, let's write a silly shell script to use
as a docker container.

We'll have it wait 10 seconds, then output either the arguments passed
to it, or else "Hello, world", and then exit:

```bash
cat > hi.sh << EOF
sleep 10
echo ${@:-Hello, world}
EOF
chmod +x hi.sh
```

Let's run it and make sure it works:
```bash
./hi.sh
```

After 10 seconds, you should see "Hello world", as expected.

We want at least a short pause because we want to make sure the
container has time to start up and report for us; if a container
entrypoint exits, it's like an entire machine exiting, and our
reporting can be stopped before it's finished.

A second would be enough to ensure we report, but we'll go a little
longer just for the sake of demoing some other stuff later.

Now we need a Dockerfile for our amazing project:

```bash
cat > Dockerfile << EOF
FROM alpine
COPY hi.sh /hi.sh
ENTRYPOINT ["/hi.sh"]
EOF
```

Now, we could build this by `wrapping` it with chalk. We just put the
word `chalk` in front of the docker command we'd normally use.

The problem with that is people then have to remember to add `chalk`
in front of all their docker operations. We can easily make the 
chalking process automatic if we just tell `chalk` that, if it doesn't 
see any other `chalk` command, it should impersonate docker; then we
can add either a user alias or a system-wide alias, and chalk will do 
the right thing when it's invoked.

Impersonation is set up simply by telling your Chalk binary that its
default chalk command should be `docker`. When you run `chalk docker`,
Chalk considers `docker` one of its own commands, and when it runs, it
both runs the Docker operation you wanted, and it does its data
collection and marking when appropriate.

Let's load a variant of the above demo config that still reports over
http, but has two other changes:

1. It sets the default command to `docker`
2. It removes the summary report.

```bash
chalk load https://chalkdust.io/demo-docker.c4m
```

If you want to edit the contents to change the server address from
localhost to a real IP, you can go ahead and do so.

Chalk is smart about masquerading as docker; so long as the *real*
docker appears anywhere in your path, it will find it and run it.

This means, if you would like to not even have to worry about an
alias, you could name your chalk binary `docker` and stick it higher
up in the default path than the *real* docker, and everything will
just work (or you can take Docker out of your path completely and
configure Chalk to tell it where docker lives).

But for this demo, let's just do the alias:

```bash
alias docker=chalk
```
Assuming you have docker installed and configured, you can now run:

```bash
docker build -t chalk-demo:latest .
```

You should be able to see that, even though there's no more summary
report being printed, the full report of what happened still went to
our server. That report will indicate the container was successfully
chalked:

```
INFO:     uvicorn.access       172.19.0.1:44046 - "POST /report HTTP/1.1" 200
```

But from the command line, what you see will look mostly like it would
if you hadn't used Chalk:

```bash
[+] Building 0.0s (7/7) FINISHED                                                                                         docker:default
 => [internal] load build definition from chalk-tsZTehBK-file.tmp                                                                  0.0s
 => => transferring dockerfile: 363B                                                                                               0.0s
 => [internal] load .dockerignore                                                                                                  0.0s
 => => transferring context: 130B                                                                                                  0.0s
 => [internal] load metadata for docker.io/library/alpine:latest                                                                   0.0s
 => [internal] load build context                                                                                                  0.0s
 => => transferring context: 254B                                                                                                  0.0s
 => CACHED [1/2] FROM docker.io/library/alpine                                                                                     0.0s
 => [2/2] COPY chalk-DIkeL7rO-file.tmp  /chalk.json                                                                                0.0s
 => exporting to image                                                                                                             0.0s
 => => exporting layers                                                                                                            0.0s
 => => writing image sha256:9f23f7871afd26d36e307a6e742225dfeec6b2857b36c6596565f1496ba0238a                                       0.0s
 => => naming to docker.io/library/chalk-demo:latest                                                                               0.0s
 ```

The only slight difference is that, after the user's Dockerfile
commands, we copied the chalk mark into the container, which does show
up in the above output.


If we inspect the image we produced:

```bash
docker inspect chalk-demo:latest
```

You'll also notice we automatically added three labels to the
container to help make it easy to look at any container in production,
and tie it back to how it was built:

```
    "Labels": {
        "run.crashoverride.branch": "main",
        "run.crashoverride.commit-id": "9b42c7ea1e24cf8c139703d3f0af7dadab272cd7",
        "run.crashoverride.origin-uri": "local"
    }
```

Again, the origin-uri will generally be a URL if you cloned or pulled
the repo. The other two fields tell you exactly which version of the
code you're running.

> 🤗 It's also easy to get Chalk to automatically sign the chalk mark
  and container when you build it. See our compliance guide for more
  information.


Chalk really only monitors a subset of docker commands, but when
wrapping docker, it will pass through all docker commands even if it
doesn't do any of its own processing on them. If chalk encoounters an
error while attempting to wrap docker, it will then execute the
underlying docker command without chalk so that this doesn't break any
pre-existing pipelines.

## Run-time reporting

> ⚠️ This section will not work as-is on OS X, since Docker is running
  a different OS from your chalk binary; dealing with that is beyond
  the scope of this tutorial.

So far, we've focused on ease of adding chalk marks. But chalk's goal
is to bridge code managed in repositories to what's running in
production. Let's change our container to use chalk to launch our
workload and report on the launch.

For that, let's load another configuration, which is the same as our
previous one, except that it also "wraps" the container's entrypoint.

That means, when your container builds, chalk will set up the
container so that the entry point you gave it is still PID 1, but
will also spawn a `chalk` process that reports metadata about the
operational environment whenever the container starts up.

The configuration for where the report goes is taken from your chalk
binary. Chalk will simply copy itself into the container and have
that binary do the reporting.

> 🤖 Chalk does not need to be reconfigured to go into the
   container. It gets run using the `chalk exec` command, which tells
   it the context it needs. It's possible to change how you report
   based on the chalk command used; see the Chalk I/O configuration
   guide for more info.

Let's apply this config automatically with:

```bash
chalk load https://chalkdust.io/demo-wrap.c4m
```

We simply need to rebuild the container to cause Chalk to wrap:

```bash
docker build -t chalk-demo:latest .
```

Now, let's finally run the container. If you're running everything
locally, Docker does require that we add a flag to explicitly allow us
to connect back to localhost for this demo.

```bash
docker run --rm -it --network="host" chalk-demo:latest
```

We get our 'hello world':
![hello](./img/hello.png){ loading=lazy }

Feel free to run it again to add some arguments to see that they get
passed all the way through to the `hi.sh` script.

You should see that every time the container starts, the server gets a
report! Let's see what it gives us. We have a second endpoint in the
demo server to make it easy to see reported executions:

```bash
curl http://127.0.0.1:8585/execs
# for pretty json output if you have jq installed, run `curl http://127.0.0.1:8585/execs | jq`
```

![serverout](./img/execout.png){ loading=lazy }

You can see that, in addition to artifact information, there is also
information about the operating environment, including the container
ID (the `_INSTANCE_ID` key). We can also see a bunch of data about the
running executable prefixed with `_PROCESS`.

You can also configure Chalk to periodically report back on
environment information. See our heartbeat guide for that.
