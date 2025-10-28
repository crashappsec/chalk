import { parseEnvConfig, getConfig, CONFIG_DEFAULTS, SUPPORTED_PLATFORMS } from "./config";
import { addDustLambdaExtension, injectChalkBinary, validateFunction } from "./helpers";
import { getProvider } from "./provider";
import type {
  CustomServerlessConfig,
  CrashOverrideConfig,
  ProviderConfig,
  AwsServiceFunctions,
  ErrorFunc,
} from "./types";
import { AlreadyHasExtensionError, getErrorMessage } from "./utils/errors";
import chalk from "chalk";
import type Serverless from "serverless";
import type Plugin from "serverless/classes/Plugin";
import { Logging } from "serverless/classes/Plugin";
import type AwsProvider from "serverless/plugins/aws/provider/awsProvider";

export default class CrashOverrideServerlessPlugin implements Plugin {
  hooks: Plugin.Hooks;
  readonly provider: AwsProvider;
  readonly config: Readonly<CrashOverrideConfig>;
  private error: ErrorFunc;

  constructor(
    readonly serverless: Serverless,
    readonly options: Serverless.Options = {},
    private readonly utils: Plugin.Logging,
  ) {
    this.error = serverless.classes.Error;
    this.provider = serverless.getProvider("aws");

    // Check if running on supported UNIX-like platform and short-circuit if not
    if (!SUPPORTED_PLATFORMS.includes(process.platform)) {
      this.log(
        "warning",
        `plugin is not supported on ${process.platform}.`,
        `Only UNIX-like platforms (${SUPPORTED_PLATFORMS.join(", ")}) are supported.`,
        `Skipping plugin initialization.`,
      );
      this.hooks = {}; // do not register any hooks
      this.config = CONFIG_DEFAULTS;
      return;
    }

    this.config = this.initializeConfig();
    this.hooks = {
      "before:package:compileFunctions": this.handleCompileFunctions.bind(this),
    };
  }

  private log(
    level: keyof Logging["log"], //
    message: string,
    ...args: string[]
  ) {
    const colors: Record<keyof Logging["log"], typeof chalk.red> = {
      debug: chalk.dim,
      verbose: chalk.dim,
      notice: chalk.cyan,
      info: chalk.gray,
      success: chalk.green,
      warning: chalk.yellow,
      error: chalk.red,
    };
    const lines = [
      `CrashOverride dust extension: ${message}`, //
      ...args,
    ];
    this.utils.log[level](colors[level](lines.join("\n")));
  }

  private initializeConfig(): Readonly<CrashOverrideConfig> {
    const customConfig: CustomServerlessConfig = this.serverless.service.custom;
    const finalConfig = getConfig(
      parseEnvConfig(this.error), //
      customConfig?.crashoverride,
    );
    this.log("info", `config initialized:`, JSON.stringify(finalConfig));
    return finalConfig;
  }

  private async getProviderConfig(): Promise<ProviderConfig> {
    // Verify provider configuration is available
    const provider = this.serverless.service.provider as AwsProvider.Provider;
    if (!provider) {
      throw new this.error("No provider configuration found in serverless.yml");
    }

    const providerConfig = await getProvider(
      this.config,
      provider,
      this.options,
      {
        servicePath: this.serverless.config.servicePath,
        packagePath: this.serverless.service.package?.["path"],
        serviceName: this.serverless.service.service,
      },
      this.error,
    );
    this.log("info", "provider config:", JSON.stringify(providerConfig));
    return providerConfig;
  }

  private enforceCheck(
    predicate: boolean,
    check: boolean,
    msg: {
      checking: string;
      error: string;
      warn: string;
      info?: string;
      success?: string;
    },
  ) {
    if (check) {
      this.log("info", `${msg.checking}...`);
    } else {
      this.log("info", `skipping ${msg.checking}`);
    }
    if (predicate) {
      if (check) {
        if (msg.success) {
          this.log("success", msg.success);
        } else if (msg.info) {
          this.log("info", msg.info);
        }
      }
    } else {
      if (check) {
        this.log("error", msg.error);
        throw new this.error(msg.error);
      } else {
        this.log("warning", msg.warn);
      }
    }
  }

  private async handleCompileFunctions(): Promise<void> {
    this.log("notice", `processing packaged functions`);

    const providerConfig = await this.getProviderConfig();

    this.enforceCheck(
      providerConfig.memorySize >= this.config.memoryCheckSize,
      this.config.memoryCheck, //
      {
        checking: "checking provider memory size",
        error: `memory check failed: memorySize (${providerConfig.memorySize}MB) is less than minimum required (${this.config.memoryCheckSize}MB)`,
        warn: `memory size (${providerConfig.memorySize}MB) is below recommended minimum (${this.config.memoryCheckSize}). Set custom.crashoverride.memoryCheck: true to enforce this requirement`,
        info: `memory check passed: ${providerConfig.memorySize}MB >= ${this.config.memoryCheckSize}MB`,
      },
    );
    this.enforceCheck(
      providerConfig.isChalkAvailable,
      this.config.chalkCheck, //
      {
        checking: "checking for chalk binary",
        error: `chalk check failed: chalk binary (${this.config.chalkPath}) not found in PATH. Please add and try again.`,
        warn: `chalk binary (${this.config.chalkPath}) not found in PATH. Continuing without chalkmarks`,
        success: "chalk binary found and will be used to add chalkmarks",
      },
    );

    // Get functions from service (cast to RuntimeAwsFunction for AWS-specific properties)
    const functions: AwsServiceFunctions = this.serverless.service.functions ?? {};
    const functionCount = Object.keys(functions).length;

    // Handle Dust Lambda Extension
    if (functionCount === 0) {
      this.log("warning", `no functions found in service - no extensions added`);
      return;
    }

    this.log("info", `validating ${functionCount} functions compatibility`);
    for (const [name, func] of Object.entries(functions)) {
      validateFunction(this.config, name, func, this.error);
    }

    let added = 0;
    let skipped = 0;
    this.log("notice", `adding ${providerConfig.dustExtensionArn} to all functions`);
    for (const [name, func] of Object.entries(functions)) {
      try {
        addDustLambdaExtension(providerConfig.dustExtensionArn, name, func);
        this.log(
          "info",
          `added ${providerConfig.dustExtensionArn} extension to function: ${chalk.bold(name)} (${chalk.gray(
            `${func.layers!.length}/${this.config.awsMaxLayers} layers/extensions`,
          )})`,
        );
        added++;
      } catch (e: unknown) {
        if (e instanceof AlreadyHasExtensionError) {
          this.log("info", getErrorMessage(e));
          skipped++;
        } else {
          throw e;
        }
      }
    }
    if (added) {
      this.log(
        "success",
        `successfully added Dust Lambda Extension to ${chalk.bold(added)} function(s)`,
      );
    }
    if (skipped) {
      this.log(
        "success",
        `skipped adding Dust Lambda Extension to ${chalk.bold(skipped)} function(s) as extension is already present`,
      );
    }

    if (!providerConfig.isChalkAvailable) {
      this.log("warning", `chalk binary not available, skipping chalkmark injection`);
      return;
    }

    this.log("info", `injecting chalkmarks into ${chalk.gray(providerConfig.zipPath)}`);
    injectChalkBinary(this.config.chalkPath, providerConfig.zipPath, this.error);
    this.log("success", `successfully injected chalkmarks into package`);
  }
}
