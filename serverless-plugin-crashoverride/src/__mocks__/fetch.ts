/**
 * Mock for global fetch API
 *
 * This mock simulates HTTP requests for fetching Dust Lambda Extension ARNs
 * from remote endpoints. It extracts the AWS region and version from the URL and returns
 * a properly formatted ARN without making actual network requests.
 *
 * **URL Pattern:**
 * - `https://dl.crashoverride.run/dust/{region}/extension.arn`
 * - `https://dl.crashoverride.run/dust/{region}/extension-v{version}.arn`
 *
 * **Return Format:** `arn:aws:lambda:{region}:123456789012:layer:test-crashoverride-dust-extension:{version}`
 *
 * @module __mocks__/fetch
 *
 * @example
 * ```typescript
 * // When the plugin calls:
 * // fetch('https://dl.crashoverride.run/dust/us-west-2/extension.arn')
 *
 * // The mock returns:
 * // 'arn:aws:lambda:us-west-2:123456789012:layer:test-crashoverride-dust-extension:8'
 * ```
 *
 * Note how `us-west-2` was passed in the URL and is returned in the ARN value.
 */

// Store custom ARN if set
let customArn: string | null = null;

/**
 * Mock implementation of global fetch function.
 *
 * Simulates fetching Dust Extension ARNs by:
 * 1. Extracting the AWS region and version from the URL
 * 2. Returning a formatted ARN with that region and version
 * 3. Providing a Response-like object with text() method
 *
 * @param url - The URL to fetch (expects pattern with /{region}/extension.arn)
 * @returns Promise resolving to a mock Response object
 */
export const fetch = jest.fn((url: string) => {
  // Extract region and version from URL pattern:
  // - https://dl.crashoverride.run/dust/{region}/extension.arn
  // - https://dl.crashoverride.run/dust/{region}/extension-v{version}.arn
  const regionMatch = url.match(/\/dust\/([^/]+)\/extension(?:-v(\d+))?\.arn/);
  const region = regionMatch ? regionMatch[1] : "us-east-1";
  const version = regionMatch?.[2] || "8"; // Default to version 8 if not specified

  // Use custom ARN if set, otherwise generate based on region and version
  const arn =
    customArn ||
    `arn:aws:lambda:${region}:123456789012:layer:test-crashoverride-dust-extension:${version}`;

  return Promise.resolve({
    ok: true,
    status: 200,
    text: () => Promise.resolve(arn),
  } as Response);
});

/**
 * Sets a custom ARN to be returned by the mock fetch function.
 * This overrides the automatic region-based ARN generation.
 *
 * @param arn - The custom ARN to return for all requests
 *
 * @example
 * ```typescript
 * import * as fetchMock from './__mocks__/fetch';
 *
 * fetchMock.mockDustExtensionArn('arn:aws:lambda:us-east-1:123:layer:custom:1');
 * // Now all fetch requests will return this specific ARN
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
 * import * as fetchMock from './__mocks__/fetch';
 *
 * afterEach(() => {
 *   fetchMock.resetMock();
 * });
 * ```
 */
export function resetMock(): void {
  customArn = null;
  fetch.mockClear();
}
