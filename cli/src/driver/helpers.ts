// The helper surface injected into every `peekr nodejs` heredoc. Browser ops
// pass through assertAgentMayOperate() so a user-taken-over space hard-stops
// exactly like ego-browser's "user is controlling".

import { listTargetsHttp } from "../cdp.js";
import { loadDiscovery } from "../discovery.js";
import { ErrorCodes, PeekrError } from "../errors.js";
import { resetRefs, state } from "../state.js";
import {
  closeTab, ensureCurrentPage, gotoAndWait, listTabs, openOrReuseTab,
  pageInfo, switchTab, waitForLoad,
} from "./nav.js";
import { screenshot, snapshotRaw, snapshotText } from "./observe.js";
import { click, doubleClick, hover, scrollBy, type ClickTarget } from "./pointer.js";
import { fillInput, pressKey, typeText } from "./keyboard.js";
import { wait, waitForElement } from "./waits.js";
import { cdp, js } from "./eval.js";
import {
  assertAgentMayOperate, claimSpace, completeSpace, handOffSpace, listSpaces,
  takeOverSpace, useOrCreateSpace, waitForAgentControl,
} from "./spaces.js";

/** Guard: refuse browser ops when the selected space belongs to the user. */
async function guarded<T>(operation: () => Promise<T>): Promise<T> {
  await assertAgentMayOperate();
  return operation();
}

export const helpers = {
  // Task spaces (ego's task-space names are aliased below).
  listSpaces,
  useOrCreateSpace,
  claimSpace,
  handOffSpace,
  takeOverSpace,
  completeSpace,
  waitForAgentControl,

  // Navigation / tabs
  listTabs: () => guarded(listTabs),
  openOrReuseTab: (url: string, options?: { wait?: boolean; timeout?: number }) =>
    guarded(() => openOrReuseTab(url, options)),
  switchTab: (targetId: string) => guarded(() => switchTab(targetId)),
  closeTab: (targetId?: string) => guarded(() => closeTab(targetId)),
  gotoAndWait: (url: string, options?: { timeout?: number; settle?: number }) =>
    guarded(() => gotoAndWait(url, options)),
  currentTab: async () => {
    await guarded(async () => {
      await ensureCurrentPage();
    });
    const discovery = loadDiscovery();
    const targets = await listTargetsHttp(discovery.port);
    const current = targets.find((target) => target.targetId === state.targetId);
    return current
      ? { targetId: current.targetId, title: current.title, url: current.url }
      : null;
  },
  pageInfo: () => guarded(pageInfo),

  // Observation
  snapshotText: (options?: { scope?: "only_within_viewport" | "full_page"; includeActionMarks?: boolean; includeStableLocator?: boolean }) =>
    guarded(() => snapshotText(options)),
  snapshotRaw: (options?: { scope?: "only_within_viewport" | "full_page"; includeActionMarks?: boolean; includeStableLocator?: boolean }) =>
    guarded(() => snapshotRaw(options)),
  screenshot: (options?: { path?: string; fullPage?: boolean }) =>
    guarded(() => screenshot(options)),

  // Pointer / keyboard
  click: (target: ClickTarget, options?: { label?: string }) =>
    guarded(() => click(target, options)),
  doubleClick: (target: ClickTarget, options?: { label?: string }) =>
    guarded(() => doubleClick(target, options)),
  hover: (target: ClickTarget) => guarded(() => hover(target)),
  scrollBy: (amount: number | { dy?: number; dx?: number }, target?: ClickTarget) =>
    guarded(() => scrollBy(amount, target)),
  pressKey: (key: string) => guarded(() => pressKey(key)),
  typeText: (text: string) => guarded(() => typeText(text)),
  fillInput: (target: ClickTarget, text: string) => guarded(() => fillInput(target, text)),

  // Waits
  wait,
  waitForLoad,
  waitForElement,

  // Direct evaluation
  js: (expression: string) => guarded(() => js(expression)),
  cdp,

  /** Clear refs without a fresh snapshot (rarely needed; snapshot resets). */
  resetRefs: (): void => {
    resetRefs([]);
  },

  /** Only output mechanism inside a heredoc. */
  cliLog: (value: unknown): void => {
    console.log(typeof value === "string" ? value : JSON.stringify(value, null, 2));
  },
};

// ego-trained agents get the familiar task-space names for free.
const aliases: Record<string, unknown> = {
  useOrCreateTaskSpace: helpers.useOrCreateSpace,
  listTaskSpaces: helpers.listSpaces,
  claimTaskSpace: helpers.claimSpace,
  handOffTaskSpace: helpers.handOffSpace,
  takeOverTaskSpace: helpers.takeOverSpace,
  completeTaskSpace: helpers.completeSpace,
};
Object.assign(helpers, aliases);

export type HelperRegistry = typeof helpers;

export function helperNames(): string[] {
  return Object.keys(helpers);
}

export { ErrorCodes, PeekrError };
