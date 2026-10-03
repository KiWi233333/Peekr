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
  { name: "taskSpace", signature: "await taskSpace(name)", summary: "Return a TaskSpace handle with page(label), pages(), handOff() and finish({keep})." },
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
  { name: "useOrCreateTaskSpace", signature: "await useOrCreateTaskSpace(nameOrId)", summary: "Alias of taskSpace; returns a TaskSpace handle." },
  { name: "listTaskSpaces", signature: "await listTaskSpaces()", summary: "Alias of listSpaces." },
  { name: "claimTaskSpace", signature: "await claimTaskSpace(id)", summary: "Claim after user approval and return a TaskSpace handle." },
  { name: "handOffTaskSpace", signature: "await handOffTaskSpace(id?)", summary: "Alias of handOffSpace; ends browser work in this round." },
  { name: "takeOverTaskSpace", signature: "await takeOverTaskSpace(id)", summary: "Resume after user confirmation and return a TaskSpace handle." },
  { name: "completeTaskSpace", signature: "await completeTaskSpace(id?, {keep}?)", summary: "Alias of completeSpace; keep is a boolean or an array of page labels." },
  { name: "waitForAgentControl", signature: "await waitForAgentControl(id, timeoutSeconds?)", summary: "Read-only ownership poll; does not claim control." },
  { name: "doubleClick", signature: "await doubleClick(target)", summary: "Double-click a ref, locator or coordinates." },
  { name: "hover", signature: "await hover(target)", summary: "Move the pointer over a target." },
  { name: "scrollBy", signature: "await scrollBy(amount, target?)", summary: "Scroll by pixels." },
  { name: "typeText", signature: "await typeText(text)", summary: "Insert text into the focused element." },
  { name: "wait", signature: "await wait(seconds)", summary: "Pause for seconds." },
  { name: "waitForLoad", signature: "await waitForLoad({timeout, settle}?)", summary: "Wait for HTTP(S) document completion; time options are milliseconds." },
  { name: "resetRefs", signature: "resetRefs()", summary: "Clear the current in-memory refs." },
  { name: "TaskSpace.page", signature: "task.page(label)", summary: "Return a Page handle bound to this space and label; goto creates it." },
  { name: "TaskSpace.pages", signature: "await task.pages()", summary: "List only native-managed pages in this space, including stable labels." },
  { name: "TaskSpace.handOff", signature: "await task.handOff()", summary: "Give control to the user; no further browser operations in this round." },
  { name: "TaskSpace.finish", signature: "await task.finish({keep: [\"p1\"]})", summary: "Close managed scratch pages, preserve user tabs and give retained pages to the user." },
  { name: "Page.goto", signature: "await page.goto(url, {timeout, settle}?)", summary: "Create or navigate this page. HTTP(S) only; time options are milliseconds." },
  { name: "Page.info", signature: "await page.info()", summary: "Read live URL, title and viewport geometry." },
  { name: "Page.snapshot", signature: "await page.snapshot(options?)", summary: "Snapshot with refs persisted for this page and document across CLI rounds." },
  { name: "Page.snapshotRaw", signature: "await page.snapshotRaw(options?)", summary: "Return snapshot content and refs." },
  { name: "Page.screenshot", signature: "await page.screenshot({path, fullPage}?)", summary: "Capture this page." },
  { name: "Page.click / dblclick / hover / fill", signature: "await page.fill(target, text)", summary: "Act on refs, supported locators or coordinates; click/dblclick/hover take a target." },
  { name: "Page.evaluate", signature: "await page.evaluate(expressionOrFunction, arg?)", summary: "Evaluate page JavaScript and await its result." },
  { name: "Page.cdp", signature: "await page.cdp(method, params?)", summary: "Send a page-scoped command. Browser/Target lifecycle and session routing are unavailable." },
  { name: "Page.reload / stop / close / bringToFront", signature: "await page.bringToFront()", summary: "Reuse the same native page in the panel; close permanently retires its label." },
  { name: "Page.goBack / goForward", signature: "await page.goBack({timeout, settle}?)", summary: "Navigate HTTP(S) history, including same-document entries. Returns null at a boundary; time options are milliseconds." },
  { name: "Page.clear", signature: "await page.clear(target)", summary: "Clear a text input, textarea or contenteditable element." },
  { name: "Page.check / uncheck / setChecked", signature: "await page.setChecked(target, checked)", summary: "Idempotently set a native checkbox/radio using trusted clicks; unchecking radio is rejected." },
  { name: "Page.selectOption", signature: "await page.selectOption(target, valueOrValues)", summary: "Select strings or {value}, {label}, {index}; returns selected values. Supports multiple selects." },
  { name: "Page.setInputFiles", signature: "await page.setInputFiles(target, pathOrPaths)", summary: "Set real files on an existing file input, including hidden inputs. [] clears; missing files and directories are rejected." },
  { name: "Page.waitForSelector", signature: "await page.waitForSelector(css, {state, timeout}?)", summary: "CSS only; attached, detached, visible or hidden. Timeout in milliseconds." },
  { name: "Page.waitForURL", signature: "await page.waitForURL(url, {timeout}?)", summary: "Wait for an exact URL." },
  { name: "Page.waitForFunction", signature: "await page.waitForFunction(expressionOrFunction, arg?, {timeout}?)", summary: "Poll a page expression until truthy." },
  { name: "Page.waitForLoadState", signature: "await page.waitForLoadState(state, {timeout}?)", summary: "Supports load and domcontentloaded; networkidle is unavailable." },
  { name: "Page.keyboard", signature: "await page.keyboard.press(key)", summary: "Single keys and portable chords (ControlOrMeta, Cmd, Ctrl, Alt, Shift); type(text, {delay}) and insertText(text)." },
  { name: "Page.mouse", signature: "await page.mouse.click(x, y)", summary: "Coordinate click or wheel(dx, dy)." },
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
