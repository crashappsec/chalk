/**
 * Mock for Node.js fs module
 *
 * This mock simulates file system operations, specifically the `existsSync`
 * function to test package zip file detection without actual file I/O,
 * and `readFileSync` for reading CloudFormation templates.
 *
 * @module __mocks__/fs
 */

/**
 * Mock implementation of existsSync from fs module.
 * Behavior is controlled by helper functions below.
 */
export const existsSync = jest.fn();

/**
 * Mock implementation of readFileSync from fs module.
 * Behavior is controlled by helper functions below.
 */
export const readFileSync = jest.fn();

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
 * Configures the mock to return a CloudFormation template when readFileSync is called.
 *
 * @param template - The CloudFormation template object to return
 * @param servicePath - The service directory path (default: '/test/service/path')
 *
 * @example
 * ```typescript
 * import * as fsMock from './__mocks__/fs';
 *
 * const template = {
 *   Resources: {
 *     MyFunction: {
 *       Type: "AWS::Lambda::Function",
 *       Properties: {
 *         Layers: ["arn:aws:lambda:us-east-1:123:layer:dust-extension:1"]
 *       }
 *     }
 *   }
 * };
 *
 * fsMock.mockCloudFormationTemplate(template);
 * ```
 */
export function mockCloudFormationTemplate(
    template: any,
    servicePath: string = "/test/service/path",
) {
    readFileSync.mockImplementation((path: string) => {
        if (
            path ===
            `${servicePath}/.serverless/cloudformation-template-update-stack.json`
        ) {
            return JSON.stringify(template);
        }
        throw new Error(`ENOENT: no such file or directory, open '${path}'`);
    });
}

/**
 * Configures the mock to throw an error when attempting to read the CloudFormation template.
 *
 * @param error - The error to throw (default: ENOENT error)
 * @param servicePath - The service directory path (default: '/test/service/path')
 *
 * @example
 * ```typescript
 * fsMock.mockCloudFormationTemplateNotFound();
 * // Now readFileSync will throw ENOENT error
 * ```
 */
export function mockCloudFormationTemplateNotFound(
    error?: Error,
    servicePath: string = "/test/service/path",
) {
    const defaultError = new Error(
        `ENOENT: no such file or directory, open '${servicePath}/.serverless/cloudformation-template-update-stack.json'`,
    );
    (defaultError as any).code = "ENOENT";

    readFileSync.mockImplementation(() => {
        throw error || defaultError;
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
    readFileSync.mockReset();
}
