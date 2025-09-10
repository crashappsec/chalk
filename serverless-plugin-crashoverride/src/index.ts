import type Serverless from "serverless";
import type Plugin from "serverless/classes/Plugin";
import type Aws from "serverless/plugins/aws/provider/awsProvider";
import type AwsProvider from "serverless/plugins/aws/provider/awsProvider";
import { execSync } from "child_process";
import * as path from "path";
import * as fs from "fs";
import * as https from "https";
import chalk from "chalk"; // chalk the JS lib. Not chalk to CO project.
import type {
    CustomServerlessConfig,
    CrashOverrideConfig,
    ProviderConfig,
} from "./types";

class CrashOverrideServerlessPlugin implements Plugin {
    serverless: Serverless;
    options: Serverless.Options;
    hooks: Plugin.Hooks;
    provider: AwsProvider;
    readonly config: Readonly<CrashOverrideConfig>;
    private log: any;
    private isChalkAvailable: boolean = false;
    private providerConfig: ProviderConfig | null = null;

    constructor(
        serverless: Serverless,
        options: Serverless.Options = {},
        { log }: { log: any },
    ) {
        this.serverless = serverless;
        this.options = options;
        this.log = log;
        this.provider = serverless.getProvider("aws")

        // Initialize config with the following precedence:
        //   1. serverless.yml custom.crashoverride values
        //   2. Environment variables
        //   3. Default values
        this.config = this.initializeConfig();

        this.hooks = {
            "after:package:setupProviderConfiguration":
                this.fetchProviderConfig.bind(this),
            "after:package:createDeploymentArtifacts":
                this.preFlightChecks.bind(this),
            "before:package:compileFunctions":
                this.mutateServerlessService.bind(this),
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
            arnUrlPrefix: "https://dl.crashoverride.run/dust"
        };

        // Environment variables (medium precedence)
        const envConfig: Partial<CrashOverrideConfig> = {};
        if (process.env["CO_MEMORY_CHECK"] !== undefined) {
            envConfig.memoryCheck =
                process.env["CO_MEMORY_CHECK"].toLowerCase() === "true";
        }
        if (process.env["CO_MEMORY_CHECK_SIZE_MB"] !== undefined) {
            const memorySize: number = (envConfig.memoryCheckSize =
                Number.parseInt(process.env["CO_MEMORY_CHECK_SIZE_MB"]));
            if (Number.isSafeInteger(memorySize)) {
                envConfig.memoryCheckSize = memorySize;
            } else {
                throw new this.serverless.classes.Error(
                    `Received invalid memoryCheckSize value of: ${memorySize}`,
                );
            }
        }
        if (process.env["CO_CHALK_CHECK_ENABLED"] !== undefined) {
            envConfig.chalkCheck =
                process.env["CO_CHALK_CHECK_ENABLED"].toLowerCase() === "true";
        }
        if (process.env["CO_ARN_URL_PREFIX"] !== undefined) {
            envConfig.arnUrlPrefix = process.env["CO_ARN_URL_PREFIX"];
        }

        // Serverless config (highest precedence)
        const customConfig: CustomServerlessConfig | undefined = this.serverless.service.custom
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

    private fetchProviderConfig(): void {
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
            memorySize = typeof provider.memorySize === 'string'
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
            `Provider config: provider=${this.providerConfig.provider}, region=${this.providerConfig.region}, memorySize=${this.providerConfig.memorySize}`,
        );
    }

    private async fetchDustExtensionArn(region: string): Promise<string> {
        const urlPrefix = this.config.arnUrlPrefix
        return new Promise((resolve, reject) => {
            const url = `${urlPrefix}/${region}/extension.arn`;

            https.get(url, (res) => {
                let data = "";

                if (res.statusCode !== 200) {
                    this.log_warning(`Failed to fetch Dust extension ARN for region ${region}: HTTP ${res.statusCode}`);
                    reject(new Error(`HTTP ${res.statusCode}`));
                    return;
                }

                res.on("data", (chunk) => {
                    data += chunk;
                });

                res.on("end", () => {
                    const arn = data.trim();
                    resolve(arn);
                });
            }).on("error", (error) => {
                this.log_warning(`Failed to fetch Dust extension ARN for region ${region}: ${error.message}`);
                reject(error);
            });
        });
    }

    private checkMemoryConfiguration(): void {
        // Ensure provider configuration has been fetched
        if (!this.providerConfig) {
            throw new this.serverless.classes.Error(
                "Provider configuration not initialized",
            );
        }

        const providerMemorySize = this.providerConfig.memorySize;

        // Check if memory size is below minimum
        if (providerMemorySize < this.config.memoryCheckSize) {
            if (this.config.memoryCheck) {
                // When memoryCheck is true, fail the build
                const errorMessage = `Memory check failed: memorySize (${providerMemorySize}MB) is less than minimum required (${this.config.memoryCheckSize}MB)`;
                this.log_error(errorMessage);
                throw new this.serverless.classes.Error(errorMessage);
            } else {
                // When memoryCheck is false, just warn
                this.log_warning(
                    `Memory size (${providerMemorySize}MB) is below recommended minimum (${this.config.memoryCheckSize}). Set custom.crashoverride.memoryCheck: true to enforce this requirement`,
                );
            }
        } else if (this.config.memoryCheck) {
            // log success when check is enabled and passes
            this.log_info(
                `Memory check passed: ${providerMemorySize}MB >= ${this.config.memoryCheckSize}MB`,
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

    private preFlightChecks(): void {
        this.log_notice(`Dust Plugin: Initializing package process`);

        // Only check memory configuration if provider config was successfully fetched
        if (this.providerConfig) {
            // Check memory configuration (fail fast if needed)
            this.checkMemoryConfiguration();
        }

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

    private async addDustLambdaExtension(): Promise<void> {
        if (this.providerConfig === null) {
            const errorMessage = `Cannot ascertain service's region from Provider configuration`
            this.log_error(errorMessage)
            throw new Error(errorMessage);
        }

        const extensionArn = await this.fetchDustExtensionArn(this.providerConfig.region)
        this.log_info(`Dust Extension ARN for ${this.providerConfig.region} :: ${extensionArn}`)
        const MAX_LAYERS_AND_EXTENSIONS = 15; // AWS Lambda limit: 5 layers + 10 extensions

        this.log_notice(`Adding Dust Lambda Extension to all functions`);

        const functions = this.serverless.service.functions || {};
        // Validate all functions first before modifying any
        for (const [functionName, func] of Object.entries(functions)) {
            if (!func) return;

            const awsFunc = func as Aws.AwsFunction;
            const currentLayers = awsFunc.layers || [];

            if (currentLayers.length >= MAX_LAYERS_AND_EXTENSIONS) {
                const error = `Cannot add Dust Lambda Extension to function ${chalk.bold(functionName)}: would exceed maximum layer/extension limit of ${MAX_LAYERS_AND_EXTENSIONS} (currently has ${currentLayers.length})`;
                this.log_error(error);
                throw new this.serverless.classes.Error(error);
            }
        };

        // Add extension to all functions
        for (const [functionName, func] of Object.entries(functions)) {
            if (!func) return;

            const awsFunc = func as Aws.AwsFunction;

            if (!awsFunc.layers) {
                awsFunc.layers = [];
            }
            awsFunc.layers = [...(awsFunc.layers ?? []), extensionArn];
            this.log_info(
                `Added Dust Lambda Extension to function: ${chalk.bold(functionName)} (${chalk.gray(`${awsFunc.layers.length}/${MAX_LAYERS_AND_EXTENSIONS} layers/extensions`)})`,
            );
        };

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

    private async mutateServerlessService(): Promise<void> {
        this.log_notice(`Dust Plugin: Processing packaged functions`);
        await this.addDustLambdaExtension();
        this.injectChalkBinary();
    }
}

export default CrashOverrideServerlessPlugin;
