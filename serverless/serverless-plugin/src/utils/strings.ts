export function rsplit(data: string, delimiter: string, maxsplit: number): string[] {
  const parts = data.split(delimiter);
  const left = parts.slice(0, -maxsplit);
  const right = parts.slice(-maxsplit);
  return [left.join(delimiter), ...right];
}

export function getVersionlessArn(versionedArn: string): string {
  // ARN format: arn:aws:lambda:region:account:layer:name:version
  // Remove the version (last part) to compare ARNs
  return rsplit(versionedArn, ":", 1)[0]!;
}
