// Locates and validates Peekr's discovery file (`agent.json`), which the app
// writes at launch while agent access is enabled. Path mirrors the app's
// `AppPaths` so the smoke/isolated data root keeps working for tests.

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { ErrorCodes, PeekrError } from "./errors.js";

export interface Discovery {
  schemaVersion: number;
  /** Chromium DevTools port (CDP). */
  port: number;
  /** Peekr's main process id — lets the CLI detect a stale file. */
  pid: number;
  /** Local control API port (spaces/ownership). Present from agent bridge v1. */
  controlPort?: number;
  /** Bearer token for the control API. */
  token?: string;
}

export function discoveryFileURL(): string {
  const explicit = process.env.PEEKR_AGENT_DISCOVERY?.trim();
  if (explicit) return resolve(explicit);
  const smokeRoot = process.env.PEEKR_SMOKE_DATA_ROOT?.trim();
  if (smokeRoot) return join(resolve(smokeRoot), "agent.json");
  return join(homedir(), "Library", "Application Support", "Peekr", "agent.json");
}

/** True when the pid still exists — cheap liveness check via kill(pid, 0). */
export function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException)?.code === "EPERM";
  }
}

/**
 * Load the discovery file. Missing file or disabled toggle maps to the
 * hard-stop `PEEKR_AGENT_ACCESS_DISABLED`; a dead pid maps to
 * `PEEKR_CDP_UNAVAILABLE` (stale file left behind by a crash).
 */
export function loadDiscovery(): Discovery {
  const fileURL = discoveryFileURL();
  if (!existsSync(fileURL)) {
    throw new PeekrError(
      ErrorCodes.agentAccessDisabled,
      `agent.json not found at ${fileURL} — Peekr writes it only while Agent Access is enabled.`,
    );
  }
  let parsed: Discovery;
  try {
    parsed = JSON.parse(readFileSync(fileURL, "utf8")) as Discovery;
  } catch (err) {
    throw new PeekrError(ErrorCodes.cdpUnavailable, `agent.json is not valid JSON: ${(err as Error).message}`);
  }
  if (!parsed || typeof parsed.port !== "number" || typeof parsed.pid !== "number") {
    throw new PeekrError(ErrorCodes.cdpUnavailable, "agent.json is missing port/pid fields.");
  }
  if (!processAlive(parsed.pid)) {
    throw new PeekrError(
      ErrorCodes.cdpUnavailable,
      `Peekr (pid ${parsed.pid}) is not running; agent.json is stale. Reopen Peekr.`,
    );
  }
  return parsed;
}
