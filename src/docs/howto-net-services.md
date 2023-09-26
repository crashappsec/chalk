# Create network services visibility reports from containers

## Use Chalk to create periodic reports about the status of container network tables

## Summary

Observability is a core tenant of devops. Understanding which services run in a container during the lifetime of its execution, and therefore creating a service map, is a key part of observability for containers.

You can do this with shell commands like `netstat`, doing this across your container fleet and storing the results in a central location can require a lot of setup.

This how-to uses Chalk™ to automate this in two easy steps:

1. Configure chalk to collect network services data from your containers and generate chalk reports
2. Add chalk to all of your containers so that it generates network services visibility reports during the containers execution lifetime

## Steps

### Before you start

The easiest way to get Chalk is to download a pre-built binary from
our [release page](https://crashoverride.com/releases). It's a
self-contained binary with no dependencies to install.

### Step 1: Configure chalk to collect network services data from your containers

This how-to uses chalk configuration files to make setup easy. To load the configuration file for this how-to, in your terminal type:

```bash
chalk load https://chalkdust.io/net-heartbeat.c4m
```

This command rewrites
your chalk binary to use the new configuration on every future run.

By default, the configuration file we just installed will report
network information every 30 minutes, and will dump the heartbeat
reporting to `stdout`, which in many containerized environments will
funnel it into a logging system.

These defaults may not be suitable for you, changing it is easy.

First, let's have chalk dump this configuration to a file. In your terminal type:

`chalk dump net-heartbeat.c4m`

Open the file net-heartbeats.cn4m in your editor.

So that we don't have to wait 30 minutes to see results when we're
testing, let's modify the interval between heartbeats. Change the exec.heartbeat_rate line in the configuration from

```con4m
exec.heartbeat_rate: <<30 minutes>>
```

to

```con4m
exec.heartbeat_rate: <<10 seconds>>
```

You might want to also change the reporting output from `stdout`. Output behavior is
configured through `sink_config` blocks in the config file, and you
can see the default enabled one is named as `sink_config
output_to_screen`. Immediately following this you can see other
`sink_config` sections which are present but _disabled_. For example, to
setup reporting to an HTTP endpoint, change the `output_to_http`
config value `uri` to be a web endpoint of your choosing, and set that
output method to be `enabled: true` like so:

```con4m
sink_config output_to_http {
  enabled: true
  sink:    "post"
  uri:     "http://some.web.location/webhook"
}
```

Chalk uses configuration files written using [con4m](https://github.com/crashappsec/con4m), a configuration language we created to make it easy to setup metadata collection.

The sample config also contains a `sink_config` section for reporting
output to a file, but for the simplicity of this exercise, we will be
keeping the `stdout` option enabled for ease of demonstrating
functionality. Feel free to go off script if you want try
different capabilities!

You may also have seen that the metadata we're going to be collecting
about network configurations is in a `report_template` section named
`network_report`. That template is named in a `custom_report` section,
named `network_heartbeat_report`. This creates a report that
supplements chalk default reporting, with a report that just contains the services visibility information, making it easier to send just this high value signal (and not all the other noise) to people that need that.

Once your config is ready, you load it into chalk by running:

```bash
./chalk load net-heartbeat.c4m
```

This will again re-write your binary to include the changes you've
made.

### Step 2: Add chalk to all of your containers so that it generates network services visibility reports during the containers execution lifetime

For this how-to we will need a `Dockerfile` in your working directory
for the container from which we will make a chalked container image,
and ideally one with a network service so we can see it in the
reporting output. To make it easy to follow along, you can pate the
following to automatically create the Dockerfile for this small
one-line Python HTTP server container in your current directory:

```bash
cat > Dockerfile << EOF
FROM python
ENTRYPOINT ["python", "-m", "http.server", "9999"]
EOF
```

This example Dockerfile will launch a Python HTTP server listening on
port 9999, which we should expect to see in our network connection
table output from Chalk, once this container runs.

From there, to build your container with the Chalk configured to
report heartbeat information, run:

```bash
./chalk docker build -t mychalkedcontainer .
```

This builds a container called `mychalkedcontainer` with the network
reporting baked-in. This works by `chalk` copying itself into the
newly built container and invoking itself before the normal container
entrypoint. The chalked container is now ready to run with the
configured reporting.

> ❗This assumes you're not doing a multi-arch build, and that the
> Dockerfile for the container doesn't specify a different architecture
> than what you're currently running. While Chalk does support the
> ability to build for other architectures, even across architectures,
> for simplicity that's beyond the scope of this quick-start guide.

You should see some additional JSON output from `chalk` after the
build finishes, identifying the metadata information for the newly
chalked contianer:

```json
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

If you built your container with the commands above, you should now be able to now run it with:
`docker run --rm -it mychalkedcontainer`

Also, if you kept the the `output_to_screen` sink to be `enabled:
true`, and set the heartbeat window to 10 seconds, then after 10
seconds you should see output similar to the following:

```json
[
  {
    "_OPERATION": "heartbeat",
    "_OP_HOSTINFO": "#93-Ubuntu SMP Tue Sep 5 17:16:10 UTC 2023",
    "_OP_HOSTNAME": "8ceb650f2714",
    "_OP_IPV4_ROUTES": [
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
    "_OP_IPV6_ROUTES": [
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
    "_OP_NODENAME": "8ceb650f2714",
    "_OP_PLATFORM": "GNU/Linux x86_64",
    "_OP_TCP_SOCKET_INFO": [
      ["0.0.0.0", "9999", "0.0.0.0", "0", "LISTEN", "0", "27973"]
    ],
    "_TIMESTAMP": 1695414149440
  }
]
```

Here we can see JSON output showing the chalked container's listening
ports, which for the case of the sample Dockerfile containing the
one-line Python service is port 9999.

As a big red button once told me, "That was easy!" Now, you can use the data however you like.

## Our cloud platform

While creating container network services visibility reports with chalk is easy, our cloud platform makes it even easier. It is designed for enterprise deployments, and provides additional functionality including prebuilt configurations to solve common tasks, prebuilt integrations to enrich your data, a built-in query editor, an API and more.

There are both free and paid plans. You can [join the waiting list](https://crashoverride.com/join-the-waiting-list) for early access.

## Related how-tos

[The complete guide to network heartbeats with chalk](/src/docs/guide-heartbeat.md)

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

This _How-To_ on collecting network tables is just one example of the
value made available when you have a means of tracking and
understanding how your build artifacts relate to your repositories and
production environments. Chalk allows software engineers and platform
engineers to have mutual awareness and relatability of each others
roles across the broader organization, bridging a visibility gap
between how software is written and how it runs. (Not to mention the
benefits in visibility to security teams!)
