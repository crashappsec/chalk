import { ErrorFunc } from "../types";
import { getErrorMessage } from "./errors";
import { execSync } from "child_process";

export function runCommand(cmd: string, error?: ErrorFunc): string {
  try {
    return execSync(cmd, { stdio: "pipe", encoding: "utf8" });
  } catch (e) {
    if (error) {
      throw new error(getErrorMessage(e));
    }
    throw e;
  }
}

export function binExists(cmd: string): boolean {
  try {
    runCommand(`which ${cmd}`);
    return true;
  } catch {
    return false;
  }
}
