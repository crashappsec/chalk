import {
  ServerlessError,
} from "./__mocks__/serverless.mock";
import * as childProcessMock from "./__mocks__/child_process";
import * as fsMock from "./__mocks__/fs";
import * as httpsMock from "./__mocks__/https";
import * as path from "path";
import {
  executeProviderConfigHook,
  executeDeploymentHook,
  executeAwsPackageHook,
  executeValidationHook,
  TestSetupBuilder,
  assertions,
  createCloudFormationTemplate,
} from "./__tests__/test-helpers";

jest.mock("child_process", () => require("./__mocks__/child_process"));
jest.mock("fs", () => require("./__mocks__/fs"));
jest.mock("https", () => require("./__mocks__/https"));
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
    httpsMock.resetMock();

    originalEnv = { ...process.env };
    originalPlatform = process.platform;
  });

  afterEach(() => {
    process.env = originalEnv;
    Object.defineProperty(process, 'platform', {
      value: originalPlatform,
    });
  });

  describe("Platform Support", () => {
    it("should early exit and not register hooks on Windows", () => {
      // Mock process.platform to return 'win32'
      Object.defineProperty(process, 'platform', {
        value: 'win32',
        configurable: true,
      });

      const { plugin, mockLog } = new TestSetupBuilder().build();

      // Verify warning was logged
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining("Crash Override plugin is not supported on Windows")
      );

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
      Object.defineProperty(process, 'platform', {
        value: 'linux',
        configurable: true,
      });

      const { plugin, mockLog } = new TestSetupBuilder().build();

      // Verify no Windows warning was logged
      expect(mockLog.warning).not.toHaveBeenCalledWith(
        expect.stringContaining("Windows")
      );

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

      it("should successfully log chalk binary was found", () => {
        const { plugin, mockLog } = new TestSetupBuilder()
          .withChalkAvailable()
          .withPackageZipExists()
          .build();

        executeDeploymentHook(plugin);

        expect(mockLog.notice).toHaveBeenCalledWith(
          expect.stringContaining("Initializing package process")
        );
        expect(mockLog.success).toHaveBeenCalledWith(
          expect.stringContaining("Chalk binary found")
        );
      });

      it("should read provider configuration correctly", () => {
        const { plugin, mockLog } = new TestSetupBuilder()
          .withProviderMemory(1234)
          .withProviderRegion("us-west-2")
          .build();

        executeProviderConfigHook(plugin);

        expect(mockLog.info).toHaveBeenCalledWith(
          expect.stringContaining(`provider=aws`)
        );
        expect(mockLog.info).toHaveBeenCalledWith(
          expect.stringContaining(`region=us-west-2`)
        );
        expect(mockLog.info).toHaveBeenCalledWith(
          expect.stringContaining(`memorySize=1234`)
        );
      });

        it("should prioritize serverless.yml config over environment variables", () => {
          const { mockLog } = new TestSetupBuilder()
            .withEnvironmentVar("CO_MEMORY_CHECK", "false")
            .withEnvironmentVar("CO_MEMORY_CHECK_SIZE_MB", "1024")
            .withEnvironmentVar("CO_CHALK_CHECK_ENABLED", "false")
            .withCustomConfig({
              memoryCheck: true,
              memoryCheckSize: 512,
              chalkCheck: true,
            })
            .build();

                assertions.expectConfigValues(mockLog, true, 512, true);
        });

        it("should use environment variables when serverless.yml config is not provided", () => {
          const { mockLog } = new TestSetupBuilder()
            .withEnvironmentVar("CO_MEMORY_CHECK", "true")
            .withEnvironmentVar("CO_MEMORY_CHECK_SIZE_MB", "1024")
            .withEnvironmentVar("CO_CHALK_CHECK_ENABLED", "true")
            .build();

          assertions.expectConfigValues(mockLog, true, 1024, true);
        });

        it("should use default values when no configuration is provided", () => {
          const { mockLog } = new TestSetupBuilder().build();

          assertions.expectConfigValues(mockLog, false, 256, false);
        });

        it("should handle invalid memoryCheckSize in environment variable", () => {
          expect(() => {
            new TestSetupBuilder()
              .withEnvironmentVar("CO_MEMORY_CHECK_SIZE_MB", "invalid")
              .build();
          }).toThrow(ServerlessError);
        });

        it("should merge configurations with correct precedence", () => {
          const { mockLog } = new TestSetupBuilder()
            .withEnvironmentVar("CO_MEMORY_CHECK", "true")
            .withEnvironmentVar("CO_MEMORY_CHECK_SIZE_MB", "1024")
            .withCustomConfig({
              memoryCheckSize: 512,
              chalkCheck: true,
            })
            .build();

          assertions.expectConfigValues(mockLog, true, 512, true);
        });

    it("should handle boolean string values in environment variables correctly", () => {
      const { mockLog } = new TestSetupBuilder()
        .withEnvironmentVar("CO_MEMORY_CHECK", "TRUE")
        .withEnvironmentVar("CO_CHALK_CHECK_ENABLED", "FALSE")
        .build();

      assertions.expectConfigValues(mockLog, true, 256, false);
    });
    });
  });

  describe("Memory Check Validation", () => {
    describe("Memory check validation failure", () => {
      it("should fail when memoryCheck=true and memoryCheckSize is greater than provider memorySize", () => {
        const { plugin } = new TestSetupBuilder()
          .withMemoryCheck(true, 2048)
          .withProviderMemory(1024)
          .build();

        executeProviderConfigHook(plugin);

        expect(() => executeDeploymentHook(plugin)).toThrow(ServerlessError);
        expect(() => executeDeploymentHook(plugin)).toThrow(
          "Memory check failed: memorySize (1024MB) is less than minimum required (2048MB)"
        );
      });

      it("should compare configured memory with memoryCheckSize", () => {
        const { plugin, mockLog } = new TestSetupBuilder()
          .withMemoryCheck(true, 512)
          .withProviderMemory(1024)
          .build();

        executeProviderConfigHook(plugin);
        executeDeploymentHook(plugin);

        expect(mockLog.info).toHaveBeenCalledWith(
          expect.stringContaining(`Memory check passed: 1024MB >= 512MB`)
        );
      });

      it("should throw error when memoryCheckSize is larger than provider memorySize", () => {
        const { plugin, mockLog } = new TestSetupBuilder()
          .withCustomConfig({
            memoryCheck: true,
            memoryCheckSize: 2048,
            chalkCheck: false,
          })
          .withProviderMemory(1024)
          .build();

        executeProviderConfigHook(plugin);

        expect(() => executeDeploymentHook(plugin)).toThrow(ServerlessError);
        expect(mockLog.error).toHaveBeenCalledWith(
          expect.stringContaining("Memory check failed")
        );
      });
    });

    it("should only warn when memoryCheck=false and memory is insufficient", () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withMemoryCheck(false, 2048)
        .withProviderMemory(1024)
        .build();

      expect(() => executeProviderConfigHook(plugin)).not.toThrow();
      expect(() => executeDeploymentHook(plugin)).not.toThrow();
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining(
          `Memory size (1024MB) is below recommended minimum (2048). Set custom.crashoverride.memoryCheck: true to enforce this requirement`
      ));
    });
  });

  describe("Chalk Binary Validation", () => {
    it("should fail when chalkCheck=true and chalk is not available", () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withChalkNotAvailable()
        .withCustomConfig({
            memoryCheck: false,
            memoryCheckSize: 256,
            chalkCheck: true,
        })
        .build();

      expect(() => executeDeploymentHook(plugin)).toThrow(ServerlessError);
      expect(() => executeDeploymentHook(plugin)).toThrow("Chalk check failed: chalk binary not found in PATH");
      expect(mockLog.error).toHaveBeenCalledWith(
        expect.stringContaining("Chalk check failed")
      );
    });

    it("should succeed when chalkCheck=true and chalk is available", () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withChalkAvailable()
        .withCustomConfig({
            memoryCheck: false,
            memoryCheckSize: 256,
            chalkCheck: true,
        })
        .build();

      expect(() => executeDeploymentHook(plugin)).not.toThrow();
      expect(mockLog.success).toHaveBeenCalledWith(
        expect.stringContaining("Chalk binary found")
      );
    });

    it("should continue without error when chalkCheck=false and chalk is not available", () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withChalkNotAvailable()
        .withCustomConfig({
          memoryCheck: false,
          memoryCheckSize: 256,
          chalkCheck: false,
        })
        .build();

      expect(() => executeDeploymentHook(plugin)).not.toThrow();
      expect(mockLog.info).toHaveBeenCalledWith(
        expect.stringContaining("Chalk binary not found in PATH")
      );
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining("Chalk binary not available. Continuing without chalkmarks")
      );
    });

    it("should inject chalk binary when available", async () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withChalkAvailable()
        .withPackageZipExists()
        .withServiceName("test-service")
        .build();

      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      expect(childProcessMock.execSync).toHaveBeenCalledWith(
        expect.stringContaining("chalk insert --inject-binary-into-zip"),
        expect.any(Object)
      );
      expect(mockLog.success).toHaveBeenCalledWith(
        expect.stringContaining("Successfully injected chalkmarks")
      );
    });

    it("should warn its skipping injection when chalk is not available", async () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withChalkNotAvailable()
        .withPackageZipExists()
        .build();

      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      expect(childProcessMock.execSync).not.toHaveBeenCalledWith(
        expect.stringContaining("chalk insert"),
        expect.any(Object)
      );
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining("skipping chalkmark injection")
      );
    });
  });

  describe("Lambda Extension Management", () => {
    it("should add Dust Lambda Extension to all functions", async () => {
      const sampleFunctions = {
          function1: {
              handler: "handler.function1",
              runtime: "nodejs18.x",
              memorySize: 512,
              timeout: 30,
              layers: [],
          },
          function2: {
              handler: "handler.function2",
              runtime: "nodejs18.x",
              memorySize: 1024,
              timeout: 60,
              layers: ["arn:aws:lambda:us-east-1:123456789012:layer:existing-layer"],
          },
          function3: {
              handler: "handler.function3",
              runtime: "nodejs18.x",
              memorySize: 256,
              timeout: 15,
          },
      }
      const { plugin, mockServerless, mockLog } = new TestSetupBuilder()
        .withFunctions(sampleFunctions)
        .build();

      executeProviderConfigHook(plugin);
      await executeAwsPackageHook(plugin);

      const extensionArn = "arn:aws:lambda:us-east-1:123456789012:layer:test-crashoverride-dust-extension:8";
      const expectedCount = Object.keys(sampleFunctions).length;
      let count = 0;

      Object.keys(mockServerless.service.functions || {}).forEach((funcName) => {
        const func = mockServerless.service.functions[funcName] as any;
        if (func.layers && func.layers.includes(extensionArn)) {
          count++;
        }
      });

      expect(count).toBe(expectedCount);
      expect(mockLog.success).toHaveBeenCalledWith(
        expect.stringContaining(`Successfully added Dust Lambda Extension to 3 function(s)`)
      );
    });

    it("should fail when adding extension would exceed 15 layers limit", async () => {
        const maxLayers = {
            maxedFunction: {
                handler: "handler.maxed",
                runtime: "nodejs18.x",
                layers: [
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer1",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer2",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer3",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer4",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer5",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer6",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer7",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer8",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer9",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer10",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer11",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer12",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer13",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer14",
                    "arn:aws:lambda:us-east-1:123456789012:layer:layer15",
                ],
            },
        }
      const { plugin, mockLog } = new TestSetupBuilder()
        .withFunctions(maxLayers)
        .build();

      executeProviderConfigHook(plugin);
      await expect(executeAwsPackageHook(plugin)).rejects.toThrow(ServerlessError);

      // Check the error message in the mock logs
      try {
        executeProviderConfigHook(plugin);
        await executeAwsPackageHook(plugin);
      } catch (e: any) {
        expect(e.message).toContain("would exceed maximum layer/extension limit");
      }

      expect(mockLog.error).toHaveBeenCalledWith(
        expect.stringContaining("Cannot add Dust Lambda Extension")
      );
    });

    it("should handle functions with existing layers", async () => {
      const { plugin, mockServerless } = new TestSetupBuilder()
        .withFunctions({
          function2: {
            handler: "handler.function2",
            runtime: "nodejs18.x",
            memorySize: 1024,
            timeout: 60,
            layers: ["arn:aws:lambda:us-east-1:123456789012:layer:existing-layer"],
          }
        })
        .build();

      executeProviderConfigHook(plugin);
      await executeAwsPackageHook(plugin);

      const func = mockServerless.service.functions["function2"] as any;
      expect(func.layers).toHaveLength(2);
      expect(func.layers).toContain("arn:aws:lambda:us-east-1:123456789012:layer:test-crashoverride-dust-extension:8");
      expect(func.layers).toContain("arn:aws:lambda:us-east-1:123456789012:layer:existing-layer");
    });

    it("should handle service with no functions", async () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withFunctions({})
        .build();

      executeProviderConfigHook(plugin);
      await expect(executeAwsPackageHook(plugin)).resolves.not.toThrow();
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining("No functions found in service")
      );
    });
  });

  describe("getServerlessPackagingLocation", () => {
    let originalCwd: () => string;

    beforeEach(() => {
      originalCwd = process.cwd;
      jest.spyOn(process, 'cwd').mockReturnValue('/mock/cwd');
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
          description: "absolute servicePath with default package path"
        },
        {
          servicePath: "./relative/path",
          packagePath: undefined,
          expected: "relative/path/.serverless", // Will be checked with toContain
          description: "relative servicePath with default package path"
        },
        {
          servicePath: undefined,
          packagePath: undefined,
          expected: "/mock/cwd/.serverless",
          description: "undefined servicePath with default package path",
          shouldCallCwd: true
        },
        {
          servicePath: "",
          packagePath: undefined,
          expected: "/mock/cwd/.serverless",
          description: "empty servicePath with default package path",
          shouldCallCwd: true
        },
        // Custom package paths
        {
          servicePath: "/service/path",
          packagePath: "/absolute/package/path",
          expected: "/absolute/package/path",
          description: "absolute package path"
        },
        {
          servicePath: "/service/path",
          packagePath: "custom/package/dir",
          expected: "/service/path/custom/package/dir",
          description: "relative package path"
        },
        {
          servicePath: undefined,
          packagePath: "dist/serverless",
          expected: "/mock/cwd/dist/serverless",
          description: "undefined servicePath with custom package path",
          shouldCallCwd: true
        },
        // Edge cases
        {
          servicePath: "/path/with/trailing/slash/",
          packagePath: undefined,
          expected: "/path/with/trailing/slash/.serverless",
          description: "servicePath with trailing slash"
        },
        {
          servicePath: "/service/path",
          packagePath: "",
          expected: "/service/path/.serverless",
          description: "empty package path falls back to default"
        }
      ];

      test.each(testCases)(
        '$description',
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
          if (servicePath?.startsWith('./')) {
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
        ["/service/sub/path", "../parent/package", "/service/sub/parent/package", "parent directory references"],
        ["/service/path", "./nested/./package", "/service/path/nested/package", "current directory references"],
        ["/service/sub/deep", "../../up/two", "/service/up/two", "multiple parent directory references"],
        ["/service", "./././nested", "/service/nested", "multiple current directory references"]
      ])(
        'should handle %s with packagePath=%s correctly',
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
      const result = (plugin as any).parseCloudFormationTemplate('/path/to/template.json');

      expect(result).toEqual(template);
    });

    it("should throw meaningful error for missing file", () => {
      fsMock.readFileSync.mockImplementation(() => {
        const error: any = new Error('ENOENT');
        error.code = 'ENOENT';
        throw error;
      });

      const { plugin } = new TestSetupBuilder().build();

      expect(() => (plugin as any).parseCloudFormationTemplate('/path/to/template.json'))
        .toThrow('CloudFormation template not found at /path/to/template.json');
    });

    it("should throw meaningful error for invalid JSON", () => {
      fsMock.readFileSync.mockReturnValue('{ invalid json }');

      const { plugin } = new TestSetupBuilder().build();

      expect(() => (plugin as any).parseCloudFormationTemplate('/path/to/template.json'))
        .toThrow('Invalid JSON in CloudFormation template');
    });

    it("should wrap unexpected errors", () => {
      fsMock.readFileSync.mockImplementation(() => {
        throw new Error('Unexpected error');
      });

      const { plugin } = new TestSetupBuilder().build();

      expect(() => (plugin as any).parseCloudFormationTemplate('/path/to/template.json'))
        .toThrow('Failed to parse CloudFormation template: Unexpected error');
    });
  });

  describe("Function Validation Logic", () => {
    it("should correctly identify functions with and without extension", () => {
      const template = createCloudFormationTemplate([
        { name: 'Function1', hasLayers: true, layers: ['arn:test'] },
        { name: 'Function2', hasLayers: false }
      ]);

      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).validateFunctionsInTemplate(template, 'arn:test');

      expect(result).toEqual({
        totalFunctions: 2,
        functionsWithExtension: ['Function1LambdaFunction'],
        functionsMissingExtension: ['Function2LambdaFunction']
      });
    });

    it("should handle template with no Lambda functions", () => {
      const template = {
        Resources: {
          SomeOtherResource: {
            Type: 'AWS::S3::Bucket'
          }
        }
      };

      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).validateFunctionsInTemplate(template, 'arn:test');

      expect(result).toEqual({
        totalFunctions: 0,
        functionsWithExtension: [],
        functionsMissingExtension: []
      });
    });

    it("should handle functions with no Layers property", () => {
      const template = {
        Resources: {
          MyFunction: {
            Type: 'AWS::Lambda::Function',
            Properties: {
              Handler: 'index.handler'
              // No Layers property
            }
          }
        }
      };

      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).validateFunctionsInTemplate(template, 'arn:test');

      expect(result).toEqual({
        totalFunctions: 1,
        functionsWithExtension: [],
        functionsMissingExtension: ['MyFunction']
      });
    });

    it("should handle template with no Resources section", () => {
      const template = {};

      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).validateFunctionsInTemplate(template, 'arn:test');

      expect(result).toEqual({
        totalFunctions: 0,
        functionsWithExtension: [],
        functionsMissingExtension: []
      });
    });

    it("should check multiple functions correctly", () => {
      const arn = 'arn:aws:lambda:us-east-1:123:layer:dust:1';
      const template = {
        Resources: {
          Func1: {
            Type: 'AWS::Lambda::Function',
            Properties: { Layers: [arn] }
          },
          Func2: {
            Type: 'AWS::Lambda::Function',
            Properties: { Layers: ['other-arn'] }
          },
          Func3: {
            Type: 'AWS::Lambda::Function',
            Properties: { Layers: [arn, 'other-arn'] }
          },
          NotAFunction: {
            Type: 'AWS::S3::Bucket'
          }
        }
      };

      const { plugin } = new TestSetupBuilder().build();
      const result = (plugin as any).validateFunctionsInTemplate(template, arn);

      expect(result).toEqual({
        totalFunctions: 3,
        functionsWithExtension: ['Func1', 'Func3'],
        functionsMissingExtension: ['Func2']
      });
    });
  });

  describe("Status Message Building", () => {
    it("should build comprehensive status message", () => {
      const result = {
        totalFunctions: 3,
        functionsWithExtension: ['Function1', 'Function2'],
        functionsMissingExtension: ['Function3']
      };

      const { plugin } = new TestSetupBuilder().build();
      const message = (plugin as any).buildStatusMessage(result);

      expect(message).toContain('Layer check status:');
      expect(message).toContain(' Functions with Dust Extension (2/3):');
      expect(message).toContain('- Function1');
      expect(message).toContain('- Function2');
      expect(message).toContain(' Functions MISSING Dust Extension (1/3):');
      expect(message).toContain('- Function3');
    });
  });

  describe("Layer Check Validation", () => {
    const dustExtensionArn = "arn:aws:lambda:us-east-1:224111541501:layer:test-crashoverride-dust-extension:8";

    beforeEach(() => {
      httpsMock.mockDustExtensionArn(dustExtensionArn);
    });

    it("should pass validation when all functions have Dust extension", async () => {
      const template = createCloudFormationTemplate([
        { name: 'Handler', hasLayers: true, layers: [dustExtensionArn] },
        { name: 'Worker', hasLayers: true, layers: [dustExtensionArn] },
      ]);

      const { plugin, mockLog } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({
          handler: { handler: 'handler.handler' },
          worker: { handler: 'worker.handler' }
        })
        .build();

      fsMock.mockCloudFormationTemplate(template);

      // Execute hooks to set up extension ARN
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      // Should not throw
      expect(() => executeValidationHook(plugin)).not.toThrow();

      expect(mockLog.success).toHaveBeenCalledWith(
        expect.stringContaining("Layer check passed: All 2 function(s) have Dust Lambda Extension")
      );
    });

    it("should throw an error when layerCheck=true and functions missing extension", async () => {
      const template = createCloudFormationTemplate([
        { name: 'Handler', hasLayers: true, layers: [dustExtensionArn] },
        { name: 'Worker', hasLayers: false },
        { name: 'Processor', hasLayers: false },
      ]);

      const { plugin, mockLog } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({
          handler: { handler: 'handler.handler' },
          worker: { handler: 'worker.handler' },
          processor: { handler: 'processor.handler' }
        })
        .build();

      fsMock.mockCloudFormationTemplate(template);

      // Execute hooks to set up extension ARN
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      // Should throw with comprehensive error
      expect(() => executeValidationHook(plugin)).toThrow(
        "Layer check failed: 2 function(s) missing Dust Lambda Extension: WorkerLambdaFunction, ProcessorLambdaFunction"
      );

      // Should log comprehensive status
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining(" Functions with Dust Extension (1/3)")
      );
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining(" Functions MISSING Dust Extension (2/3)")
      );
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining("HandlerLambdaFunction")
      );
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining("WorkerLambdaFunction")
      );
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining("ProcessorLambdaFunction")
      );
    });

    it("should warn but not throw when layerCheck=false and functions missing extension", async () => {
      const template = createCloudFormationTemplate([
        { name: 'Handler', hasLayers: true, layers: [dustExtensionArn] },
        { name: 'Worker', hasLayers: false },
      ]);

      const { plugin, mockLog } = new TestSetupBuilder()
        .withLayerCheck(false)  // layerCheck disabled
        .withFunctions({
          handler: { handler: 'handler.handler' },
          worker: { handler: 'worker.handler' }
        })
        .build();

      fsMock.mockCloudFormationTemplate(template);

      // Execute hooks to set up extension ARN
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      // Should not throw
      expect(() => executeValidationHook(plugin)).not.toThrow();

      // Should log warning with status
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining("Functions with Dust Extension (1/2)")
      );
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining("Functions MISSING Dust Extension (1/2)")
      );
      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining("1 function(s) missing Dust Lambda Extension. Set custom.crashoverride.layerCheck: true to enforce this requirement")
      );
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
            }
          }
        }
      };

      const { plugin, mockLog } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({
          handler: { handler: 'handler.handler' }
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
            Properties: {}
          }
        }
      };

      const { plugin, mockLog } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({
          handler: { handler: 'handler.handler' }  // Function in service config
        })
        .build();

      fsMock.mockCloudFormationTemplate(template);  // But no functions in CloudFormation

      // Execute hooks
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);  // Will set dustExtensionArn

      // Should not throw
      expect(() => executeValidationHook(plugin)).not.toThrow();

      expect(mockLog.info).toHaveBeenCalledWith(
        expect.stringContaining("Layer check: No Lambda functions found in CloudFormation template")
      );
    });

    it("should handle missing CloudFormation template file", async () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({
          handler: { handler: 'handler.handler' }
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
          handler: { handler: 'handler.handler' }
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
      const { plugin, mockLog } = new TestSetupBuilder()
        .withLayerCheck(true)
        .withFunctions({})  // No functions, so no ARN will be fetched
        .build();

      // Execute hooks - no functions means no ARN is fetched
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);

      // Should throw error when layerCheck is enforced
      expect(() => executeValidationHook(plugin)).toThrow(
        "Cannot perform layer check: No Dust extension ARN available"
      );

      expect(mockLog.error).toHaveBeenCalledWith(
        "Cannot perform layer check: No Dust extension ARN available"
      );
    });

    it("should skip validation when layerCheck=false and no Dust extension ARN available", async () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withLayerCheck(false)  // layerCheck disabled
        .withFunctions({})  // No functions, so no ARN will be fetched
        .build();

      // Execute hooks - no functions means no ARN is fetched
      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);

      // Should not throw and should skip validation
      expect(() => executeValidationHook(plugin)).not.toThrow();

      expect(mockLog.info).toHaveBeenCalledWith(
        "Layer check skipped: No Dust extension ARN available"
      );
    });
  });

  describe("Package Processing", () => {
    it("should handle missing package zip file gracefully", async () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withChalkAvailable()
        .build();

      fsMock.existsSync.mockReturnValue(false);

      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      expect(mockLog.warning).toHaveBeenCalledWith(
        expect.stringContaining("Package zip file not found")
      );
      expect(mockLog.error).toHaveBeenCalledWith(
        expect.stringContaining("Could not locate package zip file")
      );
    });

    it("should handle chalk injection errors gracefully", async () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withChalkAvailable()
        .withPackageZipExists()
        .build();

      // Override the mock after builder sets it up to simulate injection failure
      childProcessMock.execSync.mockImplementation((command: string) => {
        if (command === "command -v chalk") {
          return Buffer.from("/usr/local/bin/chalk");
        }
        if (command.includes("chalk insert")) {
          throw new Error("Injection failed");
        }
        return Buffer.from("");
      });

      executeProviderConfigHook(plugin);
      executeDeploymentHook(plugin);
      await executeAwsPackageHook(plugin);

      expect(mockLog.error).toHaveBeenCalledWith(
        expect.stringContaining("Failed to inject chalkmarks")
      );
    });

    it("should handle provider config not being available", () => {
      const { plugin, mockLog } = new TestSetupBuilder()
        .withNoProvider()
        .build();

      executeProviderConfigHook(plugin);

      expect(mockLog.error).toHaveBeenCalledWith(
        expect.stringContaining("No provider configuration found")
      );
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
});
