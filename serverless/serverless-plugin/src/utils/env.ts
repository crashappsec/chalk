import { ErrorFunc } from "../types";

export function parseStringEnv(name: string): string | undefined {
  return process.env[name];
}

export function parseBooleanEnv(name: string): boolean | undefined {
  const val = parseStringEnv(name);
  if (val === undefined) {
    return undefined;
  }
  return val.toLowerCase() === "true";
}

export function parseIntegerEnv(name: string, error?: ErrorFunc): number | undefined {
  const val = parseStringEnv(name);
  if (val === undefined) {
    return undefined;
  }
  const parsed = Number.parseInt(val, 10);
  if (!Number.isSafeInteger(parsed)) {
    throw new (error ?? Error)(
      `Received invalid ${name} value of: ${parsed}. Must be a safe integer.`,
    );
  }
  return parsed;
}

export function parsePositiveIntegerEnv(name: string, error?: ErrorFunc): number | undefined {
  const parsed = parseIntegerEnv(name);
  if (parsed !== undefined && parsed <= 0) {
    throw new (error ?? Error)(
      `Received invalid ${name} value: ${parsed}. Must be a positive integer.`,
    );
  }
  return parsed;
}
