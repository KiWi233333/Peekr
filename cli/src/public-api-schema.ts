export type PublicApiEntry = {
  name: string;
  signature: string;
  summary: string;
  options?: Record<string, { kind: "positiveNumber" | "nonEmptyString" | "boolean" }>;
};

/** Single source for the CLI help surface and the injected namespace names. */
export const PUBLIC_API_SCHEMA: readonly PublicApiEntry[] = [
  { name: "listSpaces", signature: "await listSpaces()", summary: "List task spaces." },
  { name: "useOrCreateSpace", signature: "await useOrCreateSpace(name)", summary: "Reuse or create an Agent-owned task space." },
  { name: "taskSpace", signature: "await taskSpace(name)", summary: "Compatibility alias for useOrCreateSpace." },
  { name: "claimSpace", signature: "await claimSpace(id)", summary: "Claim a space after user approval." },
  { name: "handOffSpace", signature: "await handOffSpace(id)", summary: "Hand a space back to the user." },
  { name: "takeOverSpace", signature: "await takeOverSpace(id)", summary: "Take over an Agent-owned space after approval." },
  { name: "completeSpace", signature: "await completeSpace(id)", summary: "Complete a task space." },
  { name: "listTabs", signature: "await listTabs()", summary: "List browser tabs." },
  { name: "openOrReuseTab", signature: "await openOrReuseTab(url, options?)", summary: "Open or reuse a Chromium tab.", options: { wait: { kind: "boolean" }, timeout: { kind: "positiveNumber" }, label: { kind: "nonEmptyString" } } },
  { name: "switchTab", signature: "await switchTab(targetId)", summary: "Activate a tab." },
  { name: "closeTab", signature: "await closeTab(targetId?)", summary: "Close a tab." },
  { name: "gotoAndWait", signature: "await gotoAndWait(url, options?)", summary: "Navigate and wait for the page.", options: { timeout: { kind: "positiveNumber" }, settle: { kind: "positiveNumber" } } },
  { name: "currentTab", signature: "await currentTab()", summary: "Return the active tab." },
  { name: "pageInfo", signature: "await pageInfo()", summary: "Read active page metadata." },
  { name: "snapshotText", signature: "await snapshotText(options?)", summary: "Return an accessibility-oriented text snapshot." },
  { name: "snapshotRaw", signature: "await snapshotRaw(options?)", summary: "Return the raw accessibility snapshot." },
  { name: "screenshot", signature: "await screenshot(options?)", summary: "Capture the active page." },
  { name: "click", signature: "await click(target, options?)", summary: "Click a snapshot ref or locator." },
  { name: "fillInput", signature: "await fillInput(target, text)", summary: "Fill an input." },
  { name: "pressKey", signature: "await pressKey(key)", summary: "Press a key." },
  { name: "waitForElement", signature: "await waitForElement(target, timeoutSeconds?)", summary: "Wait for an element." },
  { name: "js", signature: "await js(expression)", summary: "Evaluate JavaScript in the page." },
  { name: "cdp", signature: "await cdp(method, params?)", summary: "Send a CDP command." },
  { name: "cliLog", signature: "cliLog(value)", summary: "Write a value to the round output." },
];

export class PublicApiValidationError extends TypeError {
  readonly code = "PEEKR_INVALID_ARGUMENT";
}

export function renderApiHelp(topic?: string): string {
  const normalized = topic?.trim().toLowerCase();
  const entries = normalized
    ? PUBLIC_API_SCHEMA.filter((entry) => entry.name.toLowerCase().includes(normalized))
    : PUBLIC_API_SCHEMA;
  if (normalized && entries.length === 0) return `No API topic matches: ${topic}\n`;
  return entries.map((entry) => `  ${entry.signature}\n    ${entry.summary}`).join("\n") + "\n";
}

export function validateApiCall(name: string, args: unknown[]): void {
  const entry = PUBLIC_API_SCHEMA.find((candidate) => candidate.name === name);
  if (!entry?.options || args[1] === undefined) return;
  const options = args[1];
  if (options === null || typeof options !== "object" || Array.isArray(options)) {
    throw new PublicApiValidationError(`${name} options must be an object`);
  }
  for (const [key, value] of Object.entries(options as Record<string, unknown>)) {
    const spec = entry.options[key];
    if (!spec) throw new PublicApiValidationError(`${name} received unknown option: ${key}`);
    if (spec.kind === "boolean" && typeof value !== "boolean") {
      throw new PublicApiValidationError(`${name}.${key} must be a boolean`);
    }
    if (spec.kind === "nonEmptyString" && (typeof value !== "string" || !value.trim())) {
      throw new PublicApiValidationError(`${name}.${key} must be a non-empty string`);
    }
    if (spec.kind === "positiveNumber" && (typeof value !== "number" || !Number.isFinite(value) || value <= 0)) {
      throw new PublicApiValidationError(`${name}.${key} must be a positive number`);
    }
  }
}

export function withApiValidation<T extends Record<string, unknown>>(registry: T): T {
  return new Proxy(registry, {
    get(target, property, receiver) {
      const value = Reflect.get(target, property, receiver);
      if (typeof property !== "string" || typeof value !== "function") return value;
      return (...args: unknown[]) => {
        validateApiCall(property, args);
        return (value as (...input: unknown[]) => unknown)(...args);
      };
    },
  });
}
