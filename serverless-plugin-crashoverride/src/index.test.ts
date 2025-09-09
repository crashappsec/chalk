import type Serverless from "serverless";
import CrashOverrideServerlessPlugin from "../src/index.js";
import { execSync } from "child_process";
import * as fs from "fs";

jest.mock("child_process");
jest.mock("fs");
jest.mock("chalk", () => ({
    __esModule: true,
    default: {
        blue: (text: string) => text,
        green: (text: string) => text,
        yellow: (text: string) => text,
        red: (text: string) => text,
        cyan: (text: string) => text,
        dim: (text: string) => text,
        gray: (text: string) => text,
        bold: (text: string) => text,
    },
}));

const mockServerless = {
    getProvider: jest.fn().mockReturnValue({}),
    config: {
        servicePath: "/test/project",
    },
    service: {
        service: "test-service",
        provider: {
            stage: "dev",
        },
        functions: {
            function1: {},
            function2: {
                layers: [
                    "arn:aws:lambda:us-east-1:123456789012:layer:existing1",
                    "arn:aws:lambda:us-east-1:123456789012:layer:existing2",
                ],
            },
            function3: {
                layers: new Array(14)
                    .fill(0)
                    .map(
                        (_, i) =>
                            `arn:aws:lambda:us-east-1:123456789012:layer:layer${i}`,
                    ),
            },
            function4: {
                layers: new Array(15)
                    .fill(0)
                    .map(
                        (_, i) =>
                            `arn:aws:lambda:us-east-1:123456789012:layer:layer${i}`,
                    ),
            },
        },
    },
} as any as Serverless;

const mockLog = {
    error: jest.fn(),
    warning: jest.fn(),
    notice: jest.fn(),
    info: jest.fn(),
    debug: jest.fn(),
};

describe("CrashOverrideServerlessPlugin", () => {
    let plugin: CrashOverrideServerlessPlugin;

    beforeEach(() => {
        plugin = new CrashOverrideServerlessPlugin(
            mockServerless,
            {},
            { log: mockLog },
        );
    });

    afterEach(() => {
        jest.clearAllMocks();
    });

    it("should initialize with correct properties", () => {
        expect(plugin.serverless).toBe(mockServerless);
        expect(plugin.options).toEqual({});
        expect(plugin.hooks).toBeDefined();
    });

    it("should have the correct hooks registered", () => {
        expect(plugin.hooks["before:package:initialize"]).toBeDefined();
        expect(
            plugin.hooks[
                "after:aws:package:finalize:mergeCustomProviderResources"
            ],
        ).toBeDefined();
    });

    it("should log before package initialize and check for chalk binary", async () => {
        const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;
        mockExecSync.mockImplementation(() => Buffer.from(""));

        const hook = plugin.hooks["before:package:initialize"];
        if (hook) {
            await hook();
        }

        expect(mockLog.notice).toHaveBeenCalledWith(
            "🔧 Dust Plugin: Initializing package process",
        );
        expect(mockLog.info).toHaveBeenCalledWith(
            "ℹ Checking for chalk binary...",
        );
        expect(mockLog.info).toHaveBeenCalledWith("✓ Chalk binary found");
        expect(mockLog.info).toHaveBeenCalledWith(
            "ℹ Chalk binary found and will be used to add chalkmarks",
        );
        expect(mockExecSync).toHaveBeenCalledWith("command -v chalk", {
            stdio: "ignore",
        });
    });

    it("should handle chalk binary not found", () => {
        const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;
        mockExecSync.mockImplementation(() => {
            throw new Error("Command not found");
        });

        const result = (plugin as any).chalkBinaryAvailable();

        expect(result).toBe(false);
        expect(mockLog.info).toHaveBeenCalledWith(
            "ℹ Checking for chalk binary...",
        );
        expect(mockLog.info).toHaveBeenCalledWith(
            "ℹ Chalk binary not found in PATH",
        );
    });

    it("should run both addDustLambdaExtension and injectChalkBinary after package initialize", async () => {
        const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;
        const mockFs = fs as jest.Mocked<typeof fs>;

        // Create plugin with functions that won't exceed layer limit
        const integrationPlugin = new CrashOverrideServerlessPlugin(
            {
                ...mockServerless,
                service: {
                    ...mockServerless.service,
                    functions: {
                        function1: {},
                        function2: { layers: ["existing-layer-1"] },
                    },
                },
            } as any,
            {},
            { log: mockLog },
        );

        mockExecSync.mockImplementation((cmd: string) => {
            if (cmd === "command -v chalk") {
                return Buffer.from("");
            }
            if (cmd.includes("chalk insert")) {
                return Buffer.from("Successfully inserted chalkmarks");
            }
            return Buffer.from("");
        });

        mockFs.existsSync.mockReturnValue(true);

        // Set chalk as available since we're mocking it to succeed
        (integrationPlugin as any).isChalkAvailable = true;

        const hook =
            integrationPlugin.hooks[
                "after:aws:package:finalize:mergeCustomProviderResources"
            ];
        if (hook) {
            await hook();
        }

        // Check that afterPackageInitialize was called
        expect(mockLog.notice).toHaveBeenCalledWith(
            "📦 Dust Plugin: Processing packaged functions",
        );

        // Check that addDustLambdaExtension was called
        expect(mockLog.notice).toHaveBeenCalledWith(
            "🚀 Adding Dust Lambda Extension to all functions",
        );
        expect(mockLog.notice).toHaveBeenCalledWith(
            "✓ Successfully added Dust Lambda Extension to 2 function(s)",
        );

        // Check that injectChalkBinary was called
        expect(mockLog.info).toHaveBeenCalledWith(
            expect.stringContaining("ℹ Injecting chalkmarks into"),
        );
        expect(mockLog.notice).toHaveBeenCalledWith(
            "✓ Successfully injected chalkmarks into package",
        );
        expect(mockExecSync).toHaveBeenCalledWith(
            expect.stringContaining("chalk insert --inject-binary-into-zip"),
            { stdio: "pipe", encoding: "utf8" },
        );
    });

    it("should skip chalkmark injection when chalk is not available", async () => {
        const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;

        // Create plugin with functions that won't exceed layer limit
        const chalkUnavailablePlugin = new CrashOverrideServerlessPlugin(
            {
                ...mockServerless,
                service: {
                    ...mockServerless.service,
                    functions: {
                        function1: {},
                    },
                },
            } as any,
            {},
            { log: mockLog },
        );

        mockExecSync.mockImplementation((cmd: string) => {
            if (cmd === "command -v chalk") {
                throw new Error("Command not found");
            }
            return Buffer.from("");
        });

        const hook =
            chalkUnavailablePlugin.hooks[
                "after:aws:package:finalize:mergeCustomProviderResources"
            ];
        if (hook) {
            await hook();
        }

        expect(mockLog.notice).toHaveBeenCalledWith(
            "📦 Dust Plugin: Processing packaged functions",
        );
        expect(mockLog.info).toHaveBeenCalledWith(
            expect.stringMatching(
                /⚠ Chalk binary not available, skipping chalkmark injection/,
            ),
        );
    });

    it("should handle missing zip file", async () => {
        const mockExecSync = execSync as jest.MockedFunction<typeof execSync>;
        const mockFs = fs as jest.Mocked<typeof fs>;

        // Create plugin with functions that won't exceed layer limit
        const zipMissingPlugin = new CrashOverrideServerlessPlugin(
            {
                ...mockServerless,
                service: {
                    ...mockServerless.service,
                    functions: {
                        function1: {},
                    },
                },
            } as any,
            {},
            { log: mockLog },
        );

        mockExecSync.mockImplementation((cmd: string) => {
            if (cmd === "command -v chalk") {
                return Buffer.from("");
            }
            return Buffer.from("");
        });

        mockFs.existsSync.mockReturnValue(false);

        // Set chalk as available since we're mocking it to succeed
        (zipMissingPlugin as any).isChalkAvailable = true;

        const hook =
            zipMissingPlugin.hooks[
                "after:aws:package:finalize:mergeCustomProviderResources"
            ];
        if (hook) {
            await hook();
        }

        expect(mockLog.notice).toHaveBeenCalledWith(
            "📦 Dust Plugin: Processing packaged functions",
        );
        expect(mockLog.warning).toHaveBeenCalledWith(
            "⚠ Package zip file not found at /test/project/.serverless/test-service.zip",
        );
        expect(mockLog.error).toHaveBeenCalledWith(
            "✗ Could not locate package zip file",
        );
    });

    it("should add dust Lambda Extension to functions with no existing layers", () => {
        // Create a simple mock serverless with one function
        const simplePlugin = new CrashOverrideServerlessPlugin(
            {
                ...mockServerless,
                service: {
                    ...mockServerless.service,
                    functions: {
                        testFunction: {},
                    },
                },
            } as any,
            {},
            { log: mockLog },
        );

        (simplePlugin as any).addDustLambdaExtension();

        expect(mockLog.notice).toHaveBeenCalledWith(
            "🚀 Adding Dust Lambda Extension to all functions",
        );
        expect(mockLog.info).toHaveBeenCalledWith(
            "ℹ Added Dust Lambda Extension to function: testFunction (1/15 layers/extensions)",
        );
        expect(mockLog.notice).toHaveBeenCalledWith(
            "✓ Successfully added Dust Lambda Extension to 1 function(s)",
        );

        // Verify the layer was actually added
        const func = (simplePlugin.serverless.service.functions as any)[
            "testFunction"
        ];
        expect(func.layers).toEqual([
            "arn:aws:lambda:us-east-1:123456789012:layer:my-extension",
        ]);
    });

    it("should add dust Lambda Extension to functions with existing layers", () => {
        // Create a plugin with function that has 2 existing layers
        const pluginWithLayers = new CrashOverrideServerlessPlugin(
            {
                ...mockServerless,
                service: {
                    ...mockServerless.service,
                    functions: {
                        testFunction: {
                            layers: ["existing-layer-1", "existing-layer-2"],
                        },
                    },
                },
            } as any,
            {},
            { log: mockLog },
        );

        (pluginWithLayers as any).addDustLambdaExtension();

        expect(mockLog.info).toHaveBeenCalledWith(
            "ℹ Added Dust Lambda Extension to function: testFunction (3/15 layers/extensions)",
        );
        expect(mockLog.notice).toHaveBeenCalledWith(
            "✓ Successfully added Dust Lambda Extension to 1 function(s)",
        );

        // Verify the layer was added to existing layers
        const func = (pluginWithLayers.serverless.service.functions as any)[
            "testFunction"
        ];
        expect(func.layers).toEqual([
            "existing-layer-1",
            "existing-layer-2",
            "arn:aws:lambda:us-east-1:123456789012:layer:my-extension",
        ]);
    });

    it("should handle function with 14 existing layers (should accept extension)", () => {
        const pluginWith14Layers = new CrashOverrideServerlessPlugin(
            {
                ...mockServerless,
                service: {
                    ...mockServerless.service,
                    functions: {
                        testFunction: {
                            layers: new Array(14)
                                .fill(0)
                                .map((_, i) => `layer-${i}`),
                        },
                    },
                },
            } as any,
            {},
            { log: mockLog },
        );

        (pluginWith14Layers as any).addDustLambdaExtension();

        expect(mockLog.info).toHaveBeenCalledWith(
            "ℹ Added Dust Lambda Extension to function: testFunction (15/15 layers/extensions)",
        );
        expect(mockLog.notice).toHaveBeenCalledWith(
            "✓ Successfully added Dust Lambda Extension to 1 function(s)",
        );
    });

    it("should throw error when function has 15 existing layers", () => {
        const pluginWith15Layers = new CrashOverrideServerlessPlugin(
            {
                ...mockServerless,
                service: {
                    ...mockServerless.service,
                    functions: {
                        testFunction: {
                            layers: new Array(15)
                                .fill(0)
                                .map((_, i) => `layer-${i}`),
                        },
                    },
                },
            } as any,
            {},
            { log: mockLog },
        );

        expect(() => {
            (pluginWith15Layers as any).addDustLambdaExtension();
        }).toThrow(
            "Cannot add Dust Lambda Extension to function testFunction: would exceed maximum layer/extension limit of 15 (currently has 15)",
        );

        expect(mockLog.error).toHaveBeenCalledWith(
            "✗ Cannot add Dust Lambda Extension to function testFunction: would exceed maximum layer/extension limit of 15 (currently has 15)",
        );
    });

    it("should handle service with no functions", () => {
        const pluginNoFunctions = new CrashOverrideServerlessPlugin(
            {
                ...mockServerless,
                service: {
                    ...mockServerless.service,
                    functions: {},
                },
            } as any,
            {},
            { log: mockLog },
        );

        (pluginNoFunctions as any).addDustLambdaExtension();

        expect(mockLog.notice).toHaveBeenCalledWith(
            "🚀 Adding Dust Lambda Extension to all functions",
        );
        expect(mockLog.warning).toHaveBeenCalledWith(
            "⚠ No functions found in service - no extensions added",
        );
    });

    it("should validate all functions before modifying any (atomic operation)", () => {
        const pluginMixedFunctions = new CrashOverrideServerlessPlugin(
            {
                ...mockServerless,
                service: {
                    ...mockServerless.service,
                    functions: {
                        validFunction: { layers: [] },
                        invalidFunction: {
                            layers: new Array(15)
                                .fill(0)
                                .map((_, i) => `layer-${i}`),
                        },
                    },
                },
            } as any,
            {},
            { log: mockLog },
        );

        expect(() => {
            (pluginMixedFunctions as any).addDustLambdaExtension();
        }).toThrow(
            "Cannot add Dust Lambda Extension to function invalidFunction: would exceed maximum layer/extension limit of 15 (currently has 15)",
        );

        // Verify that the valid function was not modified
        const validFunc = (
            pluginMixedFunctions.serverless.service.functions as any
        )["validFunction"];
        expect(validFunc.layers).toEqual([]); // Should still be empty array, not modified
    });

    describe("Memory Check Feature", () => {
        let memoryCheckPlugin: CrashOverrideServerlessPlugin;

        afterEach(() => {
            jest.clearAllMocks();
        });

        it("should throw error when memoryCheck is true and memory < 512MB", () => {
            memoryCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        provider: {
                            ...mockServerless.service.provider,
                            memorySize: 256,
                        },
                        custom: {
                            crashoverride: {
                                memoryCheck: true,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const hook = memoryCheckPlugin.hooks["before:package:initialize"];

            if (hook) {
                expect(() => hook()).toThrow(
                    "Memory check failed: memorySize (256MB) is less than minimum required (512MB)",
                );
                expect(mockLog.error).toHaveBeenCalledWith(
                    "✗ Memory check failed: memorySize (256MB) is less than minimum required (512MB)",
                );
            }
        });

        it("should succeed when memoryCheck is true and memory >= 512MB", async () => {
            memoryCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        provider: {
                            ...mockServerless.service.provider,
                            memorySize: 1024,
                        },
                        custom: {
                            crashoverride: {
                                memoryCheck: true,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation(() => Buffer.from(""));

            const hook = memoryCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                await hook();
            }

            expect(mockLog.info).toHaveBeenCalledWith(
                "✓ Memory check passed: 1024MB >= 512MB",
            );
            expect(mockLog.error).not.toHaveBeenCalled();
        });

        it("should succeed when memoryCheck is true and memory = 512MB (edge case)", async () => {
            memoryCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        provider: {
                            ...mockServerless.service.provider,
                            memorySize: 512,
                        },
                        custom: {
                            crashoverride: {
                                memoryCheck: true,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation(() => Buffer.from(""));

            const hook = memoryCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                await hook();
            }

            expect(mockLog.info).toHaveBeenCalledWith(
                "✓ Memory check passed: 512MB >= 512MB",
            );
            expect(mockLog.error).not.toHaveBeenCalled();
        });

        it("should log warning when memoryCheck is false and memory < 512MB", async () => {
            memoryCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        provider: {
                            ...mockServerless.service.provider,
                            memorySize: 128,
                        },
                        custom: {
                            crashoverride: {
                                memoryCheck: false,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation(() => Buffer.from(""));

            const hook = memoryCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                await hook();
            }

            expect(mockLog.warning).toHaveBeenCalledWith(
                "⚠ Memory size (128MB) is below recommended minimum (512MB). Set custom.crashoverride.memoryCheck: true to enforce this requirement",
            );
            expect(mockLog.error).not.toHaveBeenCalled();
        });

        it("should log warning when memoryCheck is undefined (default) and memory < 512MB", async () => {
            memoryCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        provider: {
                            ...mockServerless.service.provider,
                            memorySize: 256,
                        },
                        custom: {}, // No crashoverride config
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation(() => Buffer.from(""));

            const hook = memoryCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                await hook();
            }

            expect(mockLog.warning).toHaveBeenCalledWith(
                "⚠ Memory size (256MB) is below recommended minimum (512MB). Set custom.crashoverride.memoryCheck: true to enforce this requirement",
            );
            expect(mockLog.error).not.toHaveBeenCalled();
        });

        it("should handle missing memorySize when memoryCheck is true", async () => {
            memoryCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        provider: {
                            // No memorySize defined
                            stage: "dev",
                        },
                        custom: {
                            crashoverride: {
                                memoryCheck: true,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation(() => Buffer.from(""));

            const hook = memoryCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                await hook();
            }

            expect(mockLog.warning).toHaveBeenCalledWith(
                "⚠ Memory check enabled but no memorySize configured in provider",
            );
            expect(mockLog.error).not.toHaveBeenCalled();
        });

        it("should not log anything when memoryCheck is false and memorySize >= 512MB", async () => {
            memoryCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        provider: {
                            ...mockServerless.service.provider,
                            memorySize: 1024,
                        },
                        custom: {
                            crashoverride: {
                                memoryCheck: false,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation(() => Buffer.from(""));

            const hook = memoryCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                await hook();
            }

            // Should only see the standard initialization logs, no memory check logs
            expect(mockLog.notice).toHaveBeenCalledWith(
                "🔧 Dust Plugin: Initializing package process",
            );
            // Should not log any memory-related messages
            expect(mockLog.info).not.toHaveBeenCalledWith(
                expect.stringContaining("Memory check"),
            );
            expect(mockLog.warning).not.toHaveBeenCalledWith(
                expect.stringContaining("Memory"),
            );
            expect(mockLog.error).not.toHaveBeenCalledWith(
                expect.stringContaining("Memory"),
            );
        });

        it("should integrate with full plugin lifecycle", async () => {
            // Test that memory check doesn't interfere with other plugin functionality
            const integrationPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        provider: {
                            ...mockServerless.service.provider,
                            memorySize: 512,
                        },
                        functions: {
                            testFunction: {},
                        },
                        custom: {
                            crashoverride: {
                                memoryCheck: true,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            const mockFs = fs as jest.Mocked<typeof fs>;

            mockExecSync.mockImplementation((cmd: string) => {
                if (cmd === "command -v chalk") {
                    return Buffer.from("");
                }
                if (cmd.includes("chalk insert")) {
                    return Buffer.from("Success");
                }
                return Buffer.from("");
            });

            mockFs.existsSync.mockReturnValue(true);

            // Run before hook
            const beforeHook =
                integrationPlugin.hooks["before:package:initialize"];
            if (beforeHook) {
                await beforeHook();
            }

            expect(mockLog.info).toHaveBeenCalledWith(
                "✓ Memory check passed: 512MB >= 512MB",
            );

            // Run after hook
            const afterHook =
                integrationPlugin.hooks[
                    "after:aws:package:finalize:mergeCustomProviderResources"
                ];
            if (afterHook) {
                await afterHook();
            }

            // Verify both features work together
            expect(mockLog.notice).toHaveBeenCalledWith(
                "📦 Dust Plugin: Processing packaged functions",
            );
            expect(mockLog.notice).toHaveBeenCalledWith(
                "✓ Successfully added Dust Lambda Extension to 1 function(s)",
            );
            expect(mockLog.notice).toHaveBeenCalledWith(
                "✓ Successfully injected chalkmarks into package",
            );
        });
    });

    describe("chalkCheck feature", () => {
        let chalkCheckPlugin: CrashOverrideServerlessPlugin;

        it("should pass when chalkCheck is true and chalk binary exists", async () => {
            chalkCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        custom: {
                            crashoverride: {
                                chalkCheck: true,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation(() => Buffer.from(""));

            const hook = chalkCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                await hook();
            }

            expect(mockLog.info).toHaveBeenCalledWith(
                "ℹ Checking for chalk binary...",
            );
            expect(mockLog.info).toHaveBeenCalledWith("✓ Chalk binary found");
            expect(mockLog.error).not.toHaveBeenCalled();
        });

        it("should throw error when chalkCheck is true and chalk binary not found", async () => {
            chalkCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        custom: {
                            crashoverride: {
                                chalkCheck: true,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation((command: string) => {
                if (command === "command -v chalk") {
                    throw new Error("Command not found");
                }
                return Buffer.from("");
            });

            const hook = chalkCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                expect(() => hook()).toThrow(
                    "Chalk check failed: chalk binary not found in PATH",
                );
            }

            expect(mockLog.error).toHaveBeenCalledWith(
                "✗ Chalk check failed: chalk binary not found in PATH",
            );
        });

        it("should warn when chalkCheck is false and chalk binary not found", async () => {
            chalkCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        custom: {
                            crashoverride: {
                                chalkCheck: false,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation((command: string) => {
                if (command === "command -v chalk") {
                    throw new Error("Command not found");
                }
                return Buffer.from("");
            });

            const hook = chalkCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                await hook();
            }

            expect(mockLog.warning).toHaveBeenCalledWith(
                "⚠ Chalk binary not available. Continuing without chalkmarks",
            );
            expect(mockLog.error).not.toHaveBeenCalled();
        });

        it("should warn when chalkCheck is undefined (default) and chalk binary not found", async () => {
            chalkCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        custom: {}, // No crashoverride config
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation((command: string) => {
                if (command === "command -v chalk") {
                    throw new Error("Command not found");
                }
                return Buffer.from("");
            });

            const hook = chalkCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                await hook();
            }

            expect(mockLog.warning).toHaveBeenCalledWith(
                "⚠ Chalk binary not available. Continuing without chalkmarks",
            );
            expect(mockLog.error).not.toHaveBeenCalled();
        });

        it("should handle chalkCheck with memoryCheck together", async () => {
            chalkCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        provider: {
                            ...mockServerless.service.provider,
                            memorySize: 512,
                        },
                        custom: {
                            crashoverride: {
                                memoryCheck: true,
                                chalkCheck: true,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation(() => Buffer.from(""));

            const hook = chalkCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                await hook();
            }

            // Both checks should pass
            expect(mockLog.info).toHaveBeenCalledWith(
                "✓ Memory check passed: 512MB >= 512MB",
            );
            expect(mockLog.info).toHaveBeenCalledWith("✓ Chalk binary found");
            expect(mockLog.error).not.toHaveBeenCalled();
        });

        it("should fail fast on chalkCheck failure even if memoryCheck would pass", async () => {
            chalkCheckPlugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        provider: {
                            ...mockServerless.service.provider,
                            memorySize: 1024,
                        },
                        custom: {
                            crashoverride: {
                                memoryCheck: true,
                                chalkCheck: true,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            const mockExecSync = execSync as jest.MockedFunction<
                typeof execSync
            >;
            mockExecSync.mockImplementation((command: string) => {
                if (command === "command -v chalk") {
                    throw new Error("Command not found");
                }
                return Buffer.from("");
            });

            const hook = chalkCheckPlugin.hooks["before:package:initialize"];
            if (hook) {
                expect(() => hook()).toThrow(
                    "Chalk check failed: chalk binary not found in PATH",
                );
            }

            expect(mockLog.error).toHaveBeenCalledWith(
                "✗ Chalk check failed: chalk binary not found in PATH",
            );
        });
    });

    describe("Configuration Precedence", () => {
        let originalEnv: NodeJS.ProcessEnv;

        beforeEach(() => {
            originalEnv = { ...process.env };
            jest.clearAllMocks();
        });

        afterEach(() => {
            process.env = originalEnv;
        });

        it("should use default values when no config is provided", () => {
            new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        custom: {}, // No crashoverride config
                    },
                } as any,
                {},
                { log: mockLog },
            );

            expect(mockLog.info).toHaveBeenCalledWith(
                "ℹ CrashOverride config initialized:\n\tmemoryCheck=false\n\tchalkCheck=false",
            );
        });

        it("should use environment variables over defaults", () => {
            process.env["CO_MEMORY_CHECK"] = "true";
            process.env["CO_CHALK_CHECK_ENABLED"] = "true";

            new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        custom: {}, // No crashoverride config
                    },
                } as any,
                {},
                { log: mockLog },
            );

            expect(mockLog.info).toHaveBeenCalledWith(
                "ℹ CrashOverride config initialized:\n\tmemoryCheck=true\n\tchalkCheck=true",
            );
        });

        it("should use serverless config over environment variables", () => {
            process.env["CO_MEMORY_CHECK"] = "true";
            process.env["CO_CHALK_CHECK_ENABLED"] = "true";

            new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        custom: {
                            crashoverride: {
                                memoryCheck: false,
                                chalkCheck: false,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            expect(mockLog.info).toHaveBeenCalledWith(
                "ℹ CrashOverride config initialized:\n\tmemoryCheck=false\n\tchalkCheck=false",
            );
        });

        it("should handle partial serverless config with env defaults", () => {
            process.env["CO_MEMORY_CHECK"] = "true";
            process.env["CO_CHALK_CHECK_ENABLED"] = "false";

            new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        custom: {
                            crashoverride: {
                                memoryCheck: false, // Override env
                                chalkCheck: true, // Override env
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            expect(mockLog.info).toHaveBeenCalledWith(
                "ℹ CrashOverride config initialized:\n\tmemoryCheck=false\n\tchalkCheck=true",
            );
        });

        it("should handle 'false' string in environment variables", () => {
            process.env["CO_MEMORY_CHECK"] = "false";
            process.env["CO_CHALK_CHECK_ENABLED"] = "false";

            new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        custom: {},
                    },
                } as any,
                {},
                { log: mockLog },
            );

            expect(mockLog.info).toHaveBeenCalledWith(
                "ℹ CrashOverride config initialized:\n\tmemoryCheck=false\n\tchalkCheck=false",
            );
        });

        it("should ignore invalid environment variable values", () => {
            process.env["CO_MEMORY_CHECK"] = "invalid";
            process.env["CO_CHALK_CHECK_ENABLED"] = "yes";

            new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        custom: {},
                    },
                } as any,
                {},
                { log: mockLog },
            );

            // Should use defaults since env values are not "true"
            expect(mockLog.info).toHaveBeenCalledWith(
                "ℹ CrashOverride config initialized:\n\tmemoryCheck=false\n\tchalkCheck=false",
            );
        });

        it("should create immutable config object", () => {
            const plugin = new CrashOverrideServerlessPlugin(
                {
                    ...mockServerless,
                    service: {
                        ...mockServerless.service,
                        custom: {
                            crashoverride: {
                                memoryCheck: true,
                                chalkCheck: false,
                            },
                        },
                    },
                } as any,
                {},
                { log: mockLog },
            );

            // Try to modify the config (should fail silently in non-strict mode)
            const config = (plugin as any).config;
            expect(() => {
                config.memoryCheck = false;
            }).toThrow(); // Will throw in strict mode or if frozen
        });
    });
});
