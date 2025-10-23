import Service from "serverless/classes/Service";

export type ErrorFunc = new (msg: string) => Error;

// Runtime representation of AWS functions with layer support
// Combines Serverless function definitions with AWS-specific properties
type ServiceFunctions = Service["functions"];
type ServiceFunction = ServiceFunctions[keyof ServiceFunctions];
export type AwsServiceFunction = ServiceFunction & { layers?: string[] };
export type AwsServiceFunctions = Record<string, AwsServiceFunction>;

export type CrashOverrideConfig = {
  memoryCheck: boolean;
  memoryCheckSize: number;
  chalkCheck: boolean;
  chalkPath: string;
  arnUrlPrefix: string;
  arnVersion: string;
  awsMaxLayers: number;
};

export type CustomServerlessConfig =
  | {
      crashoverride?: Partial<CrashOverrideConfig>;
    }
  | undefined;

export type ProviderConfig = {
  region: string;
  memorySize: number;
  dustExtensionArn: string;
  isChalkAvailable: boolean;
  zipPath: string;
};
