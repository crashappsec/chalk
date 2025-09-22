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
    FunctionValidationResult,
    CloudFormationTemplate,
} from "./types";

class CrashOverrideServerlessPlugin implements Plugin {
    hooks: Plugin.Hooks;
    readonly config: Readonly<CrashOverrideConfig>;
    private readonly log: Plugin.Logging["log"];
    private isChalkAvailable: boolean = false;
    private providerConfig: ProviderConfig | null = null;
    private dustExtensionArn: string | null = null;
    public readonly provider: AwsProvider;

    constructor(
        public readonly serverless: Serverless,
        public readonly options: Serverless.Options = {},
        { log }: Plugin.Logging,
    ) {
        this.log = log;
        this.provider = serverless.getProvider("aws")

        // Check if running on Windows and short-circuit if so
        if (process.platform === "win32") {
            this.log.warning(
                chalk.yellow(
                    "Crash Override plugin is not supported on Windows. Skipping plugin initialization."
            ));
            this.hooks = {}; // do not register any hooks
            this.config = { memoryCheck: false, memoryCheckSize: 256, chalkCheck: false, layerCheck: false };
            return;
        }


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
            "after:package:finalize":
                this.validatePackaging.bind(this),
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
            layerCheck: false,
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
        if (process.env["CO_LAYER_CHECK"] !== undefined) {
            envConfig.layerCheck = process.env["CO_LAYER_CHECK"].toLowerCase() === "true";
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

    private checkMemoryConfiguration(): boolean {
        // Ensure provider configuration has been fetched
        if (!this.providerConfig) {
            throw new this.serverless.classes.Error(
                "Provider configuration not initialized",
            );
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

    private preFlightChecks(): void {
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
                        `Memory size (${this.providerConfig.memorySize}MB) is below recommended minimum (${this.config.memoryCheckSize}). Set custom.crashoverride.memoryCheck: true to enforce this requirement`,
                    );
                }
            } else if (this.config.memoryCheck) {
                // log success when check is enabled and passes
                this.log_info(
                    `Memory check passed: ${this.providerConfig.memorySize}MB >= ${this.config.memoryCheckSize}MB`,
                );
            }
        }

        // Check chalk availability once and store the result
        this.log_info(`Checking for chalk binary...`);
        this.isChalkAvailable = this.chalkBinaryAvailable();

        if (this.isChalkAvailable) {
            this.log_success(`Chalk binary found`);
            this.log_info(
                `Chalk binary found and will be used to add chalkmarks`,
            );
        } else {
            if (this.config.chalkCheck) {
                const errorMessage = `Chalk check failed: chalk binary not found in PATH. Please add and try again.`;
                this.log_error(errorMessage);
                throw new this.serverless.classes.Error(errorMessage);
            } else {
                this.log_info(`Chalk binary not found in PATH`);
                this.log_warning(
                    `Chalk binary not available. Continuing without chalkmarks`,
                );
            }
        }
    }

    private getPackageZipPath(): string | null {
        const serviceName = this.serverless.service.service;
        // Default Serverless packaging location
        const zipPath = path.join(
            this.getServerlessPackagingLocation(),
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

    private injectChalkBinary(zipPath: string): boolean {
        try {
            execSync(`chalk insert --inject-binary-into-zip "${zipPath}"`, {
                stdio: "pipe",
                encoding: "utf8",
            });
            return true;
        } catch (error: any) {
            return false;
        }
    }

    private validateLayerCount(functions: Record<string, any>, maxLayers: number = 15): { valid: boolean; errors: string[] } {
        const errors: string[] = [];

        for (const [functionName, func] of Object.entries(functions)) {
            if (!func) continue;

            const awsFunc = func as Aws.AwsFunction;
            const currentLayers = awsFunc.layers || [];

            if (currentLayers.length >= maxLayers) {
                errors.push(`Function ${functionName} has ${currentLayers.length} layers/extensions (max: ${maxLayers})`);
            }
        }

        return {
            valid: errors.length === 0,
            errors
        };
    }

    private addDustLambdaExtension(functions: Record<string, any>, extensionArn: string): boolean {
        try {
            // Add extension to all functions
            for (const func of Object.values(functions)) {
                if (!func) continue;

                const awsFunc = func as Aws.AwsFunction;

                if (!awsFunc.layers) {
                    awsFunc.layers = [];
                }
                awsFunc.layers = [...(awsFunc.layers ?? []), extensionArn];
            }

            return true;
        } catch (error) {
            return false;
        }
    }

    private async mutateServerlessService(): Promise<void> {
        this.log_notice(`Dust Plugin: Processing packaged functions`);

        // Check provider configuration
        if (this.providerConfig === null) {
            const errorMessage = `Cannot ascertain service's region from Provider configuration`;
            this.log_error(errorMessage);
            throw new Error(errorMessage);
        }

        // Get functions from service
        const functions = this.serverless.service.functions || {};
        const functionCount = Object.keys(functions).length;

        // Handle Dust Lambda Extension
        if (functionCount === 0) {
            this.log_warning(`No functions found in service - no extensions added`);
        } else {
            // Validate layer counts before proceeding
            const MAX_LAYERS_AND_EXTENSIONS = 15;
            const validation = this.validateLayerCount(functions, MAX_LAYERS_AND_EXTENSIONS);

            if (!validation.valid) {
                const errorMessage = `Cannot add Dust Lambda Extension: ${validation.errors.join(', ')}`;
                this.log_error(errorMessage);
                throw new this.serverless.classes.Error(errorMessage);
            }

            // Fetch extension ARN
            const extensionArn = await this.fetchDustExtensionArn(this.providerConfig.region);
            this.dustExtensionArn = extensionArn; // Store for later validation
            this.log_info(`Dust Extension ARN for ${this.providerConfig.region} :: ${extensionArn}`);

            this.log_notice(`Adding Dust Lambda Extension to all functions`);

            // Add extension to functions
            const success = this.addDustLambdaExtension(functions, extensionArn);

            if (success) {
                // Log individual function updates
                for (const [functionName, func] of Object.entries(functions)) {
                    if (!func) continue;
                    const awsFunc = func as Aws.AwsFunction;
                    this.log_info(
                        `Added Dust Lambda Extension to function: ${chalk.bold(functionName)} (${chalk.gray(`${awsFunc.layers?.length || 0}/${MAX_LAYERS_AND_EXTENSIONS} layers/extensions`)})`
                    );
                }
                this.log_success(`Successfully added Dust Lambda Extension to ${chalk.bold(functionCount)} function(s)`);
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

    private parseCloudFormationTemplate(templatePath: string): CloudFormationTemplate {
        try {
            const templateContent = fs.readFileSync(templatePath, 'utf-8');
            return JSON.parse(templateContent);
        } catch (error: any) {
            if (error.code === 'ENOENT') {
                throw new Error(`CloudFormation template not found at ${templatePath}`);
            }
            if (error instanceof SyntaxError) {
                throw new Error(`Invalid JSON in CloudFormation template`);
            }
            throw new Error(`Failed to parse CloudFormation template: ${error.message}`);
        }
    }

    private validateFunctionsInTemplate(
        template: CloudFormationTemplate,
        expectedArn: string
    ): FunctionValidationResult {
        const resources = template.Resources || {};
        const functionsWithExtension: string[] = [];
        const functionsMissingExtension: string[] = [];
        let totalFunctions = 0;

        for (const [resourceName, resource] of Object.entries(resources)) {
            if (resource.Type === "AWS::Lambda::Function") {
                totalFunctions++;
                const layers = resource.Properties?.Layers || [];
                const hasExtension = layers.includes(expectedArn);

                if (hasExtension) {
                    functionsWithExtension.push(resourceName);
                } else {
                    functionsMissingExtension.push(resourceName);
                }
            }
        }

        return {
            totalFunctions,
            functionsWithExtension,
            functionsMissingExtension
        };
    }

    private buildStatusMessage(result: FunctionValidationResult): string {
        return [
            `Layer check status:`,
            `  Functions with Dust Extension (${result.functionsWithExtension.length}/${result.totalFunctions}):`,
            ...result.functionsWithExtension.map(f => `    - ${f}`),
            `  Functions MISSING Dust Extension (${result.functionsMissingExtension.length}/${result.totalFunctions}):`,
            ...result.functionsMissingExtension.map(f => `    - ${f}`)
        ].join('\n');
    }

    private getCloudFormationTemplatePath(): string {
        return path.join(
            this.getServerlessPackagingLocation(),
            "cloudformation-template-update-stack.json"
        );
    }

    private performLayerValidation(
        extensionArn: string | null,
        layerCheckEnabled: boolean
    ): { valid: boolean; error?: string; validationResult?: FunctionValidationResult; templatePath?: string } {
        // Check if extension ARN is available
        if (!extensionArn) {
            if (layerCheckEnabled) {
                return {
                    valid: false,
                    error: "Cannot perform layer check: No Dust extension ARN available"
                };
            }
            return { valid: true }; // Skip validation when not enforced
        }

        const templatePath = this.getCloudFormationTemplatePath();

        try {
            const template = this.parseCloudFormationTemplate(templatePath);
            const validationResult = this.validateFunctionsInTemplate(template, extensionArn);

            // Check if there are functions missing the extension
            if (validationResult.functionsMissingExtension.length > 0 && layerCheckEnabled) {
                return {
                    valid: false,
                    error: `Layer check failed: ${validationResult.functionsMissingExtension.length} function(s) missing Dust Lambda Extension: ${validationResult.functionsMissingExtension.join(', ')}`,
                    validationResult,
                    templatePath
                };
            }

            return {
                valid: true,
                validationResult,
                templatePath
            };
        } catch (error: any) {
            if (layerCheckEnabled) {
                // Format error message based on error type
                let errorMessage = `Layer check failed: `;
                if (error.message.includes('CloudFormation template not found')) {
                    errorMessage += error.message;
                } else if (error.message.includes('Invalid JSON')) {
                    errorMessage += error.message;
                } else {
                    errorMessage += `Failed to validate CloudFormation template: ${error.message}`;
                }
                return { valid: false, error: errorMessage };
            }
            return { valid: true }; // Skip validation on error when not enforced
        }
    }

    private validatePackaging(): void {
        const result = this.performLayerValidation(this.dustExtensionArn, this.config.layerCheck);

        // Handle validation results
        if (!result.valid && result.error) {
            this.log_error(result.error);
            throw new this.serverless.classes.Error(result.error);
        }

        // Log based on validation results
        if (!this.dustExtensionArn && !this.config.layerCheck) {
            this.log_info(`Layer check skipped: No Dust extension ARN available`);
            return;
        }

        if (result.validationResult) {
            const { validationResult } = result;

            if (validationResult.totalFunctions === 0) {
                this.log_info(`Layer check: No Lambda functions found in CloudFormation template`);
                return;
            }

            this.log_info(`Layer check: Found ${validationResult.totalFunctions} Lambda function(s) in CloudFormation template`);

            if (validationResult.functionsMissingExtension.length === 0) {
                this.log_success(
                    `Layer check passed: All ${validationResult.totalFunctions} function(s) have Dust Lambda Extension`
                );
            } else {
                const statusMessage = this.buildStatusMessage(validationResult);
                this.log_warning(statusMessage);

                if (!this.config.layerCheck) {
                    this.log_warning(
                        `${validationResult.functionsMissingExtension.length} function(s) missing Dust Lambda Extension. ` +
                        `Set custom.crashoverride.layerCheck: true to enforce this requirement`
                    );
                }
            }
        }
    }
}

export default CrashOverrideServerlessPlugin;
