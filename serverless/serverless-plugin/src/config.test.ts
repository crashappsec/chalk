import { parseEnvConfig } from "./config";

describe("Environment Variable Utilities", () => {
  let originalEnv: NodeJS.ProcessEnv;

  beforeEach(() => {
    originalEnv = { ...process.env };
    // Clear all CO_ environment variables
    Object.keys(process.env).forEach((key) => {
      if (key.startsWith("CO_")) {
        delete process.env[key];
      }
    });
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  describe("parseEnvConfig", () => {
    describe("full configuration", () => {
      it("should parse all environment variables together", () => {
        process.env["CO_MEMORY_CHECK"] = "true";
        process.env["CO_MEMORY_CHECK_SIZE_MB"] = "512";
        process.env["CO_CHALK_CHECK_ENABLED"] = "false";
        process.env["CO_ARN_URL_PREFIX"] = "https://dl.example.com";
        process.env["CO_ARN_VERSION"] = "22";

        const config = parseEnvConfig();

        expect(config).toStrictEqual({
          memoryCheck: true,
          memoryCheckSize: 512,
          chalkCheck: false,
          arnUrlPrefix: "https://dl.example.com",
          arnVersion: "22",
        });
      });

      it("should return empty object when no env vars are set", () => {
        const config = parseEnvConfig();
        expect(config).toStrictEqual({});
      });
    });

    describe("partial configuration", () => {
      it("should handle partial configuration", () => {
        process.env["CO_MEMORY_CHECK"] = "true";
        process.env["CO_ARN_VERSION"] = "7";

        const config = parseEnvConfig();

        expect(config).toStrictEqual({
          memoryCheck: true,
          arnVersion: "7",
        });
      });
    });

    describe("error handling", () => {
      it("should erorr with invalid values", () => {
        process.env["CO_MEMORY_CHECK_SIZE_MB"] = "invalid";
        process.env["CO_ARN_VERSION"] = "invalid";
        expect(() => parseEnvConfig()).toThrow();
      });
    });
  });
});
