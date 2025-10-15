import type { CrashOverrideConfig } from "./types";

/**
 * Custom error class for environment variable parsing errors
 */
export class EnvParseError extends Error {
  constructor(
    public readonly envName: string,
    public readonly value: string,
    message: string
  ) {
    super(message);
    this.name = "EnvParseError";
  }
}

/**
 * Parse a boolean environment variable
 * @param value - The environment variable value
 * @returns true if value is "true" (case-insensitive), false if "false", undefined if not set
 */
export function parseBooleanEnv(value: string | undefined): boolean | undefined {
  if (value === undefined) {
    return undefined;
  }
  return value.toLowerCase() === "true";
}

/**
 * Parse a string environment variable
 * @param value - The environment variable value
 * @returns The string value or undefined if not set
 */
export function parseStringEnv(value: string | undefined): string | undefined {
  return value;
}

/**
 * Parse an integer environment variable with safe integer validation
 * @param envName - The name of the environment variable (for error messages)
 * @param value - The environment variable value
 * @returns The parsed integer or undefined if not set
 * @throws {EnvParseError} If the value is not a safe integer
 */
export function parseIntegerEnv(envName: string, value: string | undefined): number | undefined {
  if (value === undefined) {
    return undefined;
  }

  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed)) {
    throw new EnvParseError(
      envName,
      value,
      `Received invalid ${envName} value of: ${parsed}. Must be a safe integer.`
    );
  }

  return parsed;
}

/**
 * Parse a positive integer environment variable with validation
 * @param envName - The name of the environment variable (for error messages)
 * @param value - The environment variable value
 * @returns The parsed positive integer or undefined if not set
 * @throws {EnvParseError} If the value is not a safe positive integer
 */
export function parsePositiveIntegerEnv(
  envName: string,
  value: string | undefined
): number | undefined {
  if (value === undefined) {
    return undefined;
  }

  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new EnvParseError(
      envName,
      value,
      `Received invalid ${envName} value: ${value}. Must be a positive integer.`
    );
  }

  return parsed;
}

/**
 * Parse all Crash Override environment variables
 * @returns Partial configuration object with values from environment variables
 * @throws {EnvParseError} If any environment variable has an invalid format
 */
export function parseEnvConfig(): Partial<CrashOverrideConfig> {
  const envConfig: Partial<CrashOverrideConfig> = {};

  // Parse boolean flags
  const memoryCheck = parseBooleanEnv(process.env["CO_MEMORY_CHECK"]);
  if (memoryCheck !== undefined) {
    envConfig.memoryCheck = memoryCheck;
  }

  const chalkCheck = parseBooleanEnv(process.env["CO_CHALK_CHECK_ENABLED"]);
  if (chalkCheck !== undefined) {
    envConfig.chalkCheck = chalkCheck;
  }

  // Parse memory check size
  const memoryCheckSize = parseIntegerEnv(
    "CO_MEMORY_CHECK_SIZE_MB",
    process.env["CO_MEMORY_CHECK_SIZE_MB"]
  );
  if (memoryCheckSize !== undefined) {
    envConfig.memoryCheckSize = memoryCheckSize;
  }

  // Parse ARN URL prefix
  const arnUrlPrefix = parseStringEnv(process.env["CO_ARN_URL_PREFIX"]);
  if (arnUrlPrefix !== undefined) {
    envConfig.arnUrlPrefix = arnUrlPrefix;
  }

  // Parse ARN version (must be positive)
  const arnVersion = parsePositiveIntegerEnv("CO_ARN_VERSION", process.env["CO_ARN_VERSION"]);
  if (arnVersion !== undefined) {
    envConfig.arnVersion = arnVersion;
  }

  return envConfig;
}
