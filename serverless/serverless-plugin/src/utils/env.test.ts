import { parseBooleanEnv, parseStringEnv, parseIntegerEnv, parsePositiveIntegerEnv } from "./env";

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

  describe("parseBooleanEnv", () => {
    test.each([
      { input: "true", expected: true, description: "lowercase 'true'" },
      { input: "TRUE", expected: true, description: "uppercase 'TRUE'" },
      { input: "True", expected: true, description: "mixed case 'True'" },
      { input: "TrUe", expected: true, description: "mixed case 'TrUe'" },
    ])("should return true for $description", ({ input, expected }) => {
      process.env.CO_TEST = input;
      expect(parseBooleanEnv("CO_TEST")).toBe(expected);
    });

    test.each([
      { input: "false", expected: false, description: "lowercase 'false'" },
      { input: "FALSE", expected: false, description: "uppercase 'FALSE'" },
      { input: "False", expected: false, description: "mixed case 'False'" },
    ])("should return false for $description", ({ input, expected }) => {
      process.env.CO_TEST = input;
      expect(parseBooleanEnv("CO_TEST")).toBe(expected);
    });

    test.each([
      ["yes", "string 'yes'"],
      ["1", "string '1'"],
      ["", "empty string"],
      ["anything", "string 'anything'"],
      ["0", "string '0'"],
    ])("should return false for non-'true' string: %s", (input) => {
      process.env.CO_TEST = input;
      expect(parseBooleanEnv("CO_TEST")).toBe(false);
    });
  });

  describe("parseStringEnv", () => {
    test.each([
      ["test-value", "test-value"],
      ["", ""],
      ["https://example.com", "https://example.com"],
      ["  spaces  ", "  spaces  "],
    ])("should return the string value unchanged: %s", (input, expected) => {
      process.env.CO_TEST = input;
      expect(parseStringEnv("CO_TEST")).toBe(expected);
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
      process.env.CO_TEST = input;
      expect(parseIntegerEnv("CO_TEST")).toBe(expected);
    });

    test.each([
      ["not-a-number", "non-numeric string"],
      ["abc123", "alphanumeric string"],
      ["NaN", "NaN string"],
      ["Infinity", "Infinity string"],
    ])("should throw error for invalid input: %s", (input) => {
      process.env.CO_TEST = input;
      expect(() => parseIntegerEnv("CO_TEST")).toThrow();
    });

    it("should throw error for unsafe integers", () => {
      const unsafeInt = (Number.MAX_SAFE_INTEGER + 1).toString();
      process.env.CO_TEST = unsafeInt.toString();
      expect(() => parseIntegerEnv("CO_TEST")).toThrow();
    });

    it("should include variable name in error message", () => {
      process.env.CO_TEST = "invalid";
      expect(() => parseIntegerEnv("CO_TEST")).toThrow(/CO_TEST/);
    });
  });

  describe("parsePositiveIntegerEnv", () => {
    test.each([
      { input: "0", description: "zero" },
      { input: "-1", description: "negative one" },
      { input: "-100", description: "negative integer" },
    ])("should throw error for non-positive value: $description", ({ input }) => {
      process.env.CO_TEST = input;
      expect(() => parsePositiveIntegerEnv("CO_TEST")).toThrow();
    });

    it("should include correct error message for non-positive values", () => {
      process.env.CO_TEST = "-1";
      expect(() => parsePositiveIntegerEnv("CO_TEST")).toThrow(/CO_TEST.*-1/);
    });
  });
});
