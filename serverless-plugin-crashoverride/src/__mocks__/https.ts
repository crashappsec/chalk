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
    on: (
        event: string,
        callback: (error?: Error) => void,
    ) => MockRequestOptions;
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
    (
        url: string,
        callback: (res: MockIncomingMessage) => void,
    ): MockRequestOptions => {
        // Extract region from URL pattern: https://dl.crashoverride.run/test/dust/{region}/extension.arn
        const regionMatch = url.match(/\/dust\/([^/]+)\/extension\.arn/);
        const region = regionMatch ? regionMatch[1] : "us-east-1";

        const mockResponse = new MockIncomingMessage(200);

        // Simulate async response
        setImmediate(() => {
            callback(mockResponse);

            // Emit the ARN data with the extracted region
            const arn = `arn:aws:lambda:${region}:123456789012:layer:test-crashoverride-dust-extension:8`;
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
    },
);

export default { get };
