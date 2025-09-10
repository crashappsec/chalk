/**
 * Test Helpers for CrashOverride Serverless Plugin
 *
 * This module provides utilities for testing the Serverless Framework plugin,
 * including lifecycle hook helpers, a test setup builder, and assertion helpers.
 *
 * The Serverless Framework operates through lifecycle events, and plugins register
 * handlers for these events. In tests, we manually trigger these hooks to simulate
 * the framework's behavior during deployment.
 */

import CrashOverrideServerlessPlugin from "../index";
import {
    createMockServerless,
    createMockLogger,
    createMockOptions,
} from "../__mocks__/serverless.mock";
import * as childProcessMock from "../__mocks__/child_process";
import * as fsMock from "../__mocks__/fs";
import type Serverless from "serverless";
import type { CrashOverrideConfig } from "../types";

/**
 * Creates a plugin instance with optional serverless and environment variable overrides.
 *
 * @param serverlessOverrides - Optional overrides for the Serverless instance configuration
 * @param envVars - Optional environment variables to set before creating the plugin
 * @returns Object containing the plugin instance, mock serverless, mock logger, and mock options
 *
 * @example
 * ```typescript
 * const { plugin, mockLog } = createPlugin(
 *   { service: { custom: { crashoverride: { memoryCheck: true } } } },
 *   { "CO_MEMORY_CHECK_SIZE_MB": "512" }
 * );
 * ```
 */
export function createPlugin(
    serverlessOverrides?: any,
    envVars?: Record<string, string>,
): {
    plugin: CrashOverrideServerlessPlugin;
    mockServerless: Serverless;
    mockLog: ReturnType<typeof createMockLogger>;
    mockOptions: any;
} {
    if (envVars) {
        Object.entries(envVars).forEach(([key, value]) => {
            process.env[key] = value;
        });
    }

    const mockServerless = createMockServerless(serverlessOverrides);
    const mockOptions = createMockOptions();
    const mockLog = createMockLogger();

    const plugin = new CrashOverrideServerlessPlugin(
        mockServerless,
        mockOptions,
        {
            log: mockLog,
            writeText: jest.fn(),
            progress: {
                create: jest.fn(),
                remove: jest.fn(),
                update: jest.fn(),
                get: jest.fn(),
            },
        } as any,
    );

    return { plugin, mockServerless, mockLog, mockOptions };
}

/**
 * Executes the provider configuration lifecycle hook.
 *
 * **Lifecycle Hook:** `after:package:setupProviderConfiguration`
 *
 * **Purpose:** Reads and persists provider configuration including AWS region,
 * memory size, and other provider-specific settings. This configuration is
 * required for subsequent operations like fetching region-specific ARNs.
 *
 * **Common Testing Contexts:**
 * - Must be called FIRST before other hooks that depend on provider config
 * - Testing provider configuration reading and validation
 * - Setting up tests that need AWS region or memory size information
 * - Testing fallback to default values when provider config is missing
 *
 * @param plugin - The plugin instance to execute the hook on
 *
 * @example
 * ```typescript
 * executeProviderConfigHook(plugin); // Sets up provider config
 * // Now plugin.providerConfig is initialized with region, memorySize, etc.
 * executeDeploymentHook(plugin); // Can now use provider config
 * ```
 */
export function executeProviderConfigHook(
    plugin: CrashOverrideServerlessPlugin,
): void {
    const hook = plugin.hooks["after:package:setupProviderConfiguration"];
    if (hook) {
        hook();
    }
}

/**
 * Executes the deployment pre-flight checks lifecycle hook.
 *
 * **Lifecycle Hook:** `after:package:createDeploymentArtifacts`
 *
 * **Purpose:** Performs pre-flight validation checks including memory size
 * validation and chalk binary availability checks. This hook runs after
 * deployment artifacts are created but before the service is mutated.
 *
 * **Common Testing Contexts:**
 * - Testing memory check validation (fails if memory < configured minimum)
 * - Testing chalk binary detection and requirement enforcement
 * - Testing warning vs error behavior based on configuration
 * - Validating that pre-flight checks run before service mutation
 *
 * @param plugin - The plugin instance to execute the hook on
 *
 * @example
 * ```typescript
 * executeProviderConfigHook(plugin); // Setup provider config first
 * executeDeploymentHook(plugin);     // Run pre-flight checks
 * // Will throw if memoryCheck=true and memory is insufficient
 * // Will throw if chalkCheck=true and chalk binary is missing
 * ```
 */
export function executeDeploymentHook(
    plugin: CrashOverrideServerlessPlugin,
): void {
    const hook = plugin.hooks["after:package:createDeploymentArtifacts"];
    if (hook) {
        hook();
    }
}

/**
 * Executes the service mutation lifecycle hook.
 *
 * **Lifecycle Hook:** `before:package:compileFunctions`
 *
 * **Purpose:** Mutates the Serverless service definition by adding Dust Lambda
 * Extensions to all functions and injecting chalk binary into the deployment
 * package. This is an async operation that fetches region-specific ARNs.
 *
 * **Common Testing Contexts:**
 * - Testing Lambda Extension addition to functions
 * - Testing ARN fetching for specific AWS regions
 * - Testing layer limit validation (max 15 layers/extensions per function)
 * - Testing chalk binary injection into deployment packages
 * - Testing error handling when provider config is missing
 *
 * **Important:** This is an ASYNC function and must be awaited in tests
 *
 * @param plugin - The plugin instance to execute the hook on
 * @returns Promise that resolves when the hook completes
 *
 * @example
 * ```typescript
 * executeProviderConfigHook(plugin);  // Setup provider config
 * executeDeploymentHook(plugin);      // Run pre-flight checks
 * await executeAwsPackageHook(plugin); // Mutate service (note the await!)
 * // Functions now have Dust Extension added to their layers
 * ```
 */
export async function executeAwsPackageHook(
    plugin: CrashOverrideServerlessPlugin,
): Promise<void> {
    const hook = plugin.hooks["before:package:compileFunctions"];
    if (hook) {
        await hook();
    }
}

/**
 * Fluent builder for creating complex test scenarios.
 *
 * Provides a chainable API for configuring plugin instances with specific
 * settings, mock behaviors, and serverless configurations. This builder
 * handles mock setup automatically based on the configuration.
 *
 * @example
 * ```typescript
 * const { plugin, mockLog } = new TestSetupBuilder()
 *   .withMemoryCheck(true, 512)        // Enable memory check with 512MB minimum
 *   .withProviderMemory(1024)           // Set provider memory to 1024MB
 *   .withChalkAvailable()               // Mock chalk binary as available
 *   .withFunctions(sampleFunctions)     // Add Lambda functions
 *   .withEnvironmentVar("CO_MEMORY_CHECK", "true") // Set env vars
 *   .build();
 * ```
 */
export class TestSetupBuilder {
    private serverlessOverrides: any = {};
    private envVars: Record<string, string> = {};
    private chalkAvailable: boolean = false;
    private packageZipExists: boolean = false;

    /**
     * Configures memory check validation settings.
     *
     * @param enabled - Whether to enforce memory checks (fail vs warn)
     * @param size - Minimum required memory size in MB (default: 256)
     * @returns this for method chaining
     */
    withMemoryCheck(enabled: boolean, size: number = 256): this {
        if (!this.serverlessOverrides.service) {
            this.serverlessOverrides.service = {};
        }
        if (!this.serverlessOverrides.service.custom) {
            this.serverlessOverrides.service.custom = {};
        }
        if (!this.serverlessOverrides.service.custom.crashoverride) {
            this.serverlessOverrides.service.custom.crashoverride = {};
        }
        this.serverlessOverrides.service.custom.crashoverride.memoryCheck =
            enabled;
        this.serverlessOverrides.service.custom.crashoverride.memoryCheckSize =
            size;
        return this;
    }

    /**
     * Configures chalk binary requirement.
     *
     * @param enabled - Whether to enforce chalk binary presence (fail vs warn)
     * @returns this for method chaining
     */
    withChalkCheck(enabled: boolean): this {
        if (!this.serverlessOverrides.service) {
            this.serverlessOverrides.service = {};
        }
        if (!this.serverlessOverrides.service.custom) {
            this.serverlessOverrides.service.custom = {};
        }
        if (!this.serverlessOverrides.service.custom.crashoverride) {
            this.serverlessOverrides.service.custom.crashoverride = {};
        }
        this.serverlessOverrides.service.custom.crashoverride.chalkCheck =
            enabled;
        return this;
    }

    /**
     * Sets the provider-level memory size configuration.
     *
     * @param size - Memory size in MB for Lambda functions
     * @returns this for method chaining
     */
    withProviderMemory(size: number): this {
        if (!this.serverlessOverrides.service) {
            this.serverlessOverrides.service = {};
        }
        if (!this.serverlessOverrides.service.provider) {
            this.serverlessOverrides.service.provider = {};
        }
        this.serverlessOverrides.service.provider.memorySize = size;
        return this;
    }

    /**
     * Sets the AWS region for the provider.
     *
     * @param region - AWS region (e.g., 'us-east-1', 'eu-west-1')
     * @returns this for method chaining
     */
    withProviderRegion(region: string): this {
        if (!this.serverlessOverrides.service) {
            this.serverlessOverrides.service = {};
        }
        if (!this.serverlessOverrides.service.provider) {
            this.serverlessOverrides.service.provider = {};
        }
        this.serverlessOverrides.service.provider.region = region;
        return this;
    }

    /**
     * Adds Lambda function definitions to the service.
     *
     * @param functions - Object containing function configurations with layers
     * @returns this for method chaining
     *
     * @example
     * ```typescript
     * .withFunctions({
     *   myFunction: {
     *     handler: 'handler.main',
     *     layers: ['arn:aws:lambda:us-east-1:123:layer:existing']
     *   }
     * })
     * ```
     */
    withFunctions(functions: any): this {
        if (!this.serverlessOverrides.service) {
            this.serverlessOverrides.service = {};
        }
        // Deep copy to avoid mutation
        this.serverlessOverrides.service.functions = JSON.parse(
            JSON.stringify(functions),
        );
        return this;
    }

    /**
     * Sets the Serverless service name.
     *
     * @param name - The service name (used for package naming)
     * @returns this for method chaining
     */
    withServiceName(name: string): this {
        if (!this.serverlessOverrides.service) {
            this.serverlessOverrides.service = {};
        }
        this.serverlessOverrides.service.service = name;
        return this;
    }

    /**
     * Sets the service directory path.
     *
     * @param path - Absolute path to the service directory
     * @returns this for method chaining
     */
    withServicePath(path: string): this {
        if (!this.serverlessOverrides.config) {
            this.serverlessOverrides.config = {};
        }
        this.serverlessOverrides.config.servicePath = path;
        return this;
    }

    /**
     * Sets an environment variable for the test.
     *
     * @param key - Environment variable name (e.g., 'CO_MEMORY_CHECK')
     * @param value - Environment variable value
     * @returns this for method chaining
     */
    withEnvironmentVar(key: string, value: string): this {
        this.envVars[key] = value;
        return this;
    }

    /**
     * Mocks chalk binary as available in the system PATH.
     * Automatically sets up the child_process mock to simulate chalk presence.
     *
     * @returns this for method chaining
     */
    withChalkAvailable(): this {
        this.chalkAvailable = true;
        return this;
    }

    /**
     * Mocks chalk binary as NOT available in the system PATH.
     * Automatically sets up the child_process mock to simulate chalk absence.
     *
     * @returns this for method chaining
     */
    withChalkNotAvailable(): this {
        this.chalkAvailable = false;
        return this;
    }

    /**
     * Mocks the deployment package zip file as existing.
     * Automatically sets up the fs mock to return true for the package path.
     *
     * @param servicePath - Optional custom service path
     * @returns this for method chaining
     */
    withPackageZipExists(servicePath?: string): this {
        this.packageZipExists = true;
        if (servicePath) {
            this.withServicePath(servicePath);
        }
        return this;
    }

    /**
     * Sets custom CrashOverride plugin configuration.
     *
     * @param config - Partial configuration to merge with defaults
     * @returns this for method chaining
     *
     * @example
     * ```typescript
     * .withCustomConfig({
     *   memoryCheck: true,
     *   memoryCheckSize: 512,
     *   chalkCheck: false
     * })
     * ```
     */
    withCustomConfig(config: Partial<CrashOverrideConfig>): this {
        if (!this.serverlessOverrides.service) {
            this.serverlessOverrides.service = {};
        }
        if (!this.serverlessOverrides.service.custom) {
            this.serverlessOverrides.service.custom = {};
        }
        this.serverlessOverrides.service.custom.crashoverride = config;
        return this;
    }

    /**
     * Removes provider configuration to test error handling.
     *
     * @returns this for method chaining
     */
    withNoProvider(): this {
        if (!this.serverlessOverrides.service) {
            this.serverlessOverrides.service = {};
        }
        this.serverlessOverrides.service.provider = undefined;
        return this;
    }

    /**
     * Builds and returns the configured plugin instance with mocks.
     * This method applies all configurations and sets up the appropriate mocks.
     *
     * @returns Object containing plugin, mockServerless, mockLog, and mockOptions
     */
    build(): {
        plugin: CrashOverrideServerlessPlugin;
        mockServerless: Serverless;
        mockLog: ReturnType<typeof createMockLogger>;
        mockOptions: any;
    } {
        // Setup mocks based on configuration
        if (this.chalkAvailable) {
            childProcessMock.mockChalkAvailable();
        } else {
            childProcessMock.mockChalkNotAvailable();
        }

        if (this.packageZipExists) {
            const servicePath = this.serverlessOverrides.config?.servicePath;
            fsMock.mockPackageZipExists(servicePath);
        }

        return createPlugin(this.serverlessOverrides, this.envVars);
    }
}

/**
 * Common assertion helpers for testing plugin behavior.
 *
 * @example
 * ```typescript
 * assertions.expectConfigValues(mockLog, true, 512, false);
 * // Verifies that config was logged with memoryCheck=true,
 * // memoryCheckSize=512, chalkCheck=false
 * ```
 */
export const assertions = {
    /**
     * Verifies that configuration values were logged correctly.
     *
     * @param mockLog - The mock logger to check calls on
     * @param memoryCheck - Expected memoryCheck value
     * @param memoryCheckSize - Expected memoryCheckSize value
     * @param chalkCheck - Expected chalkCheck value
     */
    expectConfigValues(
        mockLog: any,
        memoryCheck: boolean,
        memoryCheckSize: number,
        chalkCheck: boolean,
    ): void {
        expect(mockLog.info).toHaveBeenCalledWith(
            expect.stringContaining(`memoryCheck=${memoryCheck}`),
        );
        expect(mockLog.info).toHaveBeenCalledWith(
            expect.stringContaining(`memoryCheckSize=${memoryCheckSize}`),
        );
        expect(mockLog.info).toHaveBeenCalledWith(
            expect.stringContaining(`chalkCheck=${chalkCheck}`),
        );
    },
};
