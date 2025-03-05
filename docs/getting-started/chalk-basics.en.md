# Chalk Basics: A Quick Start Guide

This guide covers the fundamental operations of Chalk with simple examples. You will learn how to
chalk mark binaries and container images, extract chalk marks, and configure Chalk's reporting
behavior.

## Prerequisites

Before starting, ensure you have a working installation of Chalk. If you have not installed Chalk
yet, please refer to the [Chalk Installation Guide](./installation.en.md).

## Marking a Binary

Let's start with the simplest operation: marking an executable file. We will use the `ls` command
that's already on your system as our example.

### Step 1: Create a Test Directory

First, let's create a clean directory for our experiments:

```bash
mkdir chalk-test
cd chalk-test
```

### Step 2: Copy the Binary

Copy the `ls` binary to our test directory:

```bash
cp $(which ls) ./
```

This gives us a copy of the `ls` binary that we can safely experiment with.

### Step 3: Insert a Chalk Mark

Now, let's insert a chalk mark into our copy of `ls`:

```bash
chalk insert ls
```

You should see output similar to this:

```
info:  ./ls: chalk mark successfully added
info:  Full chalk report appended to: ~/.local/chalk/chalk.log
[
  {
    "_OPERATION": "insert",
    "_DATETIME": "2024-03-05T10:15:30.123-05:00",
    "_CHALKS": [
      {
        "PRE_CHALK_HASH": "8696974df4fc39af88ee23e307139afc533064f976da82172de823c3ad66f444",
        "CHALK_ID": "ABCDE1-F234-G567-H89012",
        "PATH_WHEN_CHALKED": "/home/user/chalk-test/ls",
        "ARTIFACT_TYPE": "ELF",
        "CHALK_VERSION": "0.2.2",
        "METADATA_ID": "ZYXWV9-U876-T543-S21098",
        "_VIRTUAL": false,
        "_CURRENT_HASH": "8696974df4fc39af88ee23e307139afc533064f976da82172de823c3ad66f444"
      }
    ],
    ...etc...
  }
]
```

This indicates that Chalk has successfully added a mark to our binary. The mark contains metadata
about the binary and the environment at the time of marking.

## Marking a Docker Image

Chalk can also mark container images. Let's try marking the popular `nginx` image.

### Step 1: Pull the nginx Image

First, pull the `nginx` image if you don't already have it:

```bash
docker pull nginx:latest
```

### Step 2: Mark the Image

To mark a Docker image, we use Chalk to "wrap" the Docker build command:

```bash
# Create a simple Dockerfile that uses nginx
echo "FROM nginx:latest" > Dockerfile

# Build with Chalk
chalk docker build -t chalked-nginx .
```

You will see Docker's build output, followed by Chalk's report:

```
...etc...
Successfully built abcdef123456
Successfully tagged chalked-nginx:latest
[
  {
    "_OPERATION": "build",
    "_DATETIME": "2024-03-05T10:20:45.678-05:00",
    "_CHALKS": [
      {
        "CHALK_ID": "IJKLM2-N345-O678-P90123",
        "DOCKERFILE_PATH": "/home/user/chalk-test/Dockerfile",
        "DOCKER_FILE": "FROM nginx:latest\n",
        "DOCKER_TAGS": [
          "chalked-nginx:latest"
        ],
		...etc...
      }
    ],
    ...etc...
  }
]
```

Chalk has now added a chalk mark to the image. The mark is stored in a file at the root of the
container filesystem.

:> [!NOTE]

> More documentation is available [on how Chalk wraps Docker](../advanced-topics/docker.en.md).

## Extracting Chalk Marks

Now that we've added chalk marks to both a binary and a Docker image, let's extract and view these
marks.

### Extracting from a Binary

To extract the chalk mark on demand from our modified `ls` binary:

```bash
chalk extract ./ls
```

This will show you the chalk mark that was inserted earlier:

```
info:  ./ls: Chalk mark extracted
info:  Full chalk report appended to: ~/.local/chalk/chalk.log
[
  {
    "_OPERATION": "extract",
    "_DATETIME": "2024-03-05T10:25:12.345-05:00",
    "_CHALKS": [
      {
        "CHALK_ID": "ABCDE1-F234-G567-H89012",
        "CHALK_VERSION": "0.2.2",
        "ARTIFACT_TYPE": "ELF",
        "METADATA_ID": "ZYXWV9-U876-T543-S21098",
        "_OP_ARTIFACT_PATH": "/home/user/chalk-test/ls",
        "_OP_ARTIFACT_TYPE": "ELF",
        "_CURRENT_HASH": "7cf6bd9e964e19e06f77fff30b8a088fbde7ccbfc94b9500c09772e175613def"
      }
    ],
    ...etc...
  }
]
```

### Extracting from a Docker Image

To extract the chalk mark from our Docker image:

```bash
chalk extract chalked-nginx:latest
```

This will display the chalk mark from the image:

```
info:  chalked-nginx:latest: Chalk mark extracted
info:  Full chalk report appended to: ~/.local/chalk/chalk.log
[
  {
    "_OPERATION": "extract",
    "_DATETIME": "2024-03-05T10:30:23.456-05:00",
    "_CHALKS": [
      {
        "_OP_ARTIFACT_TYPE": "Docker Image",
        "_IMAGE_ID": "abcdef123456789...",
        "_REPO_TAGS": [
          "chalked-nginx:latest"
        ],
        "_CURRENT_HASH": "abcdef123456789...",
        "CHALK_ID": "IJKLM2-N345-O678-P90123",
        "CHALK_VERSION": "0.2.2",
        "METADATA_ID": "QRSTU3-V456-W789-X01234"
      }
    ],
    ...etc...
  }
]
```

## Examining the Raw Chalk Mark

To see the actual chalk mark that was inserted into the binary, we can use the `strings` command:

```bash
strings ./ls | grep MAGIC
```

This should output the JSON content of the chalk mark, which begins with the `MAGIC` key:

```json
{
  "MAGIC": "dadfedabbadabbed",
  "CHALK_ID": "ABCDE1-F234-G567-H89012",
  "CHALK_VERSION": "0.2.2",
  ...
}
```

For Docker images, the chalk mark is stored in a file called `/chalk.json` within the container filesystem.

## Configuring Chalk's Reporting

By default, Chalk outputs a summary report to the console and a full report to `~/.local/chalk/chalk.log`. Let's customize this behavior to output the full report to both stdout and a local file of our choice.

### Creating a Custom Configuration

Create a new file called `custom-config.c4m` with the following content:

```
# Define a sink for stdout
sink_config full_stdout {
  sink: "stdout"
  enabled: true
}

# Define a sink for a custom log file
sink_config custom_file {
  sink: "file"
  enabled: true
  filename: "./chalk-reports.log"
}

# Subscribe our new sinks to the report topic
subscribe("report", "full_stdout")
subscribe("report", "custom_file")

# Use the 'report_all' template for all reports
outconf insert {
  report_template: "report_all"
}

outconf extract {
  report_template: "report_all"
}

outconf build {
  report_template: "report_all"
}
```

### Loading the Configuration

Now load this configuration into Chalk:

```bash
chalk load custom-config.c4m
```

You should see a confirmation that the configuration was loaded successfully.

### Testing the New Configuration

Let's test our new configuration by marking another file:

```bash
cp $(which cat) ./
chalk insert cat
```

You should now see the full report directly in your terminal, and it will also be written to `./chalk-reports.log` in your current directory.

To verify the file was created and contains the report:

```bash
ls -la chalk-reports.log
cat chalk-reports.log
```

## Summary

In this guide, you've learned how to:

1. Insert chalk marks into binaries using `chalk insert`
2. Mark Docker images using `chalk docker build`
3. Extract and view chalk marks using `chalk extract`
4. Customize Chalk's reporting configuration

These basic operations form the foundation for more advanced Chalk usage. As you become more familiar with Chalk, you can explore more complex configurations and integrate Chalk into your CI/CD pipelines for automated software tracking and reporting.

For more detailed information, refer to the [Chalk User Guide](./user-guide.md) and [Configuration Overview](./config-overview.md).
