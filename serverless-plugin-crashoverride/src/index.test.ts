import CrashOverrideServerlessPlugin from "./index";
import {
  createMockServerless,
  createMockLogger,
  createMockOptions,
  ServerlessError,
} from "./__mocks__/serverless.mock";
import * as childProcessMock from "./__mocks__/child_process";
import * as fsMock from "./__mocks__/fs";
import {
  createPlugin,
  executeProviderConfigHook,
  executeDeploymentHook,
  executeAwsPackageHook,
  TestSetupBuilder,
  assertions,
} from "./__tests__/test-helpers";
import type Serverless from "serverless";

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
  let mockServerless: Serverless;
  let mockOptions: any;
  let mockLog: ReturnType<typeof createMockLogger>;
  let originalEnv: NodeJS.ProcessEnv;

  beforeEach(() => {
    jest.clearAllMocks();
    childProcessMock.resetMocks();
    fsMock.resetMocks();

    originalEnv = { ...process.env };

    mockServerless = createMockServerless();
    mockOptions = createMockOptions();
    mockLog = createMockLogger();
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  describe("Plugin Initialization", () => {
    describe("Successful plugin installation", () => {
      it("should initialize successfully with default configuration values", () => {
        const { plugin } = createPlugin();

        expect(plugin.config.memoryCheck).toBe(false);
        expect(plugin.config.memoryCheckSize).toBe(256);
        expect(plugin.config.chalkCheck).toBe(false);
      });

      it("should register lifecycle hooks correctly", () => {
        const { plugin } = createPlugin();

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
          const { mockLog } = createPlugin();

          assertions.expectConfigValues(mockLog, false, 256, false);
        });

        it("should handle invalid memoryCheckSize in environment variable", () => {
          process.env["CO_MEMORY_CHECK_SIZE_MB"] = "invalid";
          mockServerless = createMockServerless();

          expect(() => {
            new CrashOverrideServerlessPlugin(
              mockServerless,
              mockOptions,
              { log: mockLog }
            );
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
      // Set up package zip to exist
      fsMock.mockPackageZipExists();

      // Set up the mock to simulate chalk being available but injection failing
      childProcessMock.execSync.mockImplementation((command: string) => {
        if (command === "command -v chalk") {
          return Buffer.from("/usr/local/bin/chalk");
        }
        if (command.includes("chalk insert")) {
          throw new Error("Injection failed");
        }
        return Buffer.from("");
      });

      const { plugin, mockLog } = createPlugin();

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
