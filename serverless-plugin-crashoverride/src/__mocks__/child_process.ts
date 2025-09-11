/**
 * Mock for Node.js child_process module
 *
 * This mock simulates the `execSync` function to test chalk binary detection
 * and injection without actually executing system commands.
 *
 * @module __mocks__/child_process
 */

/**
 * Mock implementation of execSync from child_process.
 * Behavior is controlled by helper functions below.
 */
export const execSync = jest.fn();

/**
 * Configures the mock to simulate chalk binary being available.
 *
 * When configured:
 * - `command -v chalk` returns a path to chalk binary
 * - `chalk insert` commands succeed with a success message
 *
 * @example
 * ```typescript
 * import * as childProcessMock from './__mocks__/child_process';
 *
 * beforeEach(() => {
 *   childProcessMock.mockChalkAvailable();
 * });
 *
 * // Now execSync('command -v chalk') will succeed
 * // And execSync('chalk insert ...') will return success
 * ```
 */
export function mockChalkAvailable() {
    execSync.mockImplementation((command: string) => {
        if (command === "which chalk") {
            return Buffer.from("/usr/local/bin/chalk");
        }
        if (command.includes("chalk insert")) {
            return Buffer.from("Successfully injected chalk");
        }
        throw new Error(`Unexpected command: ${command}. Update your mocks`);
    });
}

/**
 * Configures the mock to simulate chalk binary NOT being available.
 *
 * When configured:
 * - `command -v chalk` throws an error
 * - Any chalk commands throw an error
 *
 * @example
 * ```typescript
 * import * as childProcessMock from './__mocks__/child_process';
 *
 * beforeEach(() => {
 *   childProcessMock.mockChalkNotAvailable();
 * });
 *
 * // Now execSync('command -v chalk') will throw
 * // This simulates chalk not being installed
 * ```
 */
export function mockChalkNotAvailable() {
    execSync.mockImplementation((command: string) => {
        if (command === "which chalk") {
            throw new Error("command not found: chalk");
        }
        throw new Error(`Unexpected command: ${command}. Update your mocks`);
    });
}

/**
 * Resets all mock implementations and call history.
 *
 * @example
 * ```typescript
 * afterEach(() => {
 *   childProcessMock.resetMocks();
 * });
 * ```
 */
export function resetMocks() {
    execSync.mockReset();
}
