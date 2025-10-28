import type { CrashOverrideConfig, ErrorFunc } from "./types";
import {
  parseBooleanEnv,
  parseIntegerEnv,
  parsePositiveIntegerEnv,
  parseStringEnv,
} from "./utils/env";
import { nonNullable } from "./utils/types";

export const SUPPORTED_PLATFORMS = ["linux", "darwin"];

export const CONFIG_DEFAULTS: CrashOverrideConfig = {
  memoryCheck: true,
  memoryCheckSize: 256,
  chalkCheck: true,
  chalkPath: "chalk",
  arnUrlPrefix: "https://dl.crashoverride.run/dust",
  arnVersion: "latest",
  awsMaxLayers: 15,
};

export function parseEnvConfig(error?: ErrorFunc): Partial<CrashOverrideConfig> {
  return nonNullable({
    memoryCheck: parseBooleanEnv("CO_MEMORY_CHECK"),
    memoryCheckSize: parseIntegerEnv("CO_MEMORY_CHECK_SIZE_MB", error),
    chalkCheck: parseBooleanEnv("CO_CHALK_CHECK_ENABLED"),
    chalkPath: parseStringEnv("CO_CHALK_PATH"),
    arnUrlPrefix: parseStringEnv("CO_ARN_URL_PREFIX"),
    arnVersion: parsePositiveIntegerEnv("CO_ARN_VERSION", error)?.toString(),
  });
}

export function getConfig(
  envConfig: Partial<CrashOverrideConfig>,
  config?: Partial<CrashOverrideConfig>,
): Readonly<CrashOverrideConfig> {
  // Merge with precedence: defaults < env < serverless
  return Object.freeze({
    ...CONFIG_DEFAULTS,
    ...envConfig,
    ...(config ?? {}),
  });
}
