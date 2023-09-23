# How to keep track of your containers' network services

## Use Chalk to automatically create periodic reports on container network tables, or visibility into service availability

## Summary

Understanding which services run in containers can help you build a
service map, and Chalk provides a straight forward way to collect
network connection tables (think: like netstat) of a container for the
entire duration of its execution. This guide walks you through three
basic steps:

- Configure Chalk 
- Invoke Chalk to build a container
- Run the chalked container to see Chalk reporting in action

## When to use this

Service maps help you understand your environments, and knowing which
containers are deployed in the same network namespace/pods helps you
model how container services relate to each other. The steps in this
guide can be added to your CI/CD pipeline for container builds to add
network service reporting.

## Prerequisities

- docker

## Steps

### Before you start

Ensure you have the `chalk` program ready in your working
directory. You can download the [latest release
here](https://crashoverride.com/releases).

### Step 1: Configure Chalk

Let's install a ready-to-go starting configuration for this use case:

`chalk load https://chalkdust.io/net-heartbeat.c4m`

That command will load the configuration automatically, by rewriting
your chalk binary to use the new configuration on future startups.

By default, the configuration file we just installed will report
network information every 30 minutes, and will dump the heartbeat
reporting to `stdout`, which in many containerized environments will
funnel it into a logging system.

By default this configuration file is set to report network
information every 30 minutes, and the default output location for the
report is `stdout` (print to the screen).

These defaults may not be suitable for you, but changing this default
behavior is super easy!

First, let's have chalk dump this configuration to a file:

`chalk dump net-heartbeat.c4m`

Now open it up in your favorite editor, and we can tinker.

So that we don't have to wait 30 minutes to see results when we're
testing, let's modify the interval between heartbeats.  We're going to
modify the following line in the configuration:

```
exec.heartbeat_rate: <<30 minutes>>
```

For the sake of this guide we will set it to 10 seconds, so we can
demonstrate reporting without waiting too long:

```
exec.heartbeat_rate: <<10 seconds>>
```

Also, reporting output to `stdout` might not fit your
needs. Configuring that behavior is also trivial. Output behavior is
configured through `sink_config` blocks in the config file, and you
can see the default enabled one is named as `sink_config
output_to_screen`. Immediately following this you can see other
`sink_config` sections which are present but *disabled*. For example, to
setup reporting to an HTTP endpoint, change the `output_to_http`
config value `uri` to be a web endpoint of your choosing, and set that
output method to be `enabled: true` like so:

```
sink_config output_to_http {
  enabled: true
  sink:    "post"
  uri:     "http://some.web.location/webhook"
}
```

You may have noticed this configuration language looks a bit like
JSON, only a little friendlier for humans to write. It's actually a
new configuration language called
[con4m](https://github.com/crashappsec/con4m), which looks like a
typical configuration file, but is more powerful and less error prone
than popular solutions like YAML.

The sample config also contains a `sink_config` section for reporting
output to a file, but for the simplicity of this exercise, we will be
keeping the `stdout` option enabled for ease of demonstrating
functionality. (But feel free to go off script if you want try
different capabilities!)

You may also have seen that the metadata we're going to be collecting
about network configurations is in a `report_template` section named
`network_report`. That template is named in a `custom_report` section,
named `network_heartbeat_report`. This creates a report that
supplements Chalk's default reporting, with a report that contains
just the information we care about, which we can send anywhere we like.

So we are not in any way changing the out of the box reporting in this
recipe, just adding a new report to capture our network data! If you'd
prefer to just keep it all in one report, do check out our
configuration guide.

Once your config is ready, you load it into chalk by running:
`./chalk load net-heartbeat.c4m`

This will again re-write your binary to include the changes you've
made. Your binary is now configured, and ready for use.

The chalk binary in your current working directory is now configured
and ready for use.

### Step 2: Build your container with Chalk

For this demo we will need a `Dockerfile` in your working directory
for the container from which we will make a chalked container image,
and ideally one with a network service so we can see it in the
reporting output. To make it easy to follow along, you can pate the
following to automatically create the Dockerfile for this small
one-line Python HTTP server container in your current directory:

```
cat > DockerFile << EOF
FROM python
ENTRYPOINT ["python", "-m", "http.server", "9999"]
EOF
```

This example Dockerfile will launch a Python HTTP server listening on
port 9999, which we should expect to see in our network connection
table output from Chalk, once this container runs.

From there, to build your container with the Chalk configured to
report heartbeat information, run:

`./chalk docker build -t mychalkedcontainer .`

This builds a container called `mychalkedcontainer` with the network
reporting baked-in. This works by `chalk` copying itself into the
newly built container and invoking itself before the normal container
entrypoint. The chalked container is now ready to run with the
configured reporting.

> ❗This assumes you're not doing a multi-arch build, and that the
Dockerfile for the container doesn't specify a different architecture
than what you're currently running. While Chalk does support the
ability to build for other architectures, even across architectures,
for simplicity that's beyond the scope of this quick-start guide.

You should see some additional JSON output from `chalk` after the
build finishes, identifying the metadata information for the newly
chalked contianer:

```
[
  {
    "_OPERATION": "build",
    "_DATETIME": "2023-09-22T20:20:05.130+00:00",
    "_CHALKS": [
      {
        "DOCKERFILE_PATH": "/home/user/quickstart_guide/Dockerfile",
        "DOCKER_FILE": "from python\nentrypoint [\"python\", \"-m\", \"http.server\", \"9999\"]\n",
        "DOCKER_LABELS": {},
        "DOCKER_TAGS": [
          "mychalkedcontainer"
        ],
        "CHALK_ID": "RMZ2HA-J5EC-2K8D-SXZFCN",
        "CHALK_VERSION": "0.1.0",
        "METADATA_ID": "N3D0SH-94M4-GC8Z-TZR92B",
        "_VIRTUAL": false,
        "_IMAGE_ID": "cd016eb2bd35d397fc6618e44d6ba9675289485c3f86e44201bc8c123dc1512b",
        "_CURRENT_HASH": "cd016eb2bd35d397fc6618e44d6ba9675289485c3f86e44201bc8c123dc1512b"
      }
    ],
    "_ENV": {
      "PWD": "/home/user/quickstart_guide",
      "XDG_SESSION_TYPE": "tty",
      "USER": "user",
      "PATH": "/home/user/.nimble/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin:/home/user/.local/bin",
      "SSH_TTY": "/dev/pts/0"
    },
    "_OP_ARGV": [
      "/home/user/quickstart_guide/chalk",
      "docker",
      "build",
      "-t",
      "mychalkedcontainer",
      "."
    ],
    "_OP_CHALKER_VERSION": "0.1.1",
    "_OP_CHALK_COUNT": 1,
    "_OP_UNMARKED_COUNT": 0
  }

```

### Step 3: Run the container, see the report

If you built your container with the command provided in step 2, you
should be able to now run it with:
`docker run --rm -it mychalkedcontainer`

Also, if you kept the the `output_to_screen` sink to be `enabled:
true`, and set the heartbeat window to 10 seconds, then after 10
seconds you should see output similar to the following:

```
[
   {
      "_OPERATION" : "heartbeat",
      "_OP_HOSTINFO" : "#93-Ubuntu SMP Tue Sep 5 17:16:10 UTC 2023",
      "_OP_HOSTNAME" : "8ceb650f2714",
      "_OP_IPV4_ROUTES" : [
         [
            "0.0.0.0",
            "172.17.0.1",
            "0.0.0.0",
            "eth0",
            "0003",
            "0",
            "0",
            "0",
            "0",
            "0",
            "0"
         ],
         [
            "172.17.0.0",
            "0.0.0.0",
            "255.255.0.0",
            "eth0",
            "0001",
            "0",
            "0",
            "0",
            "0",
            "0",
            "0"
         ]
      ],
      "_OP_IPV6_ROUTES" : [
         [
            "0000:0000:0000:0000:0000:0000:0000:0000",
            "00",
            "0000:0000:0000:0000:0000:0000:0000:0000",
            "00",
            "0000:0000:0000:0000:0000:0000:0000:0000",
            "lo",
            "00200200",
            "00000001",
            "00000000",
            "ffffffff"
         ]
      ],
      "_OP_NODENAME" : "8ceb650f2714",
      "_OP_PLATFORM" : "GNU/Linux x86_64",
      "_OP_TCP_SOCKET_INFO" : [
         [
            "0.0.0.0",
            "9999",
            "0.0.0.0",
            "0",
            "LISTEN",
            "0",
            "27973"
         ]
      ],
      "_TIMESTAMP" : 1695414149440
   }
]

```

Here we can see JSON output showing the chalked container's listening
ports, which for the case of the sample Dockerfile containing the
one-line Python service is port 9999.

As a big red button once told me, "That was easy!"

Now, you can use the data however you like.

## Related HowTos
[The complete guide to network heartbeats with chalk](http://FIXME/LimingsDoc) 

## Background information
Traditionally platform engineers and ops teams would use tools like
`netstat` or `osquery` to collect this type of network table
information, but neither of these are designed to track and associate
build artifacts as part of your CI/CD pipeline like Chalk is. Also
tools like `netstat` and `osquery` can complicate your container
builds with library dependencies and bulky filesystem
footprints. Chalk is a single stand-alone static binary that carries
its config with it, and it already speaks the same language used by
Dockerfiles, so it integrates into Docker builds seamlessly.

This *How-To* on collecting network tables is just one example of the
value made available when you have a means of tracking and
understanding how your build artifacts relate to your repositories and
production environments. Chalk allows software engineers and platform
engineers to have mutual awareness and relatability of each others
roles across the broader organization, bridging a visibility gap
between how software is written and how it runs. (Not to mention the
benefits in visibility to security teams!)
