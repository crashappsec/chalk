// Custom plugin-specific configuration types
import type Serverless from "serverless";

// Runtime representation of AWS functions with layer support
// Combines Serverless function definitions with AWS-specific properties
export type RuntimeAwsFunction = (
  | Serverless.FunctionDefinitionHandler
  | Serverless.FunctionDefinitionImage
) & {
  layers?: string[];
};

export type PluginConfig = {
  enabled?: boolean;
  options?: Record<string, unknown>;
};

export type CrashOverrideConfig = {
  memoryCheck: boolean;
  memoryCheckSize: number;
  chalkCheck: boolean;
  arnUrlPrefix?: string;
  arnVersion?: number; // Optional version pinning for Dust Extension (e.g., 1, 7, 22)
};

export type CustomServerlessConfig = {
  crashoverride?: CrashOverrideConfig;
  [key: string]: PluginConfig | unknown;
};

export type ProviderConfig = {
  provider: string;
  region: string;
  memorySize: number;
};
