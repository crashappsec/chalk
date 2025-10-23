export class AlreadyHasExtensionError extends Error {}

export function getErrorMessage(e: unknown): string {
  if (e instanceof Error) {
    return e.message;
  } else {
    return String(e);
  }
}
