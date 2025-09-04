# serverless-plugin-crashoverride

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
npm install serverless-plugin-crashoverride
```

Add the plugin to your `serverless.yml`:

```yaml
plugins:
  - serverless-plugin-crashoverride

custom:
  crashoverride:
    memoryCheck: true # Optional: enforce minimum memory requirements
    chalkCheck: true # Optional: enforce chalk binary availability
```

### Requirements

- Node.js >= 18.0.0
- Serverless Framework ^3.0.0
- chalk binary (optional, required if `chalkCheck: true`)

## Configuration

Configure the plugin behavior through the `custom.crashoverride` section in your `serverless.yml`:

| Option        | Type    | Default | Description                                                                                                                                                                                |
| ------------- | ------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `memoryCheck` | boolean | `false` | When `true`, enforces a minimum memory size of 512MB for all Lambda functions. Build will fail if any function has less memory configured. When `false`, only warns about low memory.      |
| `chalkCheck`  | boolean | `false` | When `true`, requires the chalk binary to be available in `$PATH`. Build will fail if `chalk` is not found. When `false`, continues without chalkmark injection if `chalk` is unavailable. |

### Example Configuration

```yaml
service: my-service

provider:
  name: aws
  runtime: nodejs18.x
  memorySize: 1024 # Must be >= 512 when memoryCheck is true

custom:
  crashoverride:
    memoryCheck: true # enforce minimum 512MB memory
    chalkCheck: false # allow deployment without chalk binary

functions:
  myFunction:
    handler: index.handler

plugins:
  - serverless-plugin-crashoverride
```

## How It Works

The Crash Override plugin hooks into the Serverless Framework lifecycle at two key points:

1. **`before:package:initialize`**:
   - Validates memory configuration against minimum requirements
   - Checks for `chalk` binary availability
   - Logs initialization status

2. **`after:aws:package:finalize:mergeCustomProviderResources`**:
   - Adds Dust Lambda Extension to all functions (validates layer limits)
   - Injects chalkmarks into the deployment package (if chalk is available)

## Development

### Environment Setup

1. Clone the repository and install dependencies:

```bash
git clone https://github.com/crashappsec/chalk
cd ./chalk/serverless-plugin-crashoverride
npm install
```

2. Start development with TypeScript watch mode:

```bash
npm run dev
```

### Available NPM Scripts

| Script       | Command              | Description                                                             |
| ------------ | -------------------- | ----------------------------------------------------------------------- |
| `build`      | `npm run build`      | Compiles TypeScript source files to JavaScript in the `dist/` directory |
| `dev`        | `npm run dev`        | Runs TypeScript compiler in watch mode for active development           |
| `test`       | `npm test`           | Runs the Jest test suite                                                |
| `test:watch` | `npm run test:watch` | Runs Jest tests in watch mode for TDD workflow                          |
| `lint`       | `npm run lint`       | Runs ESLint to check code quality issues                                |
| `lint:fix`   | `npm run lint:fix`   | Automatically fixes ESLint issues where possible                        |
| `format`     | `npm run format`     | Formats code using Prettier                                             |
| `prepare`    | `npm run prepare`    | Automatically runs build before npm publish (lifecycle hook)            |

### Development Workflow

1. **Make changes** to source files in `src/`
2. **Run tests** to ensure functionality: `npm test`
3. **Lint and format** your code: `npm run lint:fix && npm run format`
4. **Build** the project: `npm run build`
5. **Test locally** by linking to a test Serverless project:

   ```bash
   npm link
   cd /path/to/test/serverless/project
   npm link serverless-plugin-crashoverride
   ```

### Testing

The plugin uses Jest for testing with TypeScript support via `ts-jest`. Tests are located alongside source files with the `.test.ts` extension.

Run a single test file:

```bash
npm test -- src/index.test.ts
```

## A Closer Look

### Dust Lambda Extension

The plugin automatically adds the Dust Lambda Extension ARN to all Lambda functions in your service. It:

- Validates that adding the extension won't exceed AWS's 15 layer/extension limit
- Provides detailed logging about layer counts for each function
- Fails fast if any function would exceed limits

### Chalkmark Injection

When the `chalk` binary is available, the plugin:

- Locates the packaged `.zip` file in `.serverless/` directory
- Runs `chalk insert --inject-binary-into-zip` to add chalkmarks
- Provides detailed logging about the injection process

### Memory Validation

The memory required for `chalk` requires no less than 512MB to safely run both your application workload and the `chalk` extraction. To
mitigate issues in production you can configure the plugin to perform a hard check against the `memorySize` configuration at the `provider`
level:

- Warns when memory is below 512MB (if `memoryCheck: false`)
- Fails the build when memory is below 512MB (if `memoryCheck: true`)
- Helps prevent performance issues in production

**Note:** The AWS provider sets `memorySize` to 1024MB as the default.

## Contributing

We welcome contributions but do require you to complete a contributor license agreement or CLA. You
can read the CLA and about our process [here](https://crashoverride.com/docs/other/contributing).

## Support

If you need additional help including a demo of the cloud platform, please contact us using
hello@crashoverride.com

## License

[serverless-plugin-crashoverride](#) is licensed under the GPL version 3 license.
