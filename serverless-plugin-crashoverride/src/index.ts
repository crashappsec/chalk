import type Serverless from "serverless";
import type Plugin from "serverless/classes/Plugin";
import type Aws from "serverless/plugins/aws/provider/awsProvider";
import type AwsProvider from "serverless/plugins/aws/provider/awsProvider";
import { execSync } from "child_process";
import * as path from "path";
import * as fs from "fs";
import chalk from "chalk"; // chalk the JS lib. Not chalk to CO project.
import type {
  CustomServerlessConfig,
  CrashOverrideConfig,
  ProviderConfig,
  RuntimeAwsFunction,
} from "./types";
import { parseEnvConfig, EnvParseError } from "./utils";

class CrashOverrideServerlessPlugin implements Plugin {
  hooks: Plugin.Hooks;
  readonly config: Readonly<CrashOverrideConfig>;
  readonly provider: AwsProvider;
  private isChalkAvailable: boolean = false;
  private providerConfig: ProviderConfig | null = null;
  private dustExtensionArn: string | null = null;

  constructor(
    readonly serverless: Serverless,
    readonly options: Serverless.Options = {},
    private readonly utils: Plugin.Logging
  ) {
    this.provider = serverless.getProvider("aws");

    // Check if running on supported UNIX-like platform and short-circuit if not
    const supportedPlatforms = ["linux", "darwin", "freebsd", "openbsd", "sunos", "aix"];
    if (!supportedPlatforms.includes(process.platform)) {
      this.utils.log.warning(
        chalk.yellow(
          `Crash Override plugin is not supported on ${
            process.platform
          }. Only UNIX-like platforms (${supportedPlatforms.join(
            ", "
          )}) are supported. Skipping plugin initialization.`
        )
      );
      this.hooks = {}; // do not register any hooks
      this.config = {
        memoryCheck: false,
        memoryCheckSize: 256,
        chalkCheck: false,
      };
      return;
    }

    this.config = this.initializeConfig();

    this.hooks = {
      "after:package:setupProviderConfiguration": this.handleSetupProviderConfiguration.bind(this),
      "after:package:createDeploymentArtifacts": this.handleCreateDeploymentArtifacts.bind(this),
      "before:package:compileFunctions": this.handleCompileFunctions.bind(this),
    };
  }

  // Helper logging methods
  private log_error(message: string): void {
    this.utils.log.error(chalk.red(`${message}`));
  }

  private log_warning(message: string): void {
    this.utils.log.warning(chalk.yellow(`${message}`));
  }

  private log_notice(message: string): void {
    this.utils.log.notice(chalk.cyan(`${message}`));
  }

  private log_success(message: string): void {
    this.utils.log.success(chalk.green(`${message}`));
  }

  private log_info(message: string): void {
    this.utils.log.info(chalk.gray(`${message}`));
  }

  private initializeConfig(): Readonly<CrashOverrideConfig> {
    // Default values (lowest precedence)
    const defaults: CrashOverrideConfig = {
      memoryCheck: false,
      memoryCheckSize: 256,
      chalkCheck: false,
      arnUrlPrefix: "https://dl.crashoverride.run/dust",
      // arnVersion is optional, undefined by default (uses latest version)
    };

    let envConfig: Partial<CrashOverrideConfig>;
    try {
      envConfig = parseEnvConfig();
    } catch (error) {
      if (error instanceof EnvParseError) {
        throw new this.serverless.classes.Error(error.message);
      }
      throw error;
    }

    // Serverless config (highest precedence)
    const customConfig: CustomServerlessConfig | undefined = this.serverless.service.custom;
    const serverlessConfig: Partial<CrashOverrideConfig> = customConfig?.crashoverride || {};

    // Merge with precedence: defaults < env < serverless
    const finalConfig: CrashOverrideConfig = {
      ...defaults,
      ...envConfig,
      ...serverlessConfig,
    };

    // Log the final configuration
    this.log_info(
      `CrashOverride config initialized:
        memoryCheck=${finalConfig.memoryCheck}
        memoryCheckSize=${finalConfig.memoryCheckSize}
        chalkCheck=${finalConfig.chalkCheck}
        arnVersion=${finalConfig.arnVersion ?? "latest"}`
    );

    return Object.freeze(finalConfig);
  }

  private handleSetupProviderConfiguration(): void {
    if (this.providerConfig != null) {
      // early exit if config has already been fetched
      return;
    }
    // Verify provider configuration is available
    const provider = this.serverless.service.provider as Aws.Provider;
    if (!provider) {
      this.log_error("No provider configuration found in serverless.yml");
      return;
    }

    // Parse memorySize to ensure it's a number
    let memorySize = 1024; // Serverless Framework AWS Lambda default
    if (provider.memorySize !== undefined) {
      memorySize =
        typeof provider.memorySize === "string"
          ? parseInt(provider.memorySize, 10)
          : provider.memorySize;
    }

    // Persist provider configuration
    this.providerConfig = {
      provider: "aws", // We're specifically an AWS plugin
      region: provider.region || "us-east-1", // AWS default region
      memorySize: memorySize,
    };

    // Log provider configuration for debugging
    this.log_info(
      `Provider config: provider=${this.providerConfig.provider}, region=${this.providerConfig.region}, memorySize=${this.providerConfig.memorySize}`
    );
  }

  private async fetchDustExtensionArn(region: string): Promise<string> {
    const urlPrefix = this.config.arnUrlPrefix;
    // Construct URL with version if specified, otherwise use latest
    const url = this.config.arnVersion
      ? `${urlPrefix}/${region}/extension-v${this.config.arnVersion}.arn`
      : `${urlPrefix}/${region}/extension.arn`;

    try {
      const response = await fetch(url);

      if (!response.ok) {
        const versionInfo = this.config.arnVersion ? ` (v${this.config.arnVersion})` : "";
        this.log_warning(
          `Failed to fetch Dust extension ARN for region ${region}${versionInfo}: HTTP ${response.status}`
        );
        throw new Error(`HTTP ${response.status}`);
      }

      const data = await response.text();
      const arn = data.trim();
      return arn;
    } catch (error) {
      const versionInfo = this.config.arnVersion ? ` (v${this.config.arnVersion})` : "";
      const errorMessage = error instanceof Error ? error.message : String(error);
      this.log_warning(
        `Failed to fetch Dust extension ARN for region ${region}${versionInfo}: ${errorMessage}`
      );
      throw error;
    }
  }

  private checkMemoryConfiguration(): boolean {
    // Ensure provider configuration has been fetched
    if (!this.providerConfig) {
      throw new this.serverless.classes.Error("Provider configuration not initialized");
    }

    const providerMemorySize = this.providerConfig.memorySize;
    return providerMemorySize >= this.config.memoryCheckSize;
  }

  private chalkBinaryAvailable(): boolean {
    try {
      execSync("which chalk");
      return true;
    } catch {
      return false;
    }
  }

  private getServerlessPackagingLocation(): string {
    return path.resolve(
      this.serverless.config.servicePath || process.cwd(),
      this.serverless.service.package?.["path"] || ".serverless"
    );
  }

  private handleCreateDeploymentArtifacts(): void {
    this.log_notice(`Dust Plugin: Initializing package process`);

    // Only check memory configuration if provider config was successfully fetched
    if (this.providerConfig) {
      const memoryCheckPassed = this.checkMemoryConfiguration();

      if (!memoryCheckPassed) {
        if (this.config.memoryCheck) {
          // When memoryCheck is true, fail the build
          const errorMessage = `Memory check failed: memorySize (${this.providerConfig.memorySize}MB) is less than minimum required (${this.config.memoryCheckSize}MB)`;
          this.log_error(errorMessage);
          throw new this.serverless.classes.Error(errorMessage);
        } else {
          // When memoryCheck is false, just warn
          this.log_warning(
            `Memory size (${this.providerConfig.memorySize}MB) is below recommended minimum (${this.config.memoryCheckSize}). Set custom.crashoverride.memoryCheck: true to enforce this requirement`
          );
        }
      } else if (this.config.memoryCheck) {
        // log success when check is enabled and passes
        this.log_info(
          `Memory check passed: ${this.providerConfig.memorySize}MB >= ${this.config.memoryCheckSize}MB`
        );
      }
    }

    // Check chalk availability once and store the result
    this.log_info(`Checking for chalk binary...`);
    this.isChalkAvailable = this.chalkBinaryAvailable();

    if (this.isChalkAvailable) {
      this.log_success(`Chalk binary found`);
      this.log_info(`Chalk binary found and will be used to add chalkmarks`);
    } else {
      if (this.config.chalkCheck) {
        const errorMessage = `Chalk check failed: chalk binary not found in PATH. Please add and try again.`;
        this.log_error(errorMessage);
        throw new this.serverless.classes.Error(errorMessage);
      } else {
        this.log_info(`Chalk binary not found in PATH`);
        this.log_warning(`Chalk binary not available. Continuing without chalkmarks`);
      }
    }
  }

  private getPackageZipPath(): string | null {
    const serviceName = this.serverless.service.service;
    // Default Serverless packaging location
    const zipPath = path.join(this.getServerlessPackagingLocation(), `${serviceName}.zip`);

    if (fs.existsSync(zipPath)) {
      return zipPath;
    }

    this.log_warning(`Package zip file not found at ${chalk.gray(zipPath)}`);
    return null;
  }

  private injectChalkBinary(zipPath: string): boolean {
    try {
      execSync(`chalk insert --inject-binary-into-zip "${zipPath}"`, {
        stdio: "pipe",
        encoding: "utf8",
      });
      return true;
    } catch (error) {
      return false;
    }
  }

  private validateLayerCount(
    functions: { [key: string]: RuntimeAwsFunction },
    maxLayers: number = 15
  ): { valid: boolean; errors: string[] } {
    const errors: string[] = [];

    for (const [functionName, func] of Object.entries(functions)) {
      if (!func) continue;

      // Access layers from the runtime AWS function
      const currentLayers = func.layers || [];

      if (currentLayers.length >= maxLayers) {
        errors.push(
          `Function ${functionName} has ${currentLayers.length} layers/extensions (max: ${maxLayers})`
        );
      }
    }

    return {
      valid: errors.length === 0,
      errors,
    };
  }

  private getArnWithoutVersion(arn: string): string {
    // ARN format: arn:aws:lambda:region:account:layer:name:version
    // Remove the version (last part) to compare ARNs
    const parts = arn.split(":");
    if (parts.length > 7) {
      return parts.slice(0, 7).join(":");
    }
    return arn;
  }

  private addDustLambdaExtension(
    functions: { [key: string]: RuntimeAwsFunction },
    extensionArn: string
  ): { success: boolean; skipped: string[]; added: string[] } {
    const skippedFunctions: string[] = [];
    const addedFunctions: string[] = [];

    try {
      const extensionArnBase = this.getArnWithoutVersion(extensionArn);

      // Add extension to all functions
      for (const [functionName, func] of Object.entries(functions)) {
        if (!func) continue;

        // Initialize layers array if not present
        if (!func.layers) {
          func.layers = [];
        }

        // Check if the same extension (ignoring version) already exists
        const alreadyHasExtension = func.layers.some(
          (layer) => this.getArnWithoutVersion(layer) === extensionArnBase
        );

        if (alreadyHasExtension) {
          skippedFunctions.push(functionName);
        } else {
          func.layers = [...(func.layers ?? []), extensionArn];
          addedFunctions.push(functionName);
        }
      }

      return { success: true, skipped: skippedFunctions, added: addedFunctions };
    } catch (error) {
      return { success: false, skipped: skippedFunctions, added: addedFunctions };
    }
  }

  private async handleCompileFunctions(): Promise<void> {
    this.log_notice(`Dust Plugin: Processing packaged functions`);

    // Check provider configuration
    if (this.providerConfig === null) {
      const errorMessage = `Cannot ascertain service's region from Provider configuration`;
      this.log_error(errorMessage);
      throw new Error(errorMessage);
    }

    // Get functions from service (cast to RuntimeAwsFunction for AWS-specific properties)
    const functions = (this.serverless.service.functions || {}) as {
      [key: string]: RuntimeAwsFunction;
    };
    const functionCount = Object.keys(functions).length;

    // Handle Dust Lambda Extension
    if (functionCount === 0) {
      this.log_warning(`No functions found in service - no extensions added`);
    } else {
      // Validate layer counts before proceeding
      const MAX_LAYERS_AND_EXTENSIONS = 15;
      const validation = this.validateLayerCount(functions, MAX_LAYERS_AND_EXTENSIONS);

      if (!validation.valid) {
        const errorMessage = `Cannot add Dust Lambda Extension: ${validation.errors.join(", ")}`;
        this.log_error(errorMessage);
        throw new this.serverless.classes.Error(errorMessage);
      }

      // Fetch extension ARN
      const extensionArn = await this.fetchDustExtensionArn(this.providerConfig.region);
      this.dustExtensionArn = extensionArn; // Store for later validation
      this.log_info(
        `Dust Extension ARN for ${this.providerConfig.region}${
          this.config.arnVersion ? ` (v${this.config.arnVersion})` : ""
        } :: ${extensionArn}`
      );

      this.log_notice(`Adding Dust Lambda Extension to all functions`);

      // Add extension to functions
      const result = this.addDustLambdaExtension(functions, extensionArn);

      if (result.success) {
        // Log individual function updates
        for (const functionName of result.added) {
          const func = functions[functionName];
          if (!func) continue;
          this.log_info(
            `Added Dust Lambda Extension to function: ${chalk.bold(functionName)} (${chalk.gray(
              `${func.layers?.length || 0}/${MAX_LAYERS_AND_EXTENSIONS} layers/extensions`
            )})`
          );
        }

        // Log skipped functions
        for (const functionName of result.skipped) {
          this.log_info(
            `Skipped function ${chalk.bold(functionName)}: Dust Lambda Extension already present`
          );
        }

        // Log summary
        if (result.added.length > 0 && result.skipped.length > 0) {
          this.log_success(
            `Successfully processed ${chalk.bold(functionCount)} function(s): ` +
              `${chalk.bold(result.added.length)} updated, ${chalk.bold(
                result.skipped.length
              )} skipped (already had extension)`
          );
        } else if (result.added.length > 0) {
          this.log_success(
            `Successfully added Dust Lambda Extension to ${chalk.bold(
              result.added.length
            )} function(s)`
          );
        } else if (result.skipped.length > 0) {
          this.log_success(
            `All ${chalk.bold(
              result.skipped.length
            )} function(s) already have Dust Lambda Extension`
          );
        }
      } else {
        const errorMessage = `Failed to add Dust Lambda Extension to functions`;
        this.log_error(errorMessage);
        throw new this.serverless.classes.Error(errorMessage);
      }
    }

    // Handle chalk binary injection
    if (!this.isChalkAvailable) {
      this.log_warning(`Chalk binary not available, skipping chalkmark injection`);
    } else {
      const zipPath = this.getPackageZipPath();
      if (!zipPath) {
        this.log_error(`Could not locate package zip file`);
      } else {
        this.log_info(`Injecting chalkmarks into ${chalk.gray(zipPath)}`);
        const injected = this.injectChalkBinary(zipPath);

        if (injected) {
          this.log_success(`Successfully injected chalkmarks into package`);
        } else {
          this.log_error(`Failed to inject chalkmarks into package`);
        }
      }
    }
  }
}

export default CrashOverrideServerlessPlugin;
