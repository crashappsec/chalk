# @crashappsec/serverless-plugin

A Serverless Framework plugin for Crash Override that enhances AWS Lambda deployments with runtime security features, chalkmark injection, and deployment validation.

## Overview

This plugin integrates with the Serverless Framework to provide:

- **Dust Lambda Extension**: Automatically adds the Dust Lambda Extension to all Lambda functions for runtime monitoring and security
- **Chalkmark Injection**: Integrates with the chalk binary to inject chalkmarks into deployment packages for supply chain security
- **Memory Configuration Validation**: Enforces minimum memory requirements for Lambda functions to ensure optimal performance
- **Layer Limit Validation**: Prevents exceeding AWS Lambda's layer/extension limits

## Installation

Install the plugin in your Serverless Framework project:

```bash
yarn add @crashoverride/serverless-plugin
```

Add the plugin to your `serverless.yml`:

```yaml
plugins:
  - @crashappsec/serverless-plugin

custom:
  crashoverride:
    memoryCheck: true # Optional: enforce minimum memory requirements
    chalkCheck: true # Optional: enforce chalk binary availability
    arnVersion: 7 # Optional: pin Dust Extension to specific version
```

### Requirements

- Node.js >= 22.0.0
- Serverless Framework ^3.0.0
- chalk binary (optional, required if `chalkCheck: true`)

## Configuration

The plugin can be configured through three methods with the following precedence:

1. **serverless.yml** `custom.crashoverride` section (highest priority)
2. **Environment variables** (medium priority)
3. **Default values** (lowest priority)

### Configuration Options

The plugin can be configured in either the `serverless.yaml` file or their environment variable equivalent. Reference the
table and usage examples below.

| YAML Option       | Env Equivalent            | Type    | Default                             | Description                                                                                                                                                                            |
| ----------------- | ------------------------- | ------- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `memoryCheck`     | `CO_MEMORY_CHECK`         | boolean | `false`                             | When `true`, enforces minimum memory requirements. Build fails if any function has insufficient memory. When `false`, only warns about low memory.                                     |
| `memoryCheckSize` | `CO_MEMORY_CHECK_SIZE_MB` | number  | `256`                               | Minimum required memory size in MB. Only enforced when `memoryCheck` is `true`.                                                                                                        |
| `chalkCheck`      | `CO_CHALK_CHECK_ENABLED`  | boolean | `false`                             | When `true`, requires the chalk binary to be available in `$PATH`. Build fails if `chalk` is not found. When `false`, continues without chalkmark injection if `chalk` is unavailable. |
| `arnUrlPrefix`    | `CO_ARN_URL_PREFIX`       | string  | `https://dl.crashoverride.run/dust` | Base URL for fetching Dust Lambda Extension ARNs. Used to construct region-specific ARN endpoints.                                                                                     |
| `arnVersion`      | `CO_ARN_VERSION`          | number  | (latest version)                    | Optional version number to pin the Dust Extension to a specific version (e.g., 1, 7, 22). When not specified, uses the latest version available.                                       |

### Example Configurations

#### Using serverless.yml

```yaml
service: my-service

provider:
  name: aws
  runtime: nodejs18.x
  memorySize: 1024 # Must be >= memoryCheckSize when memoryCheck is true

custom:
  crashoverride:
    memoryCheck: true # Enforce minimum memory
    memoryCheckSize: 512 # Require at least 512MB
    chalkCheck: false # Allow deployment without chalk binary
    arnVersion: 22 # Pin to specific Dust Extension version (optional)

functions:
  myFunction:
    handler: index.handler

plugins:
  - serverless-plugin-crashoverride
```

#### Using Environment Variables

Using environment variables can be helpful when enforcing the checks across entire repositories
or even entire organizations.

The equivalent configuration to above, driven by environment variables. **Note:** env vars
have a lower precedence than the more localized YAML configuration values. Feel free to mix-and-match
but keep in mind that the YAML values will clobber duplicated configs in your env.

In the example below the environement sets the memory check to fail-open but the YAML overrides it
meaining the final configuration will lead to the memory check to failing closed.

```bash
# Set configuration via environment
export CO_MEMORY_CHECK=false
export CO_MEMORY_CHECK_SIZE_MB=512
export CO_CHALK_CHECK_ENABLED=true
export CO_ARN_VERSION=7  # Pin to version 7

# Deploy with environment configuration
serverless deploy
```

#### Mixed Configuration (serverless.yml takes precedence)

```yaml
# serverless.yml
custom:
  crashoverride:
    memoryCheck: true # This overrides CO_MEMORY_CHECK env var
```

## How It Works

The Crash Override plugin hooks into the Serverless Framework lifecycle at four key points:

1. **`after:package:setupProviderConfiguration`**:
   - Reads and stores provider configuration (region, memory size)
   - Prepares configuration for subsequent operations

2. **`after:package:createDeploymentArtifacts`**:
   - Performs pre-flight checks
   - Validates memory configuration against minimum requirements
   - Checks for `chalk` binary availability
   - Logs validation status

3. **`before:package:compileFunctions`**:
   - Adds Dust Lambda Extension to all functions (while validating layer limits)
   - Fetches region-specific extension ARNs
   - Injects chalkmarks into the deployment package (if chalk is available)

## Development

### Environment Setup

1. Clone the repository and install dependencies:

```bash
git clone https://github.com/crashappsec/chalk
cd ./chalk/serverless-plugin-crashoverride
yarn install
```

2. Start development with TypeScript watch mode:

```bash
yarn dev
```

### Testing

For comprehensive testing documentation, see [TESTING.md](./TESTING.md).

## A Closer Look

### Dust Lambda Extension

The plugin automatically adds the Dust Lambda Extension ARN to all Lambda functions in your service. It:

- Fetches region-specific ARNs from the configured endpoint
- Validates that adding the extension won't exceed AWS's 15 layer/extension limit
- Provides detailed logging about layer counts for each function
- Fails fast if any function would exceed limits

### Chalkmark Injection

When the `chalk` binary is available, the plugin:

- Locates the packaged `.zip` file in `.serverless/` directory
- Runs `chalk insert --inject-binary-into-zip` to add chalkmarks

### Memory Validation

The memory required for `chalk` extraction and runtime monitoring requires adequate memory allocation. The plugin can enforce minimum memory requirements to prevent issues in production:

- **Default minimum**: 256MB (configurable via `memoryCheckSize`, see table above)
- **Warning mode** (`memoryCheck: false`): Logs warnings when memory is below the minimum
- **Enforcement mode** (`memoryCheck: true`): Fails the build when memory is below the minimum
- Helps prevent performance issues and out-of-memory errors in production

**Note:** The AWS provider sets `memorySize` to 1024MB as the default.

## Contributing

We welcome contributions but do require you to complete a contributor license agreement or CLA. You
can read the CLA and about our process [here](https://crashoverride.com/docs/other/contributing).

## Support

If you need additional help including a demo of the cloud platform, please contact us using
hello@crashoverride.com

## License

[serverless-plugin-crashoverride](#) is licensed under the GPL version 3 license.
