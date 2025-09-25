# Testing Documentation for serverless-plugin-crashoverride

## Getting Started

### Quick Setup

```bash
# Install dependencies
yarn install

# Run all tests
yarn test

# Run tests in watch mode for development
yarn test:watch

# Run specific test file
yarn test src/index.test.ts
```

## Testing Architecture

This plugin uses:

- **Jest** as the testing framework
- **TypeScript** for type-safe tests
- **Mock-first approach** for external dependencies
- **Lifecycle hook simulation** for Serverless Framework behavior

### File Organization

- Tests: `src/index.test.ts`
- Mocks: `src/__mocks__/`
- Test helpers // utilities: `src/__tests__/test-helpers.ts`

## Writing Tests

Serverless Framework plugins are not called explicitly but register themselves with the Lifecycle Hooks made available
by the framework. When writing tests, you must call these hooks as the framework would in your test cases. These are
available in the [test-helpers.ts](./src/__tests__/test-helpers.ts) module and function documentation.

**IMPORTANT:** To write valide tests be sure to execute your hooks in the correct order. Refer to the
[Serverless Framework docs]() for more detail or, refer to this [helpful cheatsheet](https://gist.github.com/HyperBrain/50d38027a8f57778d5b0f135d80ea406).

## Available Test Utilities

### Mocks

All mocks are in `src/__mocks__/` with detailed documentation in their source files:

- **`child_process.ts`** - Simulates chalk binary detection and injection
- **`fs.ts`** - Simulates file system operations for package detection
- **`fetch.ts`** - Simulates ARN fetching from remote endpoints using the Fetch API
- **`serverless.mock.ts`** - Creates mock Serverless Framework instances

### Test Helpers (`src/__tests__/test-helpers.ts`)

- **TestSetupBuilder:** Fluent API for creating test scenarios. See source for full method documentation.

#### Lifecycle Hook Helpers

Execute plugin lifecycle hooks in tests. See complete usage example above along with source for more detailed documentation.

**Typical execution order:**

```typescript
executeProviderConfigHook(plugin); // Setup provider config
executeDeploymentHook(plugin); // Run pre-flight checks
await executeAwsPackageHook(plugin); // Mutate service (async!)
```

## Best Practices

1. **Execute hooks in order** - provider config -> deployment -> packaging
2. **Always await async hooks** - `executeAwsPackageHook` returns a Promise
3. **Reset mocks** in `beforeEach` or `afterEach`
4. **Use TestSetupBuilder** instead of manual setup
5. **Test both success and failure paths**
6. **Group related tests** with `describe` blocks

## Troubleshooting

| Issue                                                           | Solution                                       |
| --------------------------------------------------------------- | ---------------------------------------------- |
| "Cannot ascertain service's region from Provider configuration" | Call `executeProviderConfigHook(plugin)` first |
| Tests hanging or timing out                                     | Ensure `executeAwsPackageHook` is awaited      |
