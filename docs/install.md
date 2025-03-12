# Chalk Installation Guide

This guide provides detailed instructions for getting Chalk up and running on
your system. You can either download a pre-built binary (recommended for most
users) or build Chalk from source.

## Option 1: Downloading the Chalk Binary

Downloading a pre-built binary is the easiest way to get started with Chalk.
The binary is self-contained with no dependencies to install.

All chalk releases are published at https://crashoverride.com/downloads.

Chalk supports multiple operating systems and architectures:

- Linux (amd64 and arm64)
- MacOS (only arm64)

1. Download chalk. You can query for the latest published version or download
   specific version:

   ```bash
   version=$(curl -fsSL https://dl.crashoverride.run/chalk/current-version.txt)
   wget https://dl.crashoverride.run/chalk/chalk-$version-$(uname -s)-$(uname -m){,.sha256}
   ```

1. Validate checksum:

   ```bash
   # Linux
   sha256sum -c chalk-$version-$(uname -s)-$(uname -m).sha256
   # MacOS
   shasum -a 256 -c chalk-$version-$(uname -s)-$(uname -m).sha256
   ```

1. Make chalk executable:

   ```bash
   chmod +x chalk-$version-$(uname -s)-$(uname -m)
   ```

1. For convenience add `chalk` to `PATH`:

   ```bash
   cp chalk-$version-$(uname -s)-$(uname -m) ~/.local/bin/chalk
   export PATH=~/.local/bin:$PATH
   ```

1. 🎉 Use `chalk`:

   ```bash
   chalk version
   ```

   You should see output showing the version of Chalk you've installed.

## Option 2: Building Chalk from Source

Building from source gives you the latest features and the ability to customize
your build. There are two methods to build Chalk from source: using Docker
(recommended) or building directly on your system.

1. Clone the Chalk Repository

   ```bash
   git clone https://github.com/crashappsec/chalk.git
   cd chalk
   ```

1. Compile chalk:

   1. Use Docker and Docker Compose to built Chalk:

      ```bash
      make
      ```

   1. Alternatively Chalk can be built without Docker.
      That will require Nim and `musl` tool-chains to be installed on the system.
      We recommend using [`choosenim`](https://github.com/dom96/choosenim)
      to install `nim`.

      ```bash
      DOCKER= make
      ```

   The resulting binary will be placed in the current directory.

1. 🎉 Use `chalk`:

   ```bash
   ./chalk version
   ```

   This should display the Chalk version.

## Next Steps

Chalk ships with extensive documentation for its built-in commands.
Access them by running the following:

```bash
# Get help
chalk help

# View available commands
chalk help commands
```

Now that you have Chalk working, you can start using it to mark and track your
software artifacts. Refer to the
[Getting Started Guide](https://crashoverride.com/docs/chalk/getting-started)
for an introduction to Chalk's capabilities.
