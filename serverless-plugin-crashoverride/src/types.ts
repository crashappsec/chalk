// Custom plugin-specific configuration types
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
}
