import type Serverless from "serverless";
import type Plugin from "serverless/classes/Plugin";
import { execSync } from "child_process";
import * as path from "path";
import * as fs from "fs";
import chalk from "chalk"; // chalk the JS lib. Not chalk to CO project.
import type { CustomServerlessConfig } from "./types";

class ServerlessPlugin implements Plugin {
  public serverless: Serverless;
  public options: Serverless.Options;
  public hooks: Plugin.Hooks;
  public provider: any;
  private log: any;
  private isChalkAvailable: boolean = false;

  private readonly symbols = {
    error: "✗",
    info: "ℹ",
    package: "📦",
    process: "🔧",
    rocket: "🚀",
    success: "✓",
    warning: "⚠",
  } as const;

  constructor(
    serverless: Serverless,
    options: Serverless.Options = {},
    { log }: { log: any },
  ) {
    this.provider = serverless.getProvider("aws");
    this.serverless = serverless;
    this.options = options;
    this.log = log;

    this.hooks = {
      "before:package:initialize": this.beforePackageInitialize.bind(this),
      "after:aws:package:finalize:mergeCustomProviderResources":
        this.afterPackageInitialize.bind(this),
    };
  }

  private checkMemoryConfiguration(): void {
    const customConfig = this.serverless.service.custom as
      | CustomServerlessConfig
      | undefined;
    const memoryCheckEnabled =
      customConfig?.crashoverride?.memoryCheck ?? false;
    // Access memorySize from the provider object (it's a custom property added by serverless.yml)
    const memorySize = (this.serverless.service.provider as any)?.memorySize;

    // If memory size is not configured, warn and return
    if (!memorySize) {
      if (memoryCheckEnabled) {
        this.log.warning(
          chalk.yellow(
            `${this.symbols.warning} Memory check enabled but no memorySize configured in provider`,
          ),
        );
      }
      return;
    }

    // Check if memory size is below minimum
    if (memorySize < 512) {
      if (memoryCheckEnabled) {
        // When memoryCheck is true, fail the build
        const errorMessage = `Memory check failed: memorySize (${memorySize}MB) is less than minimum required (512MB)`;
        this.log.error(chalk.red(`${this.symbols.error} ${errorMessage}`));
        throw new Error(errorMessage);
      } else {
        // When memoryCheck is false (or not set), just warn
        this.log.warning(
          chalk.yellow(
            `${this.symbols.warning} Memory size (${memorySize}MB) is below recommended minimum (512MB). Set custom.crashoverride.memoryCheck: true to enforce this requirement`,
          ),
        );
      }
    } else if (memoryCheckEnabled) {
      // Only log success when check is enabled and passes
      this.log.info(
        chalk.green(
          `${this.symbols.success} Memory check passed: ${memorySize}MB >= 512MB`,
        ),
      );
    }
  }

  private chalkBinaryAvailable(): boolean {
    const customConfig = this.serverless.service.custom as
      | CustomServerlessConfig
      | undefined;
    const chalkCheckEnabled = customConfig?.crashoverride?.chalkCheck ?? false;

    this.log.info(
      chalk.gray(`${this.symbols.info} Checking for chalk binary...`),
    );

    try {
      execSync("command -v chalk", { stdio: "ignore" });
      this.log.info(chalk.green(`${this.symbols.success} Chalk binary found`));
      return true;
    } catch {
      if (chalkCheckEnabled) {
        const errorMessage = `Chalk check failed: chalk binary not found in PATH`;
        this.log.error(chalk.red(`${this.symbols.error} ${errorMessage}`));
        throw new Error(errorMessage);
      } else {
        this.log.info(
          chalk.gray(`${this.symbols.info} Chalk binary not found in PATH`),
        );
        return false;
      }
    }
  }

  private beforePackageInitialize(): void {
    this.log.notice(
      chalk.cyan(
        `${this.symbols.process} Dust Plugin: Initializing package process`,
      ),
    );

    // Check memory configuration first (fail fast if needed)
    this.checkMemoryConfiguration();

    // Check chalk availability once and store the result
    this.isChalkAvailable = this.chalkBinaryAvailable();

    if (this.isChalkAvailable) {
      this.log.info(
        chalk.gray(
          `${this.symbols.info} Chalk binary found and will be used to add chalkmarks`,
        ),
      );
    } else {
      this.log.warning(
        chalk.yellow(
          `${this.symbols.warning} Chalk binary not available. Continuing without chalkmarks`,
        ),
      );
    }
  }

  private getPackageZipPath(): string | null {
    const servicePath = this.serverless.config.servicePath || process.cwd();
    const serviceName = this.serverless.service.service;

    // Default Serverless packaging location
    const zipPath = path.join(servicePath, ".serverless", `${serviceName}.zip`);

    if (fs.existsSync(zipPath)) {
      return zipPath;
    }

    this.log.warning(
      chalk.yellow(
        `${this.symbols.warning} Package zip file not found at ${chalk.gray(zipPath)}`,
      ),
    );
    return null;
  }

  private injectChalkBinary(): void {
    if (!this.isChalkAvailable) {
      this.log.info(
        chalk.yellow(
          `${this.symbols.warning} Chalk binary not available, skipping chalkmark injection`,
        ),
      );
      return;
    }

    const zipPath = this.getPackageZipPath();
    if (!zipPath) {
      this.log.error(
        chalk.red(`${this.symbols.error} Could not locate package zip file`),
      );
      return;
    }

    try {
      this.log.info(
        chalk.gray(
          `${this.symbols.info} Injecting chalkmarks into ${chalk.gray(zipPath)}`,
        ),
      );
      execSync(`chalk insert --inject-binary-into-zip "${zipPath}"`, {
        stdio: "pipe",
        encoding: "utf8",
      });
      this.log.notice(
        chalk.green(
          `${this.symbols.success} Successfully injected chalkmarks into package`,
        ),
      );
    } catch (error: any) {
      this.log.error(
        chalk.red(
          `${this.symbols.error} Failed to inject chalkmarks: ${chalk.bold(error.message)}`,
        ),
      );
    }
  }

  private addDustLambdaExtension(): void {
    const extensionArn =
      "arn:aws:lambda:us-east-1:123456789012:layer:my-extension";
    const functions = this.serverless.service.functions || {};
    const MAX_LAYERS_AND_EXTENSIONS = 15; // AWS Lambda limit: 5 layers + 10 extensions

    this.log.notice(
      chalk.cyan(
        `${this.symbols.rocket} Adding Dust Lambda Extension to all functions`,
      ),
    );

    // Validate all functions first before modifying any
    Object.keys(functions).forEach((functionName) => {
      const func = functions[functionName] as any;
      if (!func) return;

      const currentLayers = func.layers || [];

      if (currentLayers.length >= MAX_LAYERS_AND_EXTENSIONS) {
        const error = `Cannot add Dust Lambda Extension to function ${chalk.bold(functionName)}: would exceed maximum layer/extension limit of ${MAX_LAYERS_AND_EXTENSIONS} (currently has ${currentLayers.length})`;
        this.log.error(chalk.red(`${this.symbols.error} ${error}`));
        throw new Error(error);
      }
    });

    // Add extension to all functions
    Object.keys(functions).forEach((functionName) => {
      const func = functions[functionName] as any;
      if (!func) return;

      if (!func.layers) {
        func.layers = [];
      }
      func.layers.push(extensionArn);
      this.log.info(
        chalk.gray(
          `${this.symbols.info} Added Dust Lambda Extension to function: ${chalk.bold(functionName)} (${chalk.gray(`${func.layers.length}/${MAX_LAYERS_AND_EXTENSIONS} layers/extensions`)})`,
        ),
      );
    });

    const functionCount = Object.keys(functions).length;
    if (functionCount > 0) {
      this.log.notice(
        chalk.green(
          `${this.symbols.success} Successfully added Dust Lambda Extension to ${chalk.bold(functionCount)} function(s)`,
        ),
      );
    } else {
      this.log.warning(
        chalk.yellow(
          `${this.symbols.warning} No functions found in service - no extensions added`,
        ),
      );
    }
  }

  private afterPackageInitialize(): void {
    this.log.notice(
      chalk.cyan(
        `${this.symbols.package} Dust Plugin: Processing packaged functions`,
      ),
    );
    this.addDustLambdaExtension();
    this.injectChalkBinary();
  }
}

export default ServerlessPlugin;
