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
  layerCheck: boolean;
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

export type FunctionValidationResult = {
  totalFunctions: number;
  functionsWithExtension: string[];
  functionsMissingExtension: string[];
};

export type CloudFormationResource = {
  Type: string;
  Properties?: {
    Layers?: string[];
    [key: string]: unknown;
  };
  [key: string]: unknown;
};

export type CloudFormationTemplate = {
  AWSTemplateFormatVersion?: string;
  Description?: string;
  Resources?: Record<string, CloudFormationResource>;
  [key: string]: unknown;
};
