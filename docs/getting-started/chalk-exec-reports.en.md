# Using Chalk Exec Reports: A Fundamental Guide

## Introduction

Chalk's `exec` command is a powerful feature that allows you to gather runtime information about
your applications as they execute. This capability creates a bridge between the build-time metadata
collected during insertion operations and the actual runtime behavior of your software. With
`chalk exec`, you can launch a program while simultaneously collecting information about its
execution environment, process details, and system state.

This guide will walk you through the fundamentals of using `chalk exec` reports with simple examples
that demonstrate the core concepts. We will explore how to execute programs with Chalk, understand
the reports generated, configure reporting behavior, and set up periodic heartbeat monitoring.

## Understanding `chalk exec`

At its core, `chalk exec` does two main things:

1. It launches a specified program (similar to how you would runn it directly)
2. It generates a report containing information about the program's runtime environment

Unlike the `insert` and `extract` commands that focus on metadata within artifacts, `exec` focuses
on capturing details about the execution context. This is particularly valuable for applications
running in production environments, container orchestration systems, or any scenario where you need
visibility into runtime behavior.

## Basic Usage: Executing a Simple Program

Let's start with a simple example by running a basic Bash program with `chalk exec`.

### Running a Simple Command

Create a simple shell script that we'll execute with Chalk:

```bash
# Create a file named hello.sh
cat EOF > hello.sh
#!/bin/bash
echo "Hello, Chalk!"
sleep 5  # Give Chalk time to collect data
echo "Goodbye, Chalk!"
FOE

# Make it executable
chmod +x hello.sh
```

Now, let's run it by using `chalk exec`:

```bash
chalk exec --exec-command-name=./hello.sh
```

You should see your script's output interleaved with Chalk's report:

```
Hello, Chalk!
[
  {
    "_OPERATION": "exec",
    "_DATETIME": "2024-03-05T14:35:22.781-05:00",
    "_CHALKS": [
      {
        "_PROCESS_PID": 12345,
        "_PROCESS_COMMAND_NAME": "bash",
        "_PROCESS_EXE_PATH": "/bin/bash",
        "_PROCESS_ARGV": ["./hello.sh"],
        ... (more process information)
      }
    ],
    "_ENV": {
      ... (environment variables)
    },
    ... (more metadata)
  }
]
Goodbye, Chalk!
```

This report contains information about the process that was started, including its process ID,
command name, executable path, and arguments. It also includes details about the host environment.

### Understanding What's Happening

When you run `chalk exec`, Chalk:

1. Starts the program you specified
2. Collects information about the process and environment
3. Generates a report with this information and,
4. By default, continues running your program as normal

The program itself runs exactly as it would without Chalk, but you get the additional benefit of
Chalk's reporting capabilities.

## Examining the Exec Report

Let's look at some of the key information provided in a `chalk exec` report:

### Process Information

- `_PROCESS_PID`: The process ID of the running program
- `_PROCESS_COMMAND_NAME`: The name of the command being executed
- `_PROCESS_EXE_PATH`: The path to the executable
- `_PROCESS_ARGV`: The arguments passed to the program
- `_PROCESS_CWD`: The current working directory
- `_PROCESS_STATE`: The state of the process (running, sleeping, etc.)

### Environment Information

- `_ENV`: Environment variables available to the process
- `_OP_HOSTNAME`: The hostname of the machine
- `_OP_PLATFORM`: The operating system and architecture

### Timing Information

- `_TIMESTAMP`: When the report was generated
- `_DATETIME`: Human-readable datetime of the report

For chalked applications, the report will also include the original chalk mark information,
establishing a connection between build-time and runtime.

## Advanced Example: Heartbeat Monitoring

One of the most powerful features of `chalk exec` is its ability to generate periodic "heartbeat"
reports that continue for as long as your application runs.

### Setting Up Heartbeat Monitoring

Let's first create a configuration file that enables heartbeat reporting:

```bash
# Create a heartbeat configuration file
cat << EOF > heartbeat-config.c4m
# Enable heartbeat and set interval to 10 seconds
exec.heartbeat: true
exec.heartbeat_rate: <<10 seconds>>

# Define what to include in heartbeat reports
report_template heartbeat_report {
  key._PROCESS_PID.use                        = true
  key._PROCESS_STATE.use                      = true
  key._PROCESS_CWD.use                        = true
  key._OP_TCP_SOCKET_INFO.use                 = true
  key._TIMESTAMP.use                          = true
  key._DATETIME.use                           = true
}

# Use this template for heartbeat operations
outconf.heartbeat.report_template: "heartbeat_report"
EOF
```

Now, let's create a long-running program to monitor:

```bash
# Create a script that runs for a while
cat << EOF > long-running.sh
#!/bin/bash
echo "Starting long-running process..."
count=1
while [ \$count -le 5 ]; do
  echo "Iteration \$count"
  sleep 15
  count=\$((count+1))
done
echo "Process complete."
EOF

chmod +x long-running.sh
```

Load our heartbeat configuration and run the program:

```bash
# Load the heartbeat configuration
chalk load heartbeat-config.c4m

# Run with exec and heartbeat enabled
chalk exec --exec-command-name=./long-running.sh
```

You'll see your script's output along with periodic heartbeat reports:

```
Starting long-running process...
[
  {
    "_OPERATION": "exec",
    "_DATETIME": "2024-03-05T14:45:10.123-05:00",
    "_PROCESS_PID": 12346,
    "_PROCESS_STATE": "running",
    "_PROCESS_CWD": "/home/user/chalk-demo",
    ...etc...
  }
]
Iteration 1
[
  {
    "_OPERATION": "heartbeat",
    "_DATETIME": "2024-03-05T14:45:20.456-05:00",
    "_PROCESS_PID": 12346,
    "_PROCESS_STATE": "running",
    "_PROCESS_CWD": "/home/user/chalk-demo",
    ...etc...
  }
]
...etc...
```

The heartbeat reports continue to be generated every 10 seconds as specified in the configuration,
providing regular snapshots of your application's state as it runs.

## Customizing Exec Reports

You can customize what data gets collected and how it's reported by configuring Chalk's reporting
templates. Let's explore a few examples:

### Customizing Output Location

Let's create a configuration that sends exec reports to a specific file:

```bash
# Create a file output configuration
cat << EOF > file-output-config.c4m
# Define a sink for file output
sink_config exec_file_output {
  sink: "file"
  enabled: true
  filename: "./exec-reports.log"
}

# Subscribe our new sink to the report topic
subscribe("report", "exec_file_output")
EOF

# Load the configuration
chalk load file-output-config.c4m

# Run a command with the new configuration
chalk exec --exec-command-name=ls -la
```

Now check the contents of `exec-reports.log` to see the exec report that was written to the file.

### Focusing on Network Information

If you're particularly interested in network activity, you can create a configuration that focuses
on that:

```bash
# Create a network-focused configuration
cat << EOF > network-config.c4m
# Define a report template focusing on network
report_template network_focus {
  key._OP_TCP_SOCKET_INFO.use                 = true
  key._OP_UDP_SOCKET_INFO.use                 = true
  key._OP_IPV4_ROUTES.use                     = true
  key._OP_IPV6_ROUTES.use                     = true
  key._OP_IPV4_INTERFACES.use                 = true
  key._OP_ARP_TABLE.use                       = true
  key._PROCESS_PID.use                        = true
  key._TIMESTAMP.use                          = true
}

# Use this template for exec operations
outconf.exec.report_template: "network_focus"
EOF

# Load the configuration
chalk load network-config.c4m

# Run a command that generates network activity
chalk exec --exec-command-name=curl example.com
```

This configuration will produce reports that focus specifically on network-related information,
which can be valuable for monitoring network connections and activity.

## Using Exec Reports with Containers

Chalk's exec capability is particularly powerful when used with containers. Let's look at a simple
example:

### Monitoring a Container

First, let's build a container image with Chalk:

```bash
# Create a simple Dockerfile
cat > Dockerfile << EOF
FROM alpine
CMD ["sh", "-c", "while true; do echo 'Container is running...'; sleep 30; done"]
EOF

# Build the image with Chalk
chalk docker build -t chalk-demo-container .
```

Now, we can run the container:

```bash
docker run -d --name chalk-demo chalk-demo-container
```

If you haveve built the container with Chalk's entrypoint wrapping enabled, it will automatically
generate exec reports when the container starts. You can view these reports in your configured
output locations.

To enable entrypoint wrapping, you would have loaded a configuration like:

```bash
cat << EOF > docker-wrap-config.c4m
# Enable Docker entrypoint wrapping
docker.wrap_entrypoint: true
EOF

chalk load docker-wrap-config.c4m
```

## Practical Applications

Now that we understand the basics, let's briefly consider some practical applications for
`chalk exec` reports:

1. **Runtime Monitoring**: Track the behavior of your application over time through heartbeat
   reports.
1. **Incident Investigation**: When issues occur, exec reports provide valuable context about what
   was running and how.
1. **Performance Analysis**: Monitor resource usage and system state alongside your application.
1. **Security Monitoring**: Detect unexpected network connections or process behavior.
1. **Container Observability**: Gain visibility into containerized applications that might
   otherwise be difficult to monitor.

## Summary: What We've Learned

In this guide, we've explored the fundamentals of using Chalk's `exec` reports to gain visibility into running applications. Here's a summary of the key concepts we've covered:

1. **Basic `chalk exec` usage**: We learned how to execute programs with Chalk and understand the
   reports it generates, containing valuable metadata about the process and its environment.
1. **Heartbeat monitoring**: We discovered how to configure Chalk to generate periodic reports
   during a program's execution, providing continuous visibility into its runtime state.
1. **Report customization**: We explored how to customize what data gets collected in exec reports
   and where these reports are sent, allowing you to focus on the information most relevant to your needs.
1. **Container integration**: We saw how Chalk's exec capability can be combined with its Docker
   integration to monitor containerized applications.
1. **Practical applications**: We considered several real-world use cases for exec reports, from
   monitoring and troubleshooting to security and performance analysis.

The `chalk exec` command creates a crucial link between build-time and runtime, extending Chalk's
observability capabilities throughout the software lifecycle. By collecting detailed information
about running applications, Chalk provides a comprehensive view of your software from development
to production.

As you become more familiar with Chalk exec reports, you can develop more sophisticated
configurations tailored to your specific observability needs, integrate with monitoring systems,
and build automated workflows that leverage this valuable runtime information.

For more detailed information on available metadata keys and configuration options, refer to the
[Chalk Metadata Reference](./advanced-topics/config-overview/metadata.md) and
[Configuration Guide](./advanced-topics/).
