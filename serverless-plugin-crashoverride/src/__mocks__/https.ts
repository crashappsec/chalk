/**
 * Mock for Node.js https module
 *
 * This mock simulates HTTPS requests for fetching Dust Lambda Extension ARNs
 * from remote endpoints. It extracts the AWS region from the URL and returns
 * a properly formatted ARN without making actual network requests.
 *
 * **URL Pattern:** `https://dl.crashoverride.run/test/dust/{region}/extension.arn`
 *
 * **Return Format:** `arn:aws:lambda:{region}:123456789012:layer:test-crashoverride-dust-extension:8`
 *
 * @module __mocks__/https
 *
 * @example
 * ```typescript
 * // When the plugin calls:
 * // https.get('https://dl.crashoverride.run/dust/us-west-2/extension.arn', callback)
 *
 * // The mock returns:
 * // 'arn:aws:lambda:us-west-2:123456789012:layer:crashoverride-dust-extension:8'
 * ```
 *
 * Note how `us-west-2` was passed in the URL and is returned in the ARN value.
 */

import { EventEmitter } from "events";

interface MockRequestOptions {
  on: (event: string, callback: (error?: Error) => void) => MockRequestOptions;
}

/**
 * Mock implementation of Node.js IncomingMessage for HTTP responses.
 */
class MockIncomingMessage extends EventEmitter {
  statusCode: number;

  constructor(statusCode: number = 200) {
    super();
    this.statusCode = statusCode;
  }
}

// Store custom ARN if set
let customArn: string | null = null;

/**
 * Mock implementation of https.get function.
 *
 * Simulates fetching Dust Extension ARNs by:
 * 1. Extracting the AWS region from the URL
 * 2. Returning a formatted ARN with that region
 * 3. Using setImmediate to simulate async network behavior
 *
 * @param url - The URL to fetch (expects pattern with /{region}/extension.arn)
 * @param callback - Callback that receives the mock response
 * @returns Mock request object with error handling
 */
export const get = jest.fn(
  (url: string, callback: (res: MockIncomingMessage) => void): MockRequestOptions => {
    // Extract region and version from URL pattern:
    // - https://dl.crashoverride.run/test/dust/{region}/extension.arn
    // - https://dl.crashoverride.run/test/dust/{region}/extension-v{version}.arn
    const regionMatch = url.match(/\/dust\/([^/]+)\/extension(?:-v(\d+))?\.arn/);
    const region = regionMatch ? regionMatch[1] : "us-east-1";
    const version = regionMatch?.[2] || "8"; // Default to version 8 if not specified

    const mockResponse = new MockIncomingMessage(200);

    // Simulate async response
    setImmediate(() => {
      callback(mockResponse);

      // Emit the ARN data - use custom ARN if set, otherwise generate based on region and version
      const arn =
        customArn ||
        `arn:aws:lambda:${region}:123456789012:layer:test-crashoverride-dust-extension:${version}`;
      mockResponse.emit("data", arn);
      mockResponse.emit("end");
    });

    // Return a mock request object
    return {
      on: jest.fn((): MockRequestOptions => {
        // Mock error handler - by default no errors
        return { on: jest.fn() } as MockRequestOptions;
      }),
    } as MockRequestOptions;
  }
);

/**
 * Sets a custom ARN to be returned by the mock https.get function.
 * This overrides the automatic region-based ARN generation.
 *
 * @param arn - The custom ARN to return for all requests
 *
 * @example
 * ```typescript
 * import * as httpsMock from './__mocks__/https';
 *
 * httpsMock.mockDustExtensionArn('arn:aws:lambda:us-east-1:123:layer:custom:1');
 * // Now all https.get requests will return this specific ARN
 * ```
 */
export function mockDustExtensionArn(arn: string): void {
  customArn = arn;
}

/**
 * Resets the mock to use automatic region-based ARN generation.
 *
 * @example
 * ```typescript
 * httpsMock.resetMock();
 * // Now https.get will generate ARNs based on the region in the URL
 * ```
 */
export function resetMock(): void {
  customArn = null;
  get.mockClear();
}

export default { get };
