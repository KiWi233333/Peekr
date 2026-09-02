// Ref lifecycle: `@N` handles are only valid for the most recent snapshot —
// every snapshot rebuilds the map (ego-browser behavior). Resolve accepts
// `@12`, bare `12`, and passes CSS/xpath/loc= selectors through untouched.

import { ErrorCodes, PeekrError } from "./errors.js";
import { state, type RefInfo } from "./state.js";

export function isRefToken(target: unknown): target is string | number {
  if (typeof target === "number") return true;
  return typeof target === "string" && /^@\d+$|^\d+$/.test(target.trim());
}

export function resolveRef(target: string | number): RefInfo {
  const token = String(target).trim().replace(/^@/, "");
  const numeric = Number(token);
  const info = Number.isFinite(numeric) ? state.refMap.get(numeric) : undefined;
  if (!info) {
    throw new PeekrError(
      ErrorCodes.unknownRef,
      `Unknown ref ${target}. Refs are only valid for the most recent snapshot — call snapshotText() again.`,
    );
  }
  return info;
}

export function refToken(ref: number): string {
  return `@${ref}`;
}
