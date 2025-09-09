import type Serverless from "serverless";
import type Plugin from "serverless/classes/Plugin";
import { execSync } from "child_process";
import * as path from "path";
import * as fs from "fs";
import chalk from "chalk"; // chalk the JS lib. Not chalk to CO project.
import type { CustomServerlessConfig, CrashOverrideConfig } from "./types";

class CrashOverrideServerlessPlugin implements Plugin {
    public serverless: Serverless;
    public options: Serverless.Options;
    public hooks: Plugin.Hooks;
    public provider: any;
    private log: any;
    private isChalkAvailable: boolean = false;
    private readonly config: Readonly<CrashOverrideConfig>;

    constructor(
        serverless: Serverless,
        options: Serverless.Options = {},
        { log }: { log: any },
    ) {
        this.provider = serverless.getProvider("aws");
        this.serverless = serverless;
        this.options = options;
        this.log = log;

        // Initialize config with the following precedence:
        //   1. serverless.yml custom.crashoverride values
        //   2. Environment variables
        //   3. Default values
        this.config = this.initializeConfig();

        this.hooks = {
            "before:package:initialize":
                this.beforePackageInitialize.bind(this),
            "after:aws:package:finalize:mergeCustomProviderResources":
                this.afterPackageInitialize.bind(this),
        };
    }

    // Helper logging methods
    private log_error(message: string): void {
        this.log.error(chalk.red(`${message}`));
    }

    private log_warning(message: string): void {
        this.log.warning(chalk.yellow(`${message}`));
    }

    private log_notice(message: string): void {
        this.log.notice(chalk.cyan(`${message}`));
    }

    private log_success(message: string): void {
        this.log.success(chalk.green(`${message}`));
    }

    private log_info(message: string): void {
        this.log.info(chalk.gray(`${message}`));
    }

    private initializeConfig(): Readonly<CrashOverrideConfig> {
        // Default values (lowest precedence)
        const defaults: CrashOverrideConfig = {
            memoryCheck: false,
            memoryCheckSize: 256,
            chalkCheck: false,
        };

        // Environment variables (medium precedence)
        const envConfig: Partial<CrashOverrideConfig> = {};
        if (process.env["CO_MEMORY_CHECK"] !== undefined) {
            envConfig.memoryCheck =
                process.env["CO_MEMORY_CHECK"].toLowerCase() === "true";
        }
        if (process.env["CO_CHALK_CHECK_ENABLED"] !== undefined) {
            envConfig.chalkCheck =
                process.env["CO_CHALK_CHECK_ENABLED"].toLowerCase() === "true";
        }

        // Serverless config (highest precedence)
        const customConfig = this.serverless.service.custom as
            | CustomServerlessConfig
            | undefined;
        const serverlessConfig: Partial<CrashOverrideConfig> =
            customConfig?.crashoverride || {};

        // Merge with precedence: defaults < env < serverless
        const finalConfig: CrashOverrideConfig = {
            ...defaults,
            ...envConfig,
            ...serverlessConfig,
        };

        // Log the final configuration
        this.log_info(
            `CrashOverride config initialized:\n\tmemoryCheck=${finalConfig.memoryCheck}\n\tmemoryCheckSize=${finalConfig.memoryCheckSize}\n\tchalkCheck=${finalConfig.chalkCheck}`,
        );

        return Object.freeze(finalConfig);
    }

    private checkMemoryConfiguration(): void {
        // Access memorySize from the provider object (it's a custom property added by serverless.yml)
        const memorySize = (this.serverless.service.provider as any)
            ?.memorySize;

        // If memory size is not configured, warn and return
        if (!memorySize) {
            if (this.config.memoryCheck) {
                this.log_warning(
                    `Memory check enabled but no memorySize configured in provider`,
                );
            }
            return;
        }

        // Check if memory size is below minimum
        if (memorySize < this.config.memoryCheckSize) {
            if (this.config.memoryCheck) {
                // When memoryCheck is true, fail the build
                const errorMessage = `Memory check failed: memorySize (${memorySize}MB) is less than minimum required (512MB)`;
                this.log_error(errorMessage);
                throw new this.serverless.classes.Error(errorMessage);
            } else {
                // When memoryCheck is false, just warn
                this.log_warning(
                    `Memory size (${memorySize}MB) is below recommended minimum (${this.config.memoryCheckSize}). Set custom.crashoverride.memoryCheck: true to enforce this requirement`,
                );
            }
        } else if (this.config.memoryCheck) {
            // Only log success when check is enabled and passes
            this.log_info(
                `Memory check passed: ${memorySize}MB >= ${this.config.memoryCheckSize}MB`,
            );
        }
    }

    private chalkBinaryAvailable(): boolean {
        this.log_info(`Checking for chalk binary...`);

        try {
            execSync("command -v chalk", { stdio: "ignore" });
            this.log_success(`Chalk binary found`);
            return true;
        } catch {
            if (this.config.chalkCheck) {
                const errorMessage = `Chalk check failed: chalk binary not found in PATH`;
                this.log_error(errorMessage);
                throw new this.serverless.classes.Error(errorMessage);
            } else {
                this.log_info(`Chalk binary not found in PATH`);
                return false;
            }
        }
    }

    private beforePackageInitialize(): void {
        this.log_notice(`Dust Plugin: Initializing package process`);

        // Check memory configuration first (fail fast if needed)
        this.checkMemoryConfiguration();

        // Check chalk availability once and store the result
        this.isChalkAvailable = this.chalkBinaryAvailable();

        if (this.isChalkAvailable) {
            this.log_info(
                `Chalk binary found and will be used to add chalkmarks`,
            );
        } else {
            this.log_warning(
                `Chalk binary not available. Continuing without chalkmarks`,
            );
        }
    }

    private getPackageZipPath(): string | null {
        const servicePath = this.serverless.config.servicePath || process.cwd();
        const serviceName = this.serverless.service.service;

        // Default Serverless packaging location
        const zipPath = path.join(
            servicePath,
            ".serverless",
            `${serviceName}.zip`,
        );

        if (fs.existsSync(zipPath)) {
            return zipPath;
        }

        this.log_warning(
            `Package zip file not found at ${chalk.gray(zipPath)}`,
        );
        return null;
    }

    private injectChalkBinary(): void {
        if (!this.isChalkAvailable) {
            this.log_warning(
                `Chalk binary not available, skipping chalkmark injection`,
            );
            return;
        }

        const zipPath = this.getPackageZipPath();
        if (!zipPath) {
            this.log_error(`Could not locate package zip file`);
            return;
        }

        try {
            this.log_info(`Injecting chalkmarks into ${chalk.gray(zipPath)}`);
            execSync(`chalk insert --inject-binary-into-zip "${zipPath}"`, {
                stdio: "pipe",
                encoding: "utf8",
            });
            this.log_success(`Successfully injected chalkmarks into package`);
        } catch (error: any) {
            this.log_error(
                `Failed to inject chalkmarks: ${chalk.bold(error.message)}`,
            );
        }
    }

    private addDustLambdaExtension(): void {
        const extensionArn =
            "arn:aws:lambda:us-east-1:123456789012:layer:my-extension";
        const functions = this.serverless.service.functions || {};
        const MAX_LAYERS_AND_EXTENSIONS = 15; // AWS Lambda limit: 5 layers + 10 extensions

        this.log_notice(`Adding Dust Lambda Extension to all functions`);

        // Validate all functions first before modifying any
        Object.keys(functions).forEach((functionName) => {
            const func = functions[functionName] as any;
            if (!func) return;

            const currentLayers = func.layers || [];

            if (currentLayers.length >= MAX_LAYERS_AND_EXTENSIONS) {
                const error = `Cannot add Dust Lambda Extension to function ${chalk.bold(functionName)}: would exceed maximum layer/extension limit of ${MAX_LAYERS_AND_EXTENSIONS} (currently has ${currentLayers.length})`;
                this.log_error(error);
                throw new this.serverless.classes.Error(error);
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
            this.log_info(
                `Added Dust Lambda Extension to function: ${chalk.bold(functionName)} (${chalk.gray(`${func.layers.length}/${MAX_LAYERS_AND_EXTENSIONS} layers/extensions`)})`,
            );
        });

        const functionCount = Object.keys(functions).length;
        if (functionCount > 0) {
            this.log_success(
                `Successfully added Dust Lambda Extension to ${chalk.bold(functionCount)} function(s)`,
            );
        } else {
            this.log_warning(
                `No functions found in service - no extensions added`,
            );
        }
    }

    private afterPackageInitialize(): void {
        this.log_notice(`Dust Plugin: Processing packaged functions`);
        this.addDustLambdaExtension();
        this.injectChalkBinary();
    }
}

export default CrashOverrideServerlessPlugin;
