# Testing Documentation for serverless-plugin-crashoverride

## Getting Started

### Quick Setup

```bash
# Install dependencies
npm install

# Run all tests
npm test

# Run tests in watch mode for development
npm run test:watch

# Run specific test file
npm test -- src/index.test.ts
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

Below is a complete example that demonstrates why and how to use lifecycle hooks in tests:

```typescript
// ./src/example.test.ts
import {
  // Serverless Framework mock builder
  TestSetupBuilder,
  // hook helpers
  executeProviderConfigHook,
  executeDeploymentHook,
  executeAwsPackageHook,
} from "./__tests__/test-helpers";

describe("CrashOverride Plugin Memory Validation", () => {
  it("should enforce memory requirements when enabled", async () => {
    // Step 1: Build a plugin instance with specific configuration
    const { plugin, mockLog } = new TestSetupBuilder()
      .withMemoryCheck(true, 512) // Require 512MB minimum
      .withProviderMemory(256) // But provider only has 256MB
      .withChalkAvailable() // Mock chalk as installed
      .build();

    // Step 2: Execute lifecycle hooks manually
    // This simulates what Serverless Framework does automatically

    // First, setup provider configuration
    executeProviderConfigHook(plugin);
    // Without this, plugin.providerConfig would be null

    // Next, run pre-flight checks (memory validation happens here)
    expect(() => {
      executeDeploymentHook(plugin);
    }).toThrow(
      "Memory check failed: memorySize (256MB) is less than minimum required (512MB)",
    );

    // The test stops here because memory check failed
    // In a success scenario, we'd continue to:
    // await executeAwsPackageHook(plugin);
  });

  it("should successfully deploy when memory is sufficient", async () => {
    const { plugin, mockLog, mockServerless } = new TestSetupBuilder()
      .withMemoryCheck(true, 256) // Require 256MB minimum
      .withProviderMemory(512) // Provider has 512MB
      .withFunctions({
        // Add a test function
        myFunc: {
          handler: "index.handler",
          layers: [],
        },
      })
      .build();

    // Execute all hooks in order - simulating full deployment
    executeProviderConfigHook(plugin); // 1. Read provider config
    executeDeploymentHook(plugin); // 2. Validate requirements
    await executeAwsPackageHook(plugin); // 3. Add extensions (note how it is async)

    // Verify the function was modified with Dust extension
    const func = mockServerless.service.functions["myFunc"];
    expect(func.layers).toHaveLength(1);
    expect(func.layers[0]).toContain("layer:test-crashoverride-dust-extension");

    // Verify success was logged
    expect(mockLog.success).toHaveBeenCalledWith(
      expect.stringContaining("Successfully added Dust Lambda Extension"),
    );
  });
});
```

## Available Test Utilities

### Mocks

All mocks are in `src/__mocks__/` with detailed documentation in their source files:

- **`child_process.ts`** - Simulates chalk binary detection and injection
- **`fs.ts`** - Simulates file system operations for package detection
- **`https.ts`** - Simulates ARN fetching from remote endpoints
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

## Common Testing Patterns

### Testing Configuration Precedence

```typescript
it("should prioritize serverless.yml over environment variables", () => {
  const { mockLog } = new TestSetupBuilder()
    .withEnvironmentVar("CO_MEMORY_CHECK", "false")
    .withCustomConfig({ memoryCheck: true })
    .build();

  assertions.expectConfigValues(mockLog, true, 256, false);
});
```

### Testing Error Conditions

```typescript
it("should throw when memory check fails", () => {
  const { plugin } = new TestSetupBuilder()
    .withMemoryCheck(true, 2048)
    .withProviderMemory(1024)
    .build();

  executeProviderConfigHook(plugin);
  expect(() => executeDeploymentHook(plugin)).toThrow(ServerlessError);
});
```

### Testing Lambda Layer Limits

```typescript
it("should fail when exceeding 15 layers", async () => {
  const { plugin } = new TestSetupBuilder()
    .withFunctions({
      func: {
        layers: new Array(15).fill(0).map((_, i) => `layer-${i}`),
      },
    })
    .build();

  executeProviderConfigHook(plugin);
  await expect(executeAwsPackageHook(plugin)).rejects.toThrow();
});
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
