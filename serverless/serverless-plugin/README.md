# @crashappsec/serverless-dust

A Serverless Framework plugin that integrates AWS Lambda dust extension to all
deployed functions.

## Overview

This plugin integrates with the Serverless Framework to provide:

- **Dust Lambda Extension**: Automatically adds the Dust Lambda Extension to
  all Lambda functions for runtime monitoring and security
- **Chalkmark Injection**: Integrates with the chalk binary to inject
  chalkmarks into deployment packages for supply chain security
- **Memory Configuration Validation**: Enforces minimum memory requirements for
  Lambda functions to ensure optimal performance
- **Layer Limit Validation**: Prevents exceeding AWS Lambda's layer/extension limits

## Installation

Install the plugin in your Serverless Framework project:

```sh
serverless plugin install -n @crashappsec/serverless-dust
```

That will:

- add it to `serverless.yml`
- add it to `package.json`

### Requirements

- Node.js >= 18.0.0
- Serverless Framework >=3.0.0 (both 3 and 4 work)
- chalk binary (optional, required if `chalkCheck: true`)

## Configuration

The plugin can be configured through three methods with the following precedence:

1. **serverless.yml** - `custom.crashoverride` section (highest priority)
2. **Environment variables** - (medium priority)
3. **Default values** - (lowest priority)

### Configuration Options

The plugin can be configured in either the `serverless.yaml` file or their
environment variable equivalent. Reference the table and usage examples below.

| YAML Option       | Env Equivalent            | Type    | Default                             | Description                                                                                                                                                                            |
| ----------------- | ------------------------- | ------- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `memoryCheck`     | `CO_MEMORY_CHECK`         | boolean | `true`                              | When `true`, enforces minimum memory requirements. Build fails if any function has insufficient memory. When `false`, only warns about low memory.                                     |
| `memoryCheckSize` | `CO_MEMORY_CHECK_SIZE_MB` | number  | `256`                               | Minimum required memory size in MB. Only enforced when `memoryCheck` is `true`.                                                                                                        |
| `chalkCheck`      | `CO_CHALK_CHECK_ENABLED`  | boolean | `true`                              | When `true`, requires the chalk binary to be available in `$PATH`. Build fails if `chalk` is not found. When `false`, continues without chalkmark injection if `chalk` is unavailable. |
| `chalkPath`       | `CO_CHALK_PATH`           | string  | `chalk`                             | Default path how to look for a chalk binary on the system.                                                                                                                             |
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

functions:
  myFunction:
    handler: index.handler

plugins:
  - @crashappsec/serverless-dust
```

#### Using Environment Variables

Using environment variables can be helpful when enforcing the checks across
entire repositories or even entire organizations.

The equivalent configuration to above, driven by environment variables.
**Note:** env vars have a lower precedence than the more localized YAML
configuration values. Feel free to mix-and-match but keep in mind that the YAML
values will clobber duplicated configs in your env.

In the example below the environment sets the memory check to fail-open but
the YAML overrides it meaning the final configuration will lead to the memory
check to failing closed.

```sh
# Set configuration via environment
export CO_MEMORY_CHECK=false
export CO_MEMORY_CHECK_SIZE_MB=512
export CO_CHALK_CHECK_ENABLED=true

# Deploy with environment configuration
serverless deploy
```

## How It Works

The Crash Override plugin hooks into the Serverless Framework lifecycle at
**`before:package:compileFunctions`**:

- Adds Dust Lambda Extension to all functions (while validating layer limits)
- Fetches region-specific extension ARNs
- Injects chalkmarks into the deployment package (if chalk is available)
