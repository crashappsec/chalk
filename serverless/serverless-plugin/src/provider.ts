import { fetchDustExtensionArn } from "./helpers";
import type { CrashOverrideConfig, ErrorFunc, ProviderConfig } from "./types";
import { binExists } from "./utils/os";
import * as fs from "fs";
import * as path from "path";
import type Serverless from "serverless";
import type AwsProvider from "serverless/plugins/aws/provider/awsProvider";

export async function getProvider(
  config: CrashOverrideConfig,
  provider: AwsProvider.Provider,
  options: Serverless.Options,
  serverless: {
    servicePath?: string;
    packagePath?: string;
    serviceName?: string | null;
  },
  error?: ErrorFunc,
): Promise<ProviderConfig> {
  if (!serverless?.serviceName) {
    throw new (error ?? Error)(
      "No service name is provided which is required to locate serverless zip path",
    );
  }
  const zipPath = path.resolve(
    serverless?.servicePath || process.cwd(), //
    serverless?.packagePath || ".serverless",
    `${serverless.serviceName}.zip`,
  );
  if (!fs.existsSync(zipPath)) {
    throw new (error ?? Error)(`Could not locate ${zipPath}`);
  }
  // serverless defaults to us-east-1 regardless of aws profile
  // https://github.com/serverless/serverless/issues/2151
  const region = options.region ?? provider.region ?? "us-east-1";
  return {
    region,
    // Parse memorySize to ensure it's a number
    // serverless defaults to 1024 as default memory size
    // https://github.com/serverless/serverless/blob/3110342154b96b7b6ef674d2b1fa548a53fb82d4/lib/plugins/aws/package/compile/functions.js#L211-L213
    memorySize: parseInt(String(provider.memorySize ?? "1024")),
    dustExtensionArn: await fetchDustExtensionArn(
      config.arnUrlPrefix,
      region,
      config.arnVersion,
      error,
    ),
    isChalkAvailable: binExists(config.chalkPath),
    zipPath,
  };
}
