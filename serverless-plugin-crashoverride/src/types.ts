// Custom plugin-specific configuration interfaces
export interface PluginConfig {
  enabled?: boolean;
  options?: Record<string, unknown>;
}

export interface CustomServerlessConfig {
  [key: string]: PluginConfig | unknown;
}
