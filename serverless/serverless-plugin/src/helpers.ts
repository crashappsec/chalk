import { AwsServiceFunction, CrashOverrideConfig, ErrorFunc } from "./types";
import { AlreadyHasExtensionError, getErrorMessage } from "./utils/errors";
import { runCommand } from "./utils/os";
import { getVersionlessArn } from "./utils/strings";

export const ARN_PATTERN =
  /^arn:aws:lambda:(?<region>[\w\d-]+):(?<account>\d+):layer:(?<name>[\w\d-]+)(:(?<version>\d+))?$/;

export async function fetchDustExtensionArn(
  urlPrefix: string,
  region: string,
  arnVersion?: string,
  error?: ErrorFunc,
): Promise<string> {
  try {
    const response = await fetch(`${urlPrefix}/${region}/extension.arn`);

    if (!response.ok) {
      throw new Error(
        `Failed to fetch Dust extension ARN for AWS region ${region}: HTTP ${response.status}`,
      );
    }

    const data = await response.text();
    const latestVersionedArn = data.trim();

    if (!arnVersion || arnVersion === "latest") {
      return latestVersionedArn;
    } else {
      return `${getVersionlessArn(latestVersionedArn)}:${arnVersion}`;
    }
  } catch (e) {
    throw new (error ?? Error)(
      `Failed to fetch Dust extension ARN for AWS region ${region}: HTTP ${getErrorMessage(e)}`,
    );
  }
}

export function validateFunction(
  config: CrashOverrideConfig, //
  name: string,
  func: AwsServiceFunction,
  error?: ErrorFunc,
) {
  if ((func.layers?.length ?? 0) >= config.awsMaxLayers) {
    throw new (error ?? Error)(
      `Function (${name}) has ${func.layers?.length} layers/extensions (max: ${config.awsMaxLayers})`,
    );
  }
}

export function addDustLambdaExtension(
  extensionArn: string, //
  name: string,
  func: AwsServiceFunction,
): AwsServiceFunction {
  const extensionArnBase = getVersionlessArn(extensionArn);
  const alreadyHasExtension = func.layers?.some(
    (layer) => getVersionlessArn(layer) === extensionArnBase,
  );
  if (alreadyHasExtension) {
    throw new AlreadyHasExtensionError(
      `Skipped function ${name}: Dust Lambda Extension already present`,
    );
  } else {
    func.layers = [...(func.layers ?? []), extensionArn];
  }
  return func;
}

export function injectChalkBinary(chalkPath: string, zipPath: string, error?: ErrorFunc): string {
  const cmd = `${chalkPath} insert --inject-binary-into-zip ${zipPath}`;
  return runCommand(cmd, error);
}
