import {
  parseBooleanEnv,
  parseStringEnv,
  parseIntegerEnv,
  parsePositiveIntegerEnv,
  parseEnvConfig,
  EnvParseError,
} from "./utils";

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

  describe("EnvParseError", () => {
    it("should create error with correct properties", () => {
      const error = new EnvParseError("TEST_VAR", "bad_value", "Test error message");

      expect(error).toBeInstanceOf(Error);
      expect(error.name).toBe("EnvParseError");
      expect(error.envName).toBe("TEST_VAR");
      expect(error.value).toBe("bad_value");
      expect(error.message).toBe("Test error message");
    });
  });

  describe("parseBooleanEnv", () => {
    describe.each([
      { input: "true", expected: true, description: "lowercase 'true'" },
      { input: "TRUE", expected: true, description: "uppercase 'TRUE'" },
      { input: "True", expected: true, description: "mixed case 'True'" },
      { input: "TrUe", expected: true, description: "mixed case 'TrUe'" },
    ])("should return true for $description", ({ input, expected }) => {
      it(`parseBooleanEnv("${input}")`, () => {
        expect(parseBooleanEnv(input)).toBe(expected);
      });
    });

    describe.each([
      { input: "false", expected: false, description: "lowercase 'false'" },
      { input: "FALSE", expected: false, description: "uppercase 'FALSE'" },
      { input: "False", expected: false, description: "mixed case 'False'" },
    ])("should return false for $description", ({ input, expected }) => {
      it(`parseBooleanEnv("${input}")`, () => {
        expect(parseBooleanEnv(input)).toBe(expected);
      });
    });

    test.each([
      ["yes", "string 'yes'"],
      ["1", "string '1'"],
      ["", "empty string"],
      ["anything", "string 'anything'"],
      ["0", "string '0'"],
    ])("should return false for non-'true' string: %s", (input) => {
      expect(parseBooleanEnv(input)).toBe(false);
    });

    it("should return undefined for undefined input", () => {
      expect(parseBooleanEnv(undefined)).toBeUndefined();
    });
  });

  describe("parseStringEnv", () => {
    test.each([
      ["test-value", "test-value"],
      ["", ""],
      ["https://example.com", "https://example.com"],
      ["  spaces  ", "  spaces  "],
    ])("should return the string value unchanged: %s", (input, expected) => {
      expect(parseStringEnv(input)).toBe(expected);
    });

    it("should return undefined for undefined input", () => {
      expect(parseStringEnv(undefined)).toBeUndefined();
    });
  });

  describe("parseIntegerEnv", () => {
    test.each([
      { input: "42", expected: 42, description: "positive integer" },
      { input: "0", expected: 0, description: "zero" },
      { input: "-100", expected: -100, description: "negative integer" },
      { input: "1024", expected: 1024, description: "large positive integer" },
      { input: " 42 ", expected: 42, description: "integer with whitespace" },
      { input: "12.5", expected: 12, description: "decimal string (truncated)" },
    ])("should parse valid integer strings: $description", ({ input, expected }) => {
      expect(parseIntegerEnv("TEST_VAR", input)).toBe(expected);
    });

    it("should return undefined for undefined input", () => {
      expect(parseIntegerEnv("TEST_VAR", undefined)).toBeUndefined();
    });

    test.each([
      ["not-a-number", "non-numeric string"],
      ["abc123", "alphanumeric string"],
      ["NaN", "NaN string"],
      ["Infinity", "Infinity string"],
    ])("should throw EnvParseError for invalid input: %s", (input) => {
      expect(() => parseIntegerEnv("TEST_VAR", input)).toThrow(EnvParseError);
    });

    it("should throw EnvParseError for unsafe integers", () => {
      const unsafeInt = (Number.MAX_SAFE_INTEGER + 1).toString();
      expect(() => parseIntegerEnv("TEST_VAR", unsafeInt)).toThrow(EnvParseError);
    });

    it("should include variable name in error message", () => {
      try {
        parseIntegerEnv("MY_VAR", "invalid");
        fail("Expected EnvParseError to be thrown");
      } catch (error) {
        expect(error).toBeInstanceOf(EnvParseError);
        if (error instanceof EnvParseError) {
          expect(error.envName).toBe("MY_VAR");
          expect(error.message).toContain("MY_VAR");
        }
      }
    });
  });

  describe("parsePositiveIntegerEnv", () => {
    test.each([
      { input: "1", expected: 1, description: "one" },
      { input: "42", expected: 42, description: "typical positive integer" },
      { input: "1000", expected: 1000, description: "large positive integer" },
      { input: "12.5", expected: 12, description: "decimal string (truncated to 12)" },
    ])("should parse valid positive integers: $description", ({ input, expected }) => {
      expect(parsePositiveIntegerEnv("TEST_VAR", input)).toBe(expected);
    });

    it("should return undefined for undefined input", () => {
      expect(parsePositiveIntegerEnv("TEST_VAR", undefined)).toBeUndefined();
    });

    test.each([
      { input: "0", description: "zero" },
      { input: "-1", description: "negative one" },
      { input: "-100", description: "negative integer" },
    ])("should throw EnvParseError for non-positive value: $description", ({ input }) => {
      expect(() => parsePositiveIntegerEnv("TEST_VAR", input)).toThrow(EnvParseError);
    });

    test.each([
      ["not-a-number", "non-numeric string"],
      ["abc", "alphabetic string"],
    ])("should throw EnvParseError for non-numeric strings: %s", (input) => {
      expect(() => parsePositiveIntegerEnv("TEST_VAR", input)).toThrow(EnvParseError);
    });

    it("should throw EnvParseError for unsafe integers", () => {
      const unsafeInt = (Number.MAX_SAFE_INTEGER + 1).toString();
      expect(() => parsePositiveIntegerEnv("TEST_VAR", unsafeInt)).toThrow(EnvParseError);
    });

    it("should include correct error message for non-positive values", () => {
      try {
        parsePositiveIntegerEnv("ARN_VERSION", "0");
        fail("Expected EnvParseError to be thrown");
      } catch (error) {
        expect(error).toBeInstanceOf(EnvParseError);
        if (error instanceof EnvParseError) {
          expect(error.envName).toBe("ARN_VERSION");
          expect(error.value).toBe("0");
          expect(error.message).toContain("positive integer");
        }
      }
    });
  });

  describe("parseEnvConfig", () => {
    describe.each([
      {
        envVar: "CO_MEMORY_CHECK",
        configKey: "memoryCheck",
        description: "memoryCheck",
      },
      {
        envVar: "CO_CHALK_CHECK_ENABLED",
        configKey: "chalkCheck",
        description: "chalkCheck",
      },
    ])("$description (boolean field)", ({ envVar, configKey }) => {
      it(`should parse ${envVar} as true`, () => {
        process.env[envVar] = "true";
        const config = parseEnvConfig();
        expect(config[configKey as keyof typeof config]).toBe(true);
      });

      it(`should parse ${envVar} as false`, () => {
        process.env[envVar] = "false";
        const config = parseEnvConfig();
        expect(config[configKey as keyof typeof config]).toBe(false);
      });

      it(`should omit ${configKey} if not set`, () => {
        const config = parseEnvConfig();
        expect(config[configKey as keyof typeof config]).toBeUndefined();
      });
    });

    describe("memoryCheckSize", () => {
      it("should parse CO_MEMORY_CHECK_SIZE_MB as integer", () => {
        process.env["CO_MEMORY_CHECK_SIZE_MB"] = "1024";
        const config = parseEnvConfig();
        expect(config.memoryCheckSize).toBe(1024);
      });

      it("should omit memoryCheckSize if not set", () => {
        const config = parseEnvConfig();
        expect(config.memoryCheckSize).toBeUndefined();
      });

      it("should throw EnvParseError for invalid integer", () => {
        process.env["CO_MEMORY_CHECK_SIZE_MB"] = "invalid";
        expect(() => parseEnvConfig()).toThrow(EnvParseError);
      });
    });

    describe("arnUrlPrefix", () => {
      it("should parse CO_ARN_URL_PREFIX as string", () => {
        process.env["CO_ARN_URL_PREFIX"] = "https://custom.example.com";
        const config = parseEnvConfig();
        expect(config.arnUrlPrefix).toBe("https://custom.example.com");
      });

      it("should omit arnUrlPrefix if not set", () => {
        const config = parseEnvConfig();
        expect(config.arnUrlPrefix).toBeUndefined();
      });
    });

    describe("arnVersion", () => {
      it("should parse CO_ARN_VERSION as positive integer", () => {
        process.env["CO_ARN_VERSION"] = "7";
        const config = parseEnvConfig();
        expect(config.arnVersion).toBe(7);
      });

      it("should omit arnVersion if not set", () => {
        const config = parseEnvConfig();
        expect(config.arnVersion).toBeUndefined();
      });

      test.each([
        { input: "0", description: "zero" },
        { input: "-1", description: "negative number" },
        { input: "invalid", description: "invalid value" },
      ])("should throw EnvParseError for $description", ({ input }) => {
        process.env["CO_ARN_VERSION"] = input;
        expect(() => parseEnvConfig()).toThrow(EnvParseError);
      });
    });

    describe("full configuration", () => {
      it("should parse all environment variables together", () => {
        process.env["CO_MEMORY_CHECK"] = "true";
        process.env["CO_MEMORY_CHECK_SIZE_MB"] = "512";
        process.env["CO_CHALK_CHECK_ENABLED"] = "false";
        process.env["CO_ARN_URL_PREFIX"] = "https://dl.example.com";
        process.env["CO_ARN_VERSION"] = "22";

        const config = parseEnvConfig();

        expect(config.memoryCheck).toBe(true);
        expect(config.memoryCheckSize).toBe(512);
        expect(config.chalkCheck).toBe(false);
        expect(config.arnUrlPrefix).toBe("https://dl.example.com");
        expect(config.arnVersion).toBe(22);
      });

      it("should return empty object when no env vars are set", () => {
        const config = parseEnvConfig();
        expect(config).toEqual({});
      });

      it("should handle partial configuration", () => {
        process.env["CO_MEMORY_CHECK"] = "true";
        process.env["CO_ARN_VERSION"] = "7";

        const config = parseEnvConfig();

        expect(config.memoryCheck).toBe(true);
        expect(config.arnVersion).toBe(7);
        expect(config.memoryCheckSize).toBeUndefined();
        expect(config.chalkCheck).toBeUndefined();
        expect(config.arnUrlPrefix).toBeUndefined();
      });
    });

    describe("error handling", () => {
      it("should propagate EnvParseError with correct details", () => {
        process.env["CO_MEMORY_CHECK_SIZE_MB"] = "not-a-number";

        try {
          parseEnvConfig();
          fail("Expected EnvParseError to be thrown");
        } catch (error) {
          expect(error).toBeInstanceOf(EnvParseError);
          if (error instanceof EnvParseError) {
            expect(error.envName).toBe("CO_MEMORY_CHECK_SIZE_MB");
            expect(error.value).toBe("not-a-number");
            expect(error.message).toContain("CO_MEMORY_CHECK_SIZE_MB");
          }
        }
      });

      it("should stop processing on first error", () => {
        // Set multiple invalid values
        process.env["CO_MEMORY_CHECK_SIZE_MB"] = "invalid";
        process.env["CO_ARN_VERSION"] = "invalid";

        // Should throw on the first error encountered (memoryCheckSize is processed first)
        expect(() => parseEnvConfig()).toThrow(EnvParseError);
      });
    });
  });
});
