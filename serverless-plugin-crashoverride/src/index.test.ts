import { ServerlessError } from "./__mocks__/serverless.mock";
import * as childProcessMock from "./__mocks__/child_process";
import * as fsMock from "./__mocks__/fs";
import * as fetchMock from "./__mocks__/fetch";
import * as path from "path";
import {
  executeProviderConfigHook,
  executeDeploymentHook,
  executeAwsPackageHook,
  executeValidationHook,
  TestSetupBuilder,
  createCloudFormationTemplate,
} from "./__tests__/test-helpers";

jest.mock("child_process", () => require("./__mocks__/child_process"));
jest.mock("fs", () => require("./__mocks__/fs"));

// Mock fetch globally for tests
global.fetch = fetchMock.fetch;
// sidestep ANSI color codes
jest.mock("chalk", () => {
  const mockChalk = {
    red: (str: string) => str,
    yellow: (str: string) => str,
    cyan: (str: string) => str,
    green: (str: string) => str,
    gray: (str: string) => str,
    bold: (str: string) => str,
  };
  return {
    __esModule: true,
    default: mockChalk,
  };
});

describe("CrashOverrideServerlessPlugin", () => {
  let originalEnv: NodeJS.ProcessEnv;
  let originalPlatform: NodeJS.Platform;

  beforeEach(() => {
    jest.clearAllMocks();
    childProcessMock.resetMocks();
    fsMock.resetMocks();
    fetchMock.resetMock();

    originalEnv = { ...process.env };
    originalPlatform = process.platform;
  });

  afterEach(() => {
    process.env = originalEnv;
    Object.defineProperty(process, "platform", {
      value: originalPlatform,
    });
  });

  describe("Platform Support", () => {
    it("should early exit and not register hooks on Windows", () => {
      // Mock process.platform to return 'win32'
      Object.defineProperty(process, "platform", {
        value: "win32",
        configurable: true,
      });

      const { plugin } = new TestSetupBuilder().build();

      // Verify no hooks were registered
      expect(plugin.hooks).toEqual({});

      // Verify config was set to safe defaults
      expect(plugin.config.memoryCheck).toBe(false);
      expect(plugin.config.memoryCheckSize).toBe(256);
      expect(plugin.config.chalkCheck).toBe(false);
      expect(plugin.config.layerCheck).toBe(false);
    });

    it("should initialize normally on non-Windows platforms", () => {
      // Mock process.platform to return 'linux'
      Object.defineProperty(process, "platform", {
        value: "linux",
        configurable: true,
      });

      const { plugin } = new TestSetupBuilder().build();

      // Verify hooks were registered
      expect(Object.keys(plugin.hooks).length).toBeGreaterThan(0);
      expect(plugin.hooks["after:package:setupProviderConfiguration"]).toBeDefined();
      expect(plugin.hooks["after:package:createDeploymentArtifacts"]).toBeDefined();
      expect(plugin.hooks["before:package:compileFunctions"]).toBeDefined();
    });
  });

  describe("Plugin Initialization", () => {
    describe("Successful plugin installation", () => {
      it("should initialize successfully with default configuration values", () => {
        const { plugin } = new TestSetupBuilder().build();

        expect(plugin.config.memoryCheck).toBe(false);
        expect(plugin.config.memoryCheckSize).toBe(256);
        expect(plugin.config.chalkCheck).toBe(false);
        expect(plugin.config.layerCheck).toBe(false);
      });

      it("should register lifecycle hooks correctly", () => {
        const { plugin } = new TestSetupBuilder().build();

        expect(plugin.hooks).toBeDefined();
        expect(plugin.hooks["after:package:setupProviderConfiguration"]).toBeDefined();
        expect(plugin.hooks["after:package:createDeploymentArtifacts"]).toBeDefined();
        expect(plugin.hooks["before:package:compileFunctions"]).toBeDefined();
      });

      it("should detect chalk binary when available", () => {
        const { plugin } = new TestSetupBuilder()
          .withChalkAvailable()
          .withPackageZipExists()
          .build();

        executeDeploymentHook(plugin);

        // Verify chalk availability was detected and stored
        expect((plugin as any).isChalkAvailable).toBe(true);
      });

      it("should read provider configuration correctly", () => {
        const { plugin } = new TestSetupBuilder()
          .withProviderMemory(1234)
          .withProviderRegion("us-west-2")
          .build();

        executeProviderConfigHook(plugin);

        // Verify provider config was stored correctly
        const providerConfig = (plugin as any).providerConfig;
        expect(providerConfig).toBeDefined();
        expect(providerConfig.provider).toBe("aws");
        expect(providerConfig.region).toBe("us-west-2");
        expect(providerConfig.memorySize).toBe(1234);
      });

      it("should prioritize serverless.yml config over environment variables", () => {
        const { plugin } = new TestSetupBuilder()
          .withEnvironmentVar("CO_MEMORY_CHECK", "false")
          .withEnvironmentVar("CO_MEMORY_CHECK_SIZE_MB", "1024")
          .withEnvironmentVar("CO_CHALK_CHECK_ENABLED", "false")
          .withCustomConfig({
            memoryCheck: true,
            memoryCheckSize: 512,
            chalkCheck: true,
          })
          .build();

        // Verify serverless.yml config takes precedence
        expect(plugin.config.memoryCheck).toBe(true);
        expect(plugin.config.memoryCheckSize).toBe(512);
        expect(plugin.config.chalkCheck).toBe(true);
      });

      it("should use environment variables when serverless.yml config is not provided", () => {
        const { plugin } = new TestSetupBuilder()
          .withEnvironmentVar("CO_MEMORY_CHECK", "true")
          .withEnvironmentVar("CO_MEMORY_CHECK_SIZE_MB", "1024")
          .withEnvironmentVar("CO_CHALK_CHECK_ENABLED", "true")
          .build();

        expect(plugin.config.memoryCheck).toBe(true);
        expect(plugin.config.memoryCheckSize).toBe(1024);
        expect(plugin.config.chalkCheck).toBe(true);
      });

      it("should use default values when no configuration is provided", () => {
        const { plugin } = new TestSetupBuilder().build();

        expect(plugin.config.memoryCheck).toBe(false);
        expect(plugin.config.memoryCheckSize).toBe(256);
        expect(plugin.config.chalkCheck).toBe(false);
      });

      it("should handle invalid memoryCheckSize in environment variable", () => {
        expect(() => {
          new TestSetupBuilder().withEnvironmentVar("CO_MEMORY_CHECK_SIZE_MB", "invalid").build();
        }).toThrow(ServerlessError);
      });

      it("should merge configurations with correct precedence", () => {
        const { plugin } = new TestSetupBuilder()
          .withEnvironmentVar("CO_MEMORY_CHECK", "true")
          .withEnvironmentVar("CO_MEMORY_CHECK_SIZE_MB", "1024")
          .withCustomConfig({
            memoryCheckSize: 512,
            chalkCheck: true,
          })
          .build();

        expect(plugin.config.memoryCheck).toBe(true); // from env
        expect(plugin.config.memoryCheckSize).toBe(512); // from serverless.yml
        expect(plugin.config.chalkCheck).toBe(true); // from serverless.yml
      });

      it("should handle boolean string values in environment variables correctly", () => {
        const { plugin } = new TestSetupBuilder()
          .withEnvironmentVar("CO_MEMORY_CHECK", "TRUE")
          .withEnvironmentVar("CO_CHALK_CHECK_ENABLED", "FALSE")
          .build();

        expect(plugin.config.memoryCheck).toBe(true);
        expect(plugin.config.memoryCheckSize).toBe(256); // default
        expect(plugin.config.chalkCheck).toBe(false);
      });

      it("should handle ARN version configuration from environment variable", () => {
        const { plugin } = new TestSetupBuilder().withEnvironmentVar("CO_ARN_VERSION", "7").build();

        expect(plugin.config.arnVersion).toBe(7);
      });

      it("should handle ARN version configuration from serverless.yml", () => {
        const { plugin } = new TestSetupBuilder()
          .withCustomConfig({
            arnVersion: 22,
          })
          .build();

        expect(plugin.config.arnVersion).toBe(22);
      });

      it("should prioritize serverless.yml ARN version over environment variable", () => {
        const { plugin } = new TestSetupBuilder()
          .withEnvironmentVar("CO_ARN_VERSION", "7")
          .withCustomConfig({
            arnVersion: 22,
          })
          .build();

        expect(plugin.config.arnVersion).toBe(22); // serverless.yml takes precedence
      });

      it("should throw error for invalid ARN version in environment variable", () => {
        expect(() => {
          new TestSetupBuilder().withEnvironmentVar("CO_ARN_VERSION", "invalid").build();
        }).toThrow("Received invalid arnVersion value: invalid");

        expect(() => {
          new TestSetupBuilder().withEnvironmentVar("CO_ARN_VERSION", "-1").build();
        }).toThrow("Received invalid arnVersion value: -1");

        expect(() => {
          new TestSetupBuilder().withEnvironmentVar("CO_ARN_VERSION", "0").build();
        }).toThrow("Received invalid arnVersion value: 0");
      });

      it("should use undefined ARN version by default", () => {
        const { plugin } = new TestSetupBuilder().build();

        expect(plugin.config.arnVersion).toBeUndefined();
      });
    });
  });

  describe("Memory Check Validation", () => {
    describe.each([
      {
        memoryCheck: true,
        providerMemory: 1024,
        requiredMemory: 512,
        shouldThrow: false,
        description: "passes when memory is sufficient",
      },
      {
        memoryCheck: true,
        providerMemory: 512,
        requiredMemory: 512,
        shouldThrow: false,
        description: "passes when memory equals requirement",
      },
      {
        memoryCheck: true,
        providerMemory: 256,
        requiredMemory: 512,
        shouldThrow: true,
        description: "throws when memory is insufficient",
      },
      {
        memoryCheck: false,
        providerMemory: 256,
        requiredMemory: 512,
        shouldThrow: false,
        description: "warns but doesn't throw when check is disabled",
      },
    ])("$description", ({ memoryCheck, providerMemory, requiredMemory, shouldThrow }) => {
      it(`memoryCheck=${memoryCheck}, provider=${providerMemory}MB, required=${requiredMemory}MB`, () => {
        const { plugin } = new TestSetupBuilder()
          .withMemoryCheck(memoryCheck, requiredMemory)
          .withProviderMemory(providerMemory)
          .build();

        executeProviderConfigHook(plugin);

        if (shouldThrow) {
          expect(() => executeDeploymentHook(plugin)).toThrow(ServerlessError);
          expect(() => executeDeploymentHook(plugin)).toThrow(
            `Memory check failed: memorySize (${providerMemory}MB) is less than minimum required (${requiredMemory}MB)`
          );
        } else {
          expect(() => executeDeploymentHook(plugin)).not.toThrow();
        }
      });
    });

    it("should return correct boolean from checkMemoryConfiguration", () => {
      const { plugin } = new TestSetupBuilder()
        .withMemoryCheck(true, 512)
        .withProviderMemory(1024)
        .build();

      executeProviderConfigHook(plugin);

      // Access private method for unit testing
      const result = (plugin as any).checkMemoryConfiguration();
      expect(result).toBe(true);
    });

    it("should throw if provider config not initialized", () => {
      const { plugin } = new TestSetupBuilder().withMemoryCheck(true, 512).build();

      // Don't execute provider config hook
      // Access private method for unit testing
      expect(() => (plugin as any).checkMemoryConfiguration()).toThrow(
        "Provider configuration not initialized"
      );
    });
  });

  describe("Chalk Binary Validation", () => {
    describe.each([
      {
        chalkCheck: true,
        chalkAvailable: true,
        shouldThrow: false,
        description: "passes when chalk available and required",
      },
      {
        chalkCheck: true,
        chalkAvailable: false,
        shouldThrow: true,
        description: "throws when chalk required but not available",
      },
      {
        chalkCheck: false,
        chalkAvailable: true,
        shouldThrow: false,
        description: "passes when chalk available but not required",
      },
      {
        chalkCheck: false,
        chalkAvailable: false,
        shouldThrow: false,
        description: "passes when chalk not available and not required",
      },
    ])("$description", ({ chalkCheck, chalkAvailable, shouldThrow }) => {
      it(`chalkCheck=${chalkCheck}, available=${chalkAvailable}`, () => {
        const builder = new TestSetupBuilder().withCustomConfig({
          memoryCheck: false,
          memoryCheckSize: 256,
          chalkCheck: chalkCheck,
        });

        if (chalkAvailable) {
          builder.withChalkAvailable();
        } else {
          builder.withChalkNotAvailable();
        }

        const { plugin } = builder.build();

        if (shouldThrow) {
          expect(() => executeDeploymentHook(plugin)).toThrow(ServerlessError);
          expect(() => executeDeploymentHook(plugin)).toThrow(
            "Chalk check failed: chalk binary not found in PATH"
          );
        } else {
          expect(() => executeDeploymentHook(plugin)).not.toThrow();
        }

        // After deployment hook, verify isChalkAvailable state
        if (!shouldThrow) {
          executeDeploymentHook(plugin);
          expect((plugin as any).isChalkAvailable).toBe(chalkAvailable);
        }
      });
    });

    it("should correctly detect chalk availability", () => {
      const { plugin } = new TestSetupBuilder().withChalkAvailable().build();

      // Access private method for unit testing
      const result = (plugin as any).chalkBinaryAvailable();
      expect(result).toBe(true);
    });

    it("should correctly detect chalk unavailability", () => {
      const { plugin } = new TestSetupBuilder().withChalkNotAvailable().build();

      // Access private method for unit testing
      const result = (plugin as any).chalkBinaryAvailable();
      expect(result).toBe(false);
    });
  });

  describe("Chalk Binary Injection", () => {
    describe.each([
      {
        description: "chalk available and package exists",
        chalkAvailable: true,
        packageExists: true,
        shouldInject: true,
      },
      {
        description: "chalk not available",
        chalkAvailable: false,
        packageExists: true,
        shouldInject: false,
      },
      {
        description: "package does not exist",
        chalkAvailable: true,
        packageExists: false,
        shouldInject: false,
      },
    ])("injection behavior - $description", ({ chalkAvailable, packageExists, shouldInject }) => {
      it("should handle injection correctly", async () => {
        const builder = new TestSetupBuilder().withServiceName("test-service");

        if (chalkAvailable) {
          builder.withChalkAvailable();
        } else {
          builder.withChalkNotAvailable();
        }

        if (packageExists) {
          builder.withPackageZipExists();
        } else {
          fsMock.existsSync.mockReturnValue(false);
        }

        const { plugin } = builder.build();

        executeProviderConfigHook(plugin);
        executeDeploymentHook(plugin);
        await executeAwsPackageHook(plugin);

        if (shouldInject) {
          // Verify chalk injection was attempted with the correct path
          expect(childProcessMock.execSync).toHaveBeenCalledWith(
            expect.stringContaining("chalk insert --inject-binary-into-zip"),
            expect.any(Object)
          );
        } else {
          // Verify chalk injection was not attempted
          expect(childProcessMock.execSync).not.toHaveBeenCalledWith(
            expect.stringContaining("chalk insert"),
            expect.any(Object)
          );
        }
      });
    });
  });

  describe("Lambda Extension Management", () => {
    describe.each([
      {
        description: "single function with no layers",
        functions: {
          function1: {
            handler: "handler.function1",
            runtime: "nodejs18.x",
            layers: [],
          },
        },
        expectedLayerCounts: { function1: 1 },
        shouldAddExtension: true,
      },
      {
        description: "multiple functions with existing layers",
        functions: {
          function1: {
            handler: "handler.function1",
            runtime: "nodejs18.x",
            layers: ["arn:aws:lambda:us-east-1:123:layer:existing"],
          },
          function2: {
            handler: "handler.function2",
            runtime: "nodejs18.x",
            layers: [],
          },
        },
        expectedLayerCounts: { function1: 2, function2: 1 },
        shouldAddExtension: true,
      },
      {
        description: "function with no layers property",
        functions: {
          function1: {
            handler: "handler.function1",
            runtime: "nodejs18.x",
          },
        },
        expectedLayerCounts: { function1: 1 },
        shouldAddExtension: true,
      },
    ])(
      "adding extension - $description",
      ({ functions, expectedLayerCounts, shouldAddExtension }) => {
        it("should add Dust Lambda Extension correctly", async () => {
          const { plugin, mockServerless } = new TestSetupBuilder()
            .withFunctions(functions)
            .build();

          executeProviderConfigHook(plugin);
          await executeAwsPackageHook(plugin);

          const extensionArn =
            "arn:aws:lambda:us-east-1:123456789012:layer:test-crashoverride-dust-extension:8";

          if (shouldAddExtension) {
            // Verify all functions have the correct number of layers
            for (const [funcName, expectedCount] of Object.entries(expectedLayerCounts)) {
              const func = mockServerless.service.functions[funcName] as any;
              expect(func.layers).toHaveLength(expectedCount);
              expect(func.layers).toContain(extensionArn);
            }

            // Verify the extension ARN was stored
            expect((plugin as any).dustExtensionArn).toBe(extensionArn);
          }
        });
      }
    );

    describe.each([
      {
        description: "function at 15 layer limit",
        functions: {
          maxedFunction: {
            handler: "handler.maxed",
            runtime: "nodejs18.x",
            layers: Array(15)
              .fill(0)
              .map((_, i) => `arn:aws:lambda:us-east-1:123456789012:layer:layer${i + 1}`),
          },
        },
        shouldThrow: true,
        errorMatch: "Cannot add Dust Lambda Extension",
      },
      {
        description: "function with 14 layers (just under limit)",
        functions: {
          almostMaxed: {
            handler: "handler.almost",
            runtime: "nodejs18.x",
            layers: Array(14)
              .fill(0)
              .map((_, i) => `arn:aws:lambda:us-east-1:123456789012:layer:layer${i + 1}`),
          },
        },
        shouldThrow: false,
        expectedLayerCount: 15,
      },
    ])(
      "layer limit validation - $description",
      ({ functions, shouldThrow, errorMatch, expectedLayerCount }) => {
        it("should validate layer limits correctly", async () => {
          const { plugin, mockServerless } = new TestSetupBuilder()
            .withFunctions(functions)
            .build();

          executeProviderConfigHook(plugin);

          if (shouldThrow) {
            await expect(executeAwsPackageHook(plugin)).rejects.toThrow(errorMatch);
            // Verify no functions were modified when validation fails
            for (const func of Object.values(mockServerless.service.functions || {})) {
              const awsFunc = func as any;
              expect(awsFunc.layers).not.toContain(
                "arn:aws:lambda:us-east-1:123456789012:layer:test-crashoverride-dust-extension:8"
              );
            }
          } else {
            await expect(executeAwsPackageHook(plugin)).resolves.not.toThrow();
            // Verify function has expected layer count
            const funcName = Object.keys(functions)[0];
            const func = mockServerless.service.functions[funcName] as any;
            expect(func.layers).toHaveLength(expectedLayerCount);
          }
        });
      }
    );

    it("should handle service with no functions", async () => {
      const { plugin, mockServerless } = new TestSetupBuilder().withFunctions({}).build();

      executeProviderConfigHook(plugin);
      await expect(executeAwsPackageHook(plugin)).resolves.not.toThrow();

      // Verify no functions were modified
      expect(Object.keys(mockServerless.service.functions || {}).length).toBe(0);
      // Verify no extension ARN was set when there are no functions
      expect((plugin as any).dustExtensionArn).toBeNull();
    });
  });

  describe("getServerlessPackagingLocation", () => {
    let originalCwd: () => string;

    beforeEach(() => {
      originalCwd = process.cwd;
      jest.spyOn(process, "cwd").mockReturnValue("/mock/cwd");
    });

    afterEach(() => {
      process.cwd = originalCwd;
    });

    describe("path resolution with various servicePath and packagePath combinations", () => {
      interface TestCase {
        servicePath: string | undefined;
        packagePath: string | undefined;
        expected: string;
        description: string;
        shouldCallCwd?: boolean;
      }

      const testCases: TestCase[] = [
        // Basic servicePath tests
        {
          servicePath: "/absolute/service/path",
          packagePath: undefined,
          expected: "/absolute/service/path/.serverless",
          description: "absolute servicePath with default package path",
        },
        {
          servicePath: "./relative/path",
          packagePath: undefined,
          expected: "relative/path/.serverless", // Will be checked with toContain
          description: "relative servicePath with default package path",
        },
        {
          servicePath: undefined,
          packagePath: undefined,
          expected: "/mock/cwd/.serverless",
          description: "undefined servicePath with default package path",
          shouldCallCwd: true,
        },
        {
          servicePath: "",
          packagePath: undefined,
          expected: "/mock/cwd/.serverless",
          description: "empty servicePath with default package path",
          shouldCallCwd: true,
        },
        // Custom package paths
        {
          servicePath: "/service/path",
          packagePath: "/absolute/package/path",
          expected: "/absolute/package/path",
          description: "absolute package path",
        },
        {
          servicePath: "/service/path",
          packagePath: "custom/package/dir",
          expected: "/service/path/custom/package/dir",
          description: "relative package path",
        },
        {
          servicePath: undefined,
          packagePath: "dist/serverless",
          expected: "/mock/cwd/dist/serverless",
          description: "undefined servicePath with custom package path",
          shouldCallCwd: true,
        },
        // Edge cases
        {
          servicePath: "/path/with/trailing/slash/",
          packagePath: undefined,
          expected: "/path/with/trailing/slash/.serverless",
          description: "servicePath with trailing slash",
        },
        {
          servicePath: "/service/path",
          packagePath: "",
          expected: "/service/path/.serverless",
          description: "empty package path falls back to default",
        },
      ];

      test.each(testCases)(
        "$description",
        ({ servicePath, packagePath, expected, shouldCallCwd }) => {
          const builder = new TestSetupBuilder();

          if (servicePath !== undefined) {
            builder.withServicePath(servicePath);
          }

          if (packagePath !== undefined) {
            builder.withPackagePath(packagePath);
          }

          const { plugin, mockServerless } = builder.build();

          // Handle undefined servicePath case
          if (servicePath === undefined) {
            mockServerless.config.servicePath = undefined;
          }

          // Handle undefined packagePath case
          if (packagePath === undefined && servicePath !== undefined) {
            mockServerless.service.package = undefined;
          }

          const location = (plugin as any).getServerlessPackagingLocation();

          // Check the result
          if (servicePath?.startsWith("./")) {
            // For relative paths, just check it contains the expected part
            expect(location).toContain(expected);
          } else {
            expect(location).toBe(expected);
          }

          // All results should be absolute paths
          expect(path.isAbsolute(location)).toBe(true);

          // Check if process.cwd was called when expected
          if (shouldCallCwd) {
            expect(process.cwd).toHaveBeenCalled();
          }
        }
      );
    });

    describe("complex relative path handling", () => {
      test.each([
        [
          "/service/sub/path",
          "../parent/package",
          "/service/sub/parent/package",
          "parent directory references",
        ],
        [
          "/service/path",
          "./nested/./package",
          "/service/path/nested/package",
          "current directory references",
        ],
        [
          "/service/sub/deep",
          "../../up/two",
          "/service/up/two",
          "multiple parent directory references",
        ],
        ["/service", "./././nested", "/service/nested", "multiple current directory references"],
      ])(
        "should handle %s with packagePath=%s correctly",
        (servicePath: string, packagePath: string, expected: string, description: string) => {
          const { plugin } = new TestSetupBuilder()
            .withServicePath(servicePath)
            .withPackagePath(packagePath)
            .build();

          const location = (plugin as any).getServerlessPackagingLocation();

          expect(location).toBe(expected);
          expect(path.isAbsolute(location)).toBe(true);
        }
      );
    });
  });

  describe("CloudFormation Template Parsing", () => {
    it("should parse valid CloudFormation template", () => {
      const template = { Resources: {} };
      fsMock.readFileSync.mockReturnValue(JSON.stringify(template));

      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).parseCloudFormationTemplate("/path/to/template.json");

      expect(result).toEqual(template);
    });

    it("should throw meaningful error for missing file", () => {
      fsMock.readFileSync.mockImplementation(() => {
        const error: any = new Error("ENOENT");
        error.code = "ENOENT";
        throw error;
      });

      const { plugin } = new TestSetupBuilder().build();

      expect(() => (plugin as any).parseCloudFormationTemplate("/path/to/template.json")).toThrow(
        "CloudFormation template not found at /path/to/template.json"
      );
    });

    it("should throw meaningful error for invalid JSON", () => {
      fsMock.readFileSync.mockReturnValue("{ invalid json }");

      const { plugin } = new TestSetupBuilder().build();

      expect(() => (plugin as any).parseCloudFormationTemplate("/path/to/template.json")).toThrow(
        "Invalid JSON in CloudFormation template"
      );
    });

    it("should wrap unexpected errors", () => {
      fsMock.readFileSync.mockImplementation(() => {
        throw new Error("Unexpected error");
      });

      const { plugin } = new TestSetupBuilder().build();

      expect(() => (plugin as any).parseCloudFormationTemplate("/path/to/template.json")).toThrow(
        "Failed to parse CloudFormation template: Unexpected error"
      );
    });
  });

  describe("Function Validation Logic", () => {
    it("should correctly identify functions with and without extension", () => {
      const template = createCloudFormationTemplate([
        { name: "Function1", hasLayers: true, layers: ["arn:test"] },
        { name: "Function2", hasLayers: false },
      ]);

      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).validateFunctionsInTemplate(template, "arn:test");

      expect(result).toEqual({
        totalFunctions: 2,
        functionsWithExtension: ["Function1LambdaFunction"],
        functionsMissingExtension: ["Function2LambdaFunction"],
      });
    });

    it("should handle template with no Lambda functions", () => {
      const template = {
        Resources: {
          SomeOtherResource: {
            Type: "AWS::S3::Bucket",
          },
        },
      };

      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).validateFunctionsInTemplate(template, "arn:test");

      expect(result).toEqual({
        totalFunctions: 0,
        functionsWithExtension: [],
        functionsMissingExtension: [],
      });
    });

    it("should handle functions with no Layers property", () => {
      const template = {
        Resources: {
          MyFunction: {
            Type: "AWS::Lambda::Function",
            Properties: {
              Handler: "index.handler",
              // No Layers property
            },
          },
        },
      };

      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).validateFunctionsInTemplate(template, "arn:test");

      expect(result).toEqual({
        totalFunctions: 1,
        functionsWithExtension: [],
        functionsMissingExtension: ["MyFunction"],
      });
    });

    it("should handle template with no Resources section", () => {
      const template = {};

      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).validateFunctionsInTemplate(template, "arn:test");

      expect(result).toEqual({
        totalFunctions: 0,
        functionsWithExtension: [],
        functionsMissingExtension: [],
      });
    });

    it("should check multiple functions correctly", () => {
      const arn = "arn:aws:lambda:us-east-1:123:layer:dust:1";
      const template = {
        Resources: {
          Func1: {
            Type: "AWS::Lambda::Function",
            Properties: { Layers: [arn] },
          },
          Func2: {
            Type: "AWS::Lambda::Function",
            Properties: { Layers: ["other-arn"] },
          },
          Func3: {
            Type: "AWS::Lambda::Function",
            Properties: { Layers: [arn, "other-arn"] },
          },
          NotAFunction: {
            Type: "AWS::S3::Bucket",
          },
        },
      };

      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).validateFunctionsInTemplate(template, arn);

      expect(result).toEqual({
        totalFunctions: 3,
        functionsWithExtension: ["Func1", "Func3"],
        functionsMissingExtension: ["Func2"],
      });
    });
  });

  describe("Status Message Building", () => {
    it("should build comprehensive status message", () => {
      const result = {
        totalFunctions: 3,
        functionsWithExtension: ["Function1", "Function2"],
        functionsMissingExtension: ["Function3"],
      };

      const { plugin } = new TestSetupBuilder().build();
      const message = (plugin as any).buildStatusMessage(result);

      expect(message).toContain("Layer check status:");
      expect(message).toContain(" Functions with Dust Extension (2/3):");
      expect(message).toContain("- Function1");
      expect(message).toContain("- Function2");
      expect(message).toContain(" Functions MISSING Dust Extension (1/3):");
      expect(message).toContain("- Function3");
    });
  });

  describe("Layer Check Validation", () => {
    const dustExtensionArn =
      "arn:aws:lambda:us-east-1:224111541501:layer:test-crashoverride-dust-extension:8";

    beforeEach(() => {
      fetchMock.mockDustExtensionArn(dustExtensionArn);
    });

    it("should pass validation when all functions have Dust extension", async () => {
      const template = createCloudFormationTemplate([
        { name: "Handler", hasLayers: true, layers: [dustExtensionArn] },
        { name: "Worker", hasLayers: true, layers: [dustExtensionArn] },
      ]);

      const { plugin } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({
          handler: { handler: "handler.handler" },
          worker: { handler: "worker.handler" },
        })
        .build();

      fsMock.mockCloudFormationTemplate(template);

      // Execute hooks to set up extension ARN
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      // Should not throw when all functions have the extension
      expect(() => executeValidationHook(plugin)).not.toThrow();
    });

    it("should throw an error when layerCheck=true and functions missing extension", async () => {
      const template = createCloudFormationTemplate([
        { name: "Handler", hasLayers: true, layers: [dustExtensionArn] },
        { name: "Worker", hasLayers: false },
        { name: "Processor", hasLayers: false },
      ]);

      const { plugin } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({
          handler: { handler: "handler.handler" },
          worker: { handler: "worker.handler" },
          processor: { handler: "processor.handler" },
        })
        .build();

      fsMock.mockCloudFormationTemplate(template);

      // Execute hooks to set up extension ARN
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      // Should throw with specific error about missing extensions
      expect(() => executeValidationHook(plugin)).toThrow(ServerlessError);
      expect(() => executeValidationHook(plugin)).toThrow(
        "Layer check failed: 2 function(s) missing Dust Lambda Extension: WorkerLambdaFunction, ProcessorLambdaFunction"
      );
    });

    it("should warn but not throw when layerCheck=false and functions missing extension", async () => {
      const template = createCloudFormationTemplate([
        { name: "Handler", hasLayers: true, layers: [dustExtensionArn] },
        { name: "Worker", hasLayers: false },
      ]);

      const { plugin } = new TestSetupBuilder()
        .withLayerCheck(false) // layerCheck disabled
        .withFunctions({
          handler: { handler: "handler.handler" },
          worker: { handler: "worker.handler" },
        })
        .build();

      fsMock.mockCloudFormationTemplate(template);

      // Execute hooks to set up extension ARN
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      // Should not throw when layerCheck is disabled
      expect(() => executeValidationHook(plugin)).not.toThrow();
    });

    it("should handle functions with no Layers property", async () => {
      const template = {
        AWSTemplateFormatVersion: "2010-09-09",
        Resources: {
          HandlerLambdaFunction: {
            Type: "AWS::Lambda::Function",
            Properties: {
              Handler: "handler.handler",
              Runtime: "nodejs18.x",
              // No Layers property at all
            },
          },
        },
      };

      const { plugin, mockLog } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({
          handler: { handler: "handler.handler" },
        })
        .build();

      fsMock.mockCloudFormationTemplate(template);

      // Execute hooks to set up extension ARN
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      // Should throw
      expect(() => executeValidationHook(plugin)).toThrow(
        "Layer check failed: 1 function(s) missing Dust Lambda Extension: HandlerLambdaFunction"
      );
    });

    it("should handle CloudFormation template with no Lambda functions", async () => {
      const template = {
        AWSTemplateFormatVersion: "2010-09-09",
        Resources: {
          // Only non-Lambda resources
          IamRole: {
            Type: "AWS::IAM::Role",
            Properties: {},
          },
        },
      };

      const { plugin } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({
          handler: { handler: "handler.handler" }, // Function in service config
        })
        .build();

      fsMock.mockCloudFormationTemplate(template); // But no functions in CloudFormation

      // Execute hooks
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin); // Will set dustExtensionArn

      // Should not throw when no Lambda functions found in template
      expect(() => executeValidationHook(plugin)).not.toThrow();
    });

    it("should handle missing CloudFormation template file", async () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({
          handler: { handler: "handler.handler" },
        })
        .build();

      fsMock.mockCloudFormationTemplateNotFound();

      // Execute hooks to set up extension ARN
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      // Should throw with specific error
      expect(() => executeValidationHook(plugin)).toThrow(
        "Layer check failed: CloudFormation template not found at"
      );
    });

    it("should handle malformed JSON in CloudFormation template", async () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({
          handler: { handler: "handler.handler" },
        })
        .build();

      // Mock readFileSync to return invalid JSON
      fsMock.readFileSync.mockReturnValue("{ invalid json }");

      // Execute hooks to set up extension ARN
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      // Should throw with JSON error
      expect(() => executeValidationHook(plugin)).toThrow(
        "Layer check failed: Invalid JSON in CloudFormation template"
      );
    });

    it("should throw error when layerCheck=true and no Dust extension ARN available", async () => {
      const { plugin } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({}) // No functions, so no ARN will be fetched
        .build();

      // Execute hooks - no functions means no ARN is fetched
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);

      // Verify ARN was not set
      expect((plugin as any).dustExtensionArn).toBeNull();

      // Should throw error when layerCheck is enforced but no ARN available
      expect(() => executeValidationHook(plugin)).toThrow(
        "Cannot perform layer check: No Dust extension ARN available"
      );
    });

    it("should skip validation when layerCheck=false and no Dust extension ARN available", async () => {
      const { plugin } = new TestSetupBuilder()
        .withLayerCheck(false) // layerCheck disabled
        .withFunctions({}) // No functions, so no ARN will be fetched
        .build();

      // Execute hooks - no functions means no ARN is fetched
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);

      // Should not throw when layerCheck is disabled
      expect(() => executeValidationHook(plugin)).not.toThrow();

      // Verify ARN was not set
      expect((plugin as any).dustExtensionArn).toBeNull();
    });
  });

  describe("Package Processing", () => {
    it("should handle missing package zip file gracefully", async () => {
      const { plugin } = new TestSetupBuilder().withChalkAvailable().build();

      fsMock.existsSync.mockReturnValue(false);

      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);

      // Should not throw, but should not attempt injection
      await expect(executeAwsPackageHook(plugin)).resolves.not.toThrow();

      // Verify injection was not attempted when zip doesn't exist
      expect(childProcessMock.execSync).not.toHaveBeenCalledWith(
        expect.stringContaining("chalk insert"),
        expect.any(Object)
      );
    });

    it("should handle chalk injection errors gracefully", async () => {
      const { plugin } = new TestSetupBuilder().withChalkAvailable().withPackageZipExists().build();

      // Override the mock after builder sets it up to simulate injection failure
      childProcessMock.execSync.mockImplementation((command: string) => {
        if (command === "which chalk") {
          return Buffer.from("/usr/local/bin/chalk");
        }
        if (command.includes("chalk insert")) {
          throw new Error("Injection failed");
        }
        return Buffer.from("");
      });

      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);

      // Should not throw even when injection fails
      await expect(executeAwsPackageHook(plugin)).resolves.not.toThrow();
    });

    it("should handle provider config not being available", () => {
      const { plugin } = new TestSetupBuilder().withNoProvider().build();

      executeProviderConfigHook(plugin);

      // Verify provider config was not set
      expect((plugin as any).providerConfig).toBeNull();
    });

    it("should use correct service path for package location", async () => {
      const customServicePath = "/custom/service/path";

      fsMock.existsSync.mockImplementation((path: string) => {
        return path === `${customServicePath}/.serverless/test-service.zip`;
      });

      const { plugin } = new TestSetupBuilder()
        .withChalkAvailable()
        .withServicePath(customServicePath)
        .build();

      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      expect(fsMock.existsSync).toHaveBeenCalledWith(
        `${customServicePath}/.serverless/test-service.zip`
      );
    });
  });

  describe("validateLayerCount", () => {
    describe.each([
      {
        description: "all functions under limit",
        functions: {
          func1: { layers: ["layer1", "layer2"] },
          func2: { layers: [] },
        },
        maxLayers: 15,
        expectedValid: true,
        expectedErrors: [],
      },
      {
        description: "one function at limit",
        functions: {
          func1: { layers: Array(15).fill("layer") },
        },
        maxLayers: 15,
        expectedValid: false,
        expectedErrors: ["Function func1 has 15 layers/extensions (max: 15)"],
      },
      {
        description: "multiple functions over limit",
        functions: {
          func1: { layers: Array(16).fill("layer") },
          func2: { layers: Array(20).fill("layer") },
        },
        maxLayers: 15,
        expectedValid: false,
        expectedErrors: [
          "Function func1 has 16 layers/extensions (max: 15)",
          "Function func2 has 20 layers/extensions (max: 15)",
        ],
      },
      {
        description: "function with no layers property",
        functions: {
          func1: { handler: "handler.main" },
        },
        maxLayers: 15,
        expectedValid: true,
        expectedErrors: [],
      },
    ])("$description", ({ functions, maxLayers, expectedValid, expectedErrors }) => {
      const { plugin } = new TestSetupBuilder().build();

      // Access private method for unit testing
      const result = (plugin as any).validateLayerCount(functions, maxLayers);

      expect(result.valid).toBe(expectedValid);
      expect(result.errors).toEqual(expectedErrors);
    });
  });

  describe("addDustLambdaExtension", () => {
    it("should add extension ARN to all functions and return success with details", () => {
      const functions = {
        func1: { layers: ["existing-layer"] },
        func2: { layers: [] },
        func3: {},
      };

      const extensionArn = "arn:aws:lambda:us-east-1:123:layer:dust:1";
      const { plugin } = new TestSetupBuilder().build();

      // Access private method for unit testing
      const result = (plugin as any).addDustLambdaExtension(functions, extensionArn);

      expect(result.success).toBe(true);
      expect(result.added).toEqual(["func1", "func2", "func3"]);
      expect(result.skipped).toEqual([]);
      expect(functions.func1.layers).toContain(extensionArn);
      expect(functions.func1.layers).toContain("existing-layer"); // does not squash
      expect(functions.func2.layers).toContain(extensionArn);
      expect(functions.func3.layers).toContain(extensionArn); // handles missing key
    });

    it("should handle empty functions object", () => {
      const functions = {};
      const extensionArn = "arn:aws:lambda:us-east-1:123:layer:dust:1";
      const { plugin } = new TestSetupBuilder().build();

      const result = (plugin as any).addDustLambdaExtension(functions, extensionArn);

      expect(result.success).toBe(true); // no-ops are a successful result
      expect(result.added).toEqual([]);
      expect(result.skipped).toEqual([]);
      expect(Object.keys(functions)).toHaveLength(0);
    });

    it("should not duplicate Dust extension if already present with same base ARN", () => {
      const existingArn = "arn:aws:lambda:us-east-1:123:layer:dust:1";
      const newArn = "arn:aws:lambda:us-east-1:123:layer:dust:2";
      const functions = {
        func1: { layers: [existingArn] },
        func2: { layers: ["other-layer"] },
        func3: {},
      };
      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).addDustLambdaExtension(functions, newArn);

      expect(result.success).toBe(true);
      expect(result.added).toEqual(["func2", "func3"]);
      expect(result.skipped).toEqual(["func1"]);
      // func1 should still have only the original version
      expect(functions.func1.layers).toEqual([existingArn]);
      expect(functions.func1.layers).toHaveLength(1);
      // func2 and func3 should have the new version added
      expect(functions.func2.layers).toContain(newArn);
      expect(functions.func3.layers).toContain(newArn);
    });

    it("should skip all functions if they already have the Dust extension", () => {
      const existingArn = "arn:aws:lambda:us-east-1:123:layer:dust:1";
      const functions = {
        func1: { layers: [existingArn] },
        func2: { layers: [existingArn, "other-layer"] },
      };
      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).addDustLambdaExtension(functions, existingArn);

      expect(result.success).toBe(true);
      expect(result.added).toEqual([]);
      expect(result.skipped).toEqual(["func1", "func2"]);
      // Layers should remain unchanged
      expect(functions.func1.layers).toEqual([existingArn]);
      expect(functions.func2.layers).toEqual([existingArn, "other-layer"]);
    });

    it("should add extension even if a different ARN is present", () => {
      const otherExtension = "arn:aws:lambda:us-east-1:999:layer:other-extension:1";
      const dustExtension = "arn:aws:lambda:us-east-1:123:layer:dust:1";
      const functions = {
        func1: { layers: [otherExtension] },
      };
      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).addDustLambdaExtension(functions, dustExtension);

      expect(result.success).toBe(true);
      expect(result.added).toEqual(["func1"]);
      expect(result.skipped).toEqual([]);
      expect(functions.func1.layers).toContain(otherExtension);
      expect(functions.func1.layers).toContain(dustExtension);
      expect(functions.func1.layers).toHaveLength(2);
    });
  });

  describe("getArnWithoutVersion", () => {
    it("should remove version from a complete ARN", () => {
      const { plugin } = new TestSetupBuilder().build();
      const arn = "arn:aws:lambda:us-east-1:123456789012:layer:dust-extension:8";
      const result = (plugin as any).getArnWithoutVersion(arn);
      expect(result).toBe("arn:aws:lambda:us-east-1:123456789012:layer:dust-extension");
    });

    it("should handle ARN without version", () => {
      const { plugin } = new TestSetupBuilder().build();
      const arn = "arn:aws:lambda:us-east-1:123456789012:layer:dust-extension";
      const result = (plugin as any).getArnWithoutVersion(arn);
      expect(result).toBe("arn:aws:lambda:us-east-1:123456789012:layer:dust-extension");
    });

    it("should handle short ARN", () => {
      const { plugin } = new TestSetupBuilder().build();
      const arn = "arn:aws:lambda:region";
      const result = (plugin as any).getArnWithoutVersion(arn);
      expect(result).toBe("arn:aws:lambda:region");
    });
  });

  describe("injectChalkBinary", () => {
    beforeEach(() => {
      // Reset mocks to avoid interference from TestSetupBuilder
      childProcessMock.execSync.mockReset();
    });

    it("should return true when injection succeeds", () => {
      // Build the plugin first
      const { plugin } = new TestSetupBuilder().build();

      // Then set up the mock for our specific test
      childProcessMock.execSync.mockReturnValue(Buffer.from("Success"));

      // Access private method for unit testing
      const result = (plugin as any).injectChalkBinary("/path/to/package.zip");

      expect(result).toBe(true);
      expect(childProcessMock.execSync).toHaveBeenCalledWith(
        'chalk insert --inject-binary-into-zip "/path/to/package.zip"',
        expect.any(Object)
      );
    });

    it("should return false when injection fails", () => {
      childProcessMock.execSync.mockImplementation(() => {
        throw new Error("Injection failed");
      });
      const { plugin } = new TestSetupBuilder().build();

      const result = (plugin as any).injectChalkBinary("/path/to/package.zip");

      expect(result).toBe(false);
    });
  });

  describe("getCloudFormationTemplatePath", () => {
    it("should return correct CloudFormation template path", () => {
      const { plugin } = new TestSetupBuilder().withServicePath("/test/service/path").build();

      const result = (plugin as any).getCloudFormationTemplatePath();

      expect(result).toBe(
        "/test/service/path/.serverless/cloudformation-template-update-stack.json"
      );
    });

    it("should handle custom package path", () => {
      const { plugin } = new TestSetupBuilder()
        .withServicePath("/test/service")
        .withPackagePath("/custom/package")
        .build();

      const result = (plugin as any).getCloudFormationTemplatePath();

      expect(result).toBe("/custom/package/cloudformation-template-update-stack.json");
    });
  });

  describe("performLayerValidation", () => {
    describe.each([
      {
        description: "no extension ARN and layerCheck disabled",
        extensionArn: null,
        layerCheckEnabled: false,
        expectedValid: true,
        expectedError: undefined,
      },
      {
        description: "no extension ARN and layerCheck enabled",
        extensionArn: null,
        layerCheckEnabled: true,
        expectedValid: false,
        expectedError: "Cannot perform layer check: No Dust extension ARN available",
      },
      {
        description: "all functions have extension",
        extensionArn: "arn:test:extension",
        layerCheckEnabled: true,
        setupMocks: () => {
          const template = createCloudFormationTemplate([
            { name: "Func1", hasLayers: true, layers: ["arn:test:extension"] },
            { name: "Func2", hasLayers: true, layers: ["arn:test:extension"] },
          ]);
          fsMock.mockCloudFormationTemplate(template);
        },
        expectedValid: true,
        expectedValidationResult: {
          totalFunctions: 2,
          functionsWithExtension: ["Func1LambdaFunction", "Func2LambdaFunction"],
          functionsMissingExtension: [],
        },
      },
      {
        description: "functions missing extension with layerCheck enabled",
        extensionArn: "arn:test:extension",
        layerCheckEnabled: true,
        setupMocks: () => {
          const template = createCloudFormationTemplate([
            { name: "Func1", hasLayers: true, layers: ["arn:test:extension"] },
            { name: "Func2", hasLayers: false },
          ]);
          fsMock.mockCloudFormationTemplate(template);
        },
        expectedValid: false,
        expectedError:
          "Layer check failed: 1 function(s) missing Dust Lambda Extension: Func2LambdaFunction",
        expectedValidationResult: {
          totalFunctions: 2,
          functionsWithExtension: ["Func1LambdaFunction"],
          functionsMissingExtension: ["Func2LambdaFunction"],
        },
      },
      {
        description: "functions missing extension with layerCheck disabled",
        extensionArn: "arn:test:extension",
        layerCheckEnabled: false,
        setupMocks: () => {
          const template = createCloudFormationTemplate([
            { name: "Func1", hasLayers: true, layers: ["arn:test:extension"] },
            { name: "Func2", hasLayers: false },
          ]);
          fsMock.mockCloudFormationTemplate(template);
        },
        expectedValid: true,
        expectedValidationResult: {
          totalFunctions: 2,
          functionsWithExtension: ["Func1LambdaFunction"],
          functionsMissingExtension: ["Func2LambdaFunction"],
        },
      },
      {
        description: "CloudFormation template not found with layerCheck enabled",
        extensionArn: "arn:test:extension",
        layerCheckEnabled: true,
        setupMocks: () => {
          fsMock.mockCloudFormationTemplateNotFound();
        },
        expectedValid: false,
        expectedError: "Layer check failed: CloudFormation template not found at",
      },
      {
        description: "CloudFormation template not found with layerCheck disabled",
        extensionArn: "arn:test:extension",
        layerCheckEnabled: false,
        setupMocks: () => {
          fsMock.mockCloudFormationTemplateNotFound();
        },
        expectedValid: true,
      },
      {
        description: "invalid JSON in template with layerCheck enabled",
        extensionArn: "arn:test:extension",
        layerCheckEnabled: true,
        setupMocks: () => {
          fsMock.readFileSync.mockReturnValue("{ invalid json }");
        },
        expectedValid: false,
        expectedError: "Layer check failed: Invalid JSON in CloudFormation template",
      },
    ])(
      "$description",
      ({
        extensionArn,
        layerCheckEnabled,
        setupMocks,
        expectedValid,
        expectedError,
        expectedValidationResult,
      }) => {
        it("should validate correctly", () => {
          if (setupMocks) {
            setupMocks();
          }

          const { plugin } = new TestSetupBuilder().build();

          // Access private method for unit testing
          const result = (plugin as any).performLayerValidation(extensionArn, layerCheckEnabled);

          expect(result.valid).toBe(expectedValid);
          if (expectedError) {
            expect(result.error).toContain(expectedError);
          } else {
            expect(result.error).toBeUndefined();
          }
          if (expectedValidationResult) {
            expect(result.validationResult).toEqual(expectedValidationResult);
          }
        });
      }
    );
  });
});
