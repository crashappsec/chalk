// Custom plugin-specific configuration interfaces
export interface PluginConfig {
    enabled?: boolean;
    options?: Record<string, unknown>;
}

export interface CrashOverrideConfig {
    memoryCheck: boolean;
    memoryCheckSize: number;
    chalkCheck: boolean;
    arnUrlPrefix?: string;
}

export interface CustomServerlessConfig {
    crashoverride?: CrashOverrideConfig;
    [key: string]: PluginConfig | unknown;
}

export interface ProviderConfig {
    provider: string;
    region: string;
    memorySize: number;
}
