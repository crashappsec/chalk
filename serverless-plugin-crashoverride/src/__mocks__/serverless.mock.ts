/**
 * Mock for Serverless Framework types and instances
 *
 * Provides factory functions for creating mock Serverless instances,
 * loggers, and options for testing the plugin without a real Serverless
 * Framework environment.
 *
 * @module __mocks__/serverless.mock
 */

import type Serverless from "serverless";

/**
 * Mock implementation of Serverless Framework Error class.
 * Used to simulate user-facing errors (configuration errors, validation failures, etc.)
 */
export class ServerlessError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "ServerlessError";
    }
}

/**
 * Creates a mock Serverless Framework instance with customizable configuration.
 *
 * @param options - Optional overrides for service and config properties
 * @returns Mock Serverless instance with default AWS provider configuration
 *
 * @example
 * ```typescript
 * // Create with defaults
 * const mockServerless = createMockServerless();
 *
 * // Create with custom service configuration
 * const mockServerless = createMockServerless({
 *   service: {
 *     custom: {
 *       crashoverride: {
 *         memoryCheck: true,
 *         memoryCheckSize: 512
 *       }
 *     },
 *     functions: {
 *       myFunc: { handler: 'index.handler' }
 *     }
 *   }
 * });
 * ```
 */
export function createMockServerless(
    options: { service?: any; config?: any } = {},
): Serverless {
    const mockServerless: Serverless = {
        service: {
            service: "test-service",
            provider: {
                name: "aws",
                runtime: "nodejs18.x",
                region: "us-east-1",
                memorySize: 1024,
                stage: "dev",
                ...options.service?.provider,
            } as any,
            custom: options.service?.custom || {},
            functions: options.service?.functions || {},
            layers: options.service?.layers || {},
            resources: options.service?.resources || {},
            ...options.service,
        } as any,

        config: {
            servicePath: "/test/service/path",
            ...options.config,
        } as any,

        classes: {
            Error: ServerlessError,
        } as any,
    } as unknown as Serverless;

    return mockServerless;
}

/**
 * Creates a mock logger with Jest spy functions for all log levels.
 *
 * @returns Mock logger object with jest.fn() for each log method
 *
 * @example
 * ```typescript
 * const mockLog = createMockLogger();
 *
 * // Use in plugin creation
 * const plugin = new CrashOverrideServerlessPlugin(
 *   mockServerless,
 *   mockOptions,
 *   { log: mockLog }
 * );
 *
 * // Assert on log calls
 * expect(mockLog.error).toHaveBeenCalledWith('Error message');
 * expect(mockLog.warning).toHaveBeenCalledTimes(1);
 * ```
 */
export function createMockLogger() {
    return {
        error: jest.fn(),
        warning: jest.fn(),
        notice: jest.fn(),
        success: jest.fn(),
        info: jest.fn(),
    };
}

/**
 * Creates mock Serverless Framework CLI options.
 *
 * @returns Mock options object with common CLI parameters
 *
 * @example
 * ```typescript
 * const mockOptions = createMockOptions();
 * // Returns: { stage: 'dev', region: 'us-east-1' }
 * ```
 */
export function createMockOptions(): any {
    return {
        stage: "dev",
        region: "us-east-1",
    };
}
