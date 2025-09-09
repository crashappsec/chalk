/**
 * Mock for Node.js fs module
 *
 * This mock simulates file system operations, specifically the `existsSync`
 * function to test package zip file detection without actual file I/O.
 *
 * @module __mocks__/fs
 */

/**
 * Mock implementation of existsSync from fs module.
 * Behavior is controlled by helper functions below.
 */
export const existsSync = jest.fn();

/**
 * Configures the mock to simulate that the deployment package zip exists.
 *
 * The mock will return true for the expected package path:
 * `{servicePath}/.serverless/test-service.zip`
 *
 * @param servicePath - The service directory path (default: '/test/service/path')
 *
 * @example
 * ```typescript
 * import * as fsMock from './__mocks__/fs';
 *
 * beforeEach(() => {
 *   // Simulate package exists at default location
 *   fsMock.mockPackageZipExists();
 *
 *   // Or with custom path
 *   fsMock.mockPackageZipExists('/custom/project/path');
 * });
 *
 * // Now existsSync('/test/service/path/.serverless/test-service.zip') returns true
 * ```
 */
export function mockPackageZipExists(
    servicePath: string = "/test/service/path",
) {
    existsSync.mockImplementation((path: string) => {
        if (path === `${servicePath}/.serverless/test-service.zip`) {
            return true;
        }
        return false;
    });
}

/**
 * Resets all mock implementations and call history.
 *
 * @example
 * ```typescript
 * afterEach(() => {
 *   fsMock.resetMocks();
 * });
 * ```
 */
export function resetMocks() {
    existsSync.mockReset();
}
