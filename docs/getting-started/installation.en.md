# Chalk Installation Guide

This guide provides detailed instructions for getting Chalk up and running on your system. You can
either download a pre-built binary (recommended for most users) or build Chalk from source.

## Option 1: Downloading the Chalk Binary

Downloading a pre-built binary is the easiest way to get started with Chalk. The binary is
self-contained with no dependencies to install.

### Step 1: Visit the Download Page

Navigate to the Crash Override downloads page at:

```
https://crashoverride.com/downloads
```

### Step 2: Download the Binary for Your System

Select the appropriate binary for your operating system and architecture. Chalk currently supports:

- Linux (amd64 and arm64)
- macOS (amd64 and arm64)

Click on the appropriate download link to begin downloading the binary.

### Step 3: Make the Binary Executable

After downloading, you'll need to make the binary executable. Open a terminal and navigate to the
directory containing the downloaded file.

```bash
# Navigate to download directory
cd ~/Downloads

# Make the binary executable
chmod +x chalk
```

### Step 4: Move the Binary to a Directory in Your PATH

For convenience, move the Chalk binary to a directory in your PATH. This will allow you to run
Chalk from any location.

```bash
# Create a local bin directory if it doesn't exist
mkdir -p ~/.local/bin

# Move chalk to local bin directory
mv chalk ~/.local/bin

# Add local bin to PATH if not already there
echo 'export PATH=$PATH:~/.local/bin' >> ~/.bashrc

# Reload your shell configuration
source ~/.bashrc
```

### Step 5: Verify the Installation

Verify that Chalk is installed correctly by running:

```bash
chalk version
```

You should see output showing the version of Chalk you've installed.

## Option 2: Building Chalk from Source

Building from source gives you the latest features and the ability to customize your build. There
are two methods to build Chalk from source: using Docker (recommended) or building directly on your
system.

### Method 1: Building with Docker (Recommended)

This method requires Docker and Docker Compose to be installed on your system.

#### Step 1: Clone the Chalk Repository

```bash
git clone https://github.com/crashappsec/chalk.git
cd chalk
```

#### Step 2: Build the Docker Image

```bash
docker compose build chalk
```

This command builds a Docker image that contains all the necessary dependencies to build Chalk.

#### Step 3: Build Chalk

```bash
make chalk
```

This will compile Chalk using the Docker image created in the previous step. The resulting binary
will be placed in the current directory.

For a debug version with additional logging capabilities, use:

```bash
make debug
```

#### Step 4: Verify the Build

Check that the build was successful by running:

```bash
./chalk
```

This should display the Chalk help documentation.

#### Step 5: Install the Binary

Move the chalk binary to a directory in your PATH:

```bash
chmod +x chalk
mv chalk ~/.local/bin/
```

### Method 2: Building Without Docker

Building without Docker requires a POSIX-compliant environment (Linux or macOS) with a C compiler
toolchain installed. Chalk currently supports amd64 and arm64 architectures.

#### Step 1: Install Prerequisites

You need to have a C compiler installed on your system. On Ubuntu or Debian-based systems:

```bash
sudo apt update
sudo apt install build-essential
```

On macOS with Homebrew:

```bash
brew install gcc
```

#### Step 2: Install Nim 2.0

Chalk is built using Nim 2.0, which you can install using the choosenim installer:

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
```

#### Step 3: Add Nim to Your PATH

```bash
export PATH=$PATH:~/.nimble/bin
```

You might want to add this line to your `~/.bashrc` or `~/.zshrc` for future sessions.

#### Step 4: Clone the Chalk Repository

```bash
git clone https://github.com/crashappsec/chalk.git
cd chalk
```

#### Step 5: Build Chalk

```bash
nimble build
```

This command will compile Chalk and produce a binary in the current directory.

#### Step 6: Verify and Install

Test that the build was successful:

```bash
./chalk
```

Then move the binary to a directory in your PATH:

```bash
chmod +x chalk
mv chalk ~/.local/bin/
```

Chalk ships with extensive documentation for its built-in commands. Access them by running the
following:

```bash
# Get help
chalk help

# View available commands
chalk help commands
```

## Next Steps

Now that you have Chalk installed, you can start using it to mark and track your software artifacts.
Refer to the [Getting Started Guide](https://crashoverride.com/docs/chalk/getting-started) for an
introduction to Chalk's capabilities.
