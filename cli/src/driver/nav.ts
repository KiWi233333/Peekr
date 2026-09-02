// Navigation driver: target discovery, sticky current-tab selection, per-page
// socket lifecycle, and URL loading. Mirrors ego-browser's nav.ts surface.

import { BrowserSocket, listTargetsHttp, TargetSocket, type CdpTarget } from "../cdp.js";
import { loadDiscovery } from "../discovery.js";
import { ErrorCodes, PeekrError } from "../errors.js";
import { state } from "../state.js";

const INTERNAL_URL_PREFIXES = ["devtools://", "chrome://", "wss://"];

function isPageTarget(target: CdpTarget): boolean {
  return target.type === "page" && !INTERNAL_URL_PREFIXES.some((prefix) => target.url.startsWith(prefix));
}

async function ensureBrowserSocket(): Promise<BrowserSocket> {
  if (!state.browser) {
    const discovery = loadDiscovery();
    state.browser = await BrowserSocket.connect(discovery.port);
  }
  return state.browser;
}

/** Open (or reuse) the per-page socket and enable the domains we rely on. */
export async function socketFor(targetId: string, wsUrl?: string): Promise<TargetSocket> {
  const existing = state.sockets.get(targetId);
  if (existing) return existing;
  const url = wsUrl
    ?? (await listTargetsHttp(loadDiscovery().port)).find((target) => target.targetId === targetId)?.webSocketDebuggerUrl;
  if (!url) {
    throw new PeekrError(ErrorCodes.cdpUnavailable, `No DevTools socket for target ${targetId}.`);
  }
  const socket = await TargetSocket.open(url);
  await socket.try("Page.enable");
  await socket.try("Runtime.enable");
  await socket.try("DOM.enable");
  state.sockets.set(targetId, socket);
  return socket;
}

/** Socket of the current page; connects (or reconnects) on demand. */
export async function currentSocket(options: { createIfMissing?: boolean } = {}): Promise<TargetSocket> {
  const targetId = await ensureCurrentPage(options);
  return socketFor(targetId);
}

/**
 * Pick the current page: the sticky preferred target when still alive, else
 * the first real page. Throws `PEEKR_NO_ACTIVE_TAB` when Peekr has no pages.
 */
export async function ensureCurrentPage(options: { createIfMissing?: boolean } = {}): Promise<string> {
  const discovery = loadDiscovery();
  let targets = (await listTargetsHttp(discovery.port)).filter(isPageTarget);

  if (targets.length === 0 && options.createIfMissing) {
    const browser = await ensureBrowserSocket();
    const created = await browser.send<{ targetId: string }>("Target.createTarget", { url: "about:blank" });
    state.preferredTargetId = created.targetId;
    state.targetId = created.targetId;
    targets = (await listTargetsHttp(discovery.port)).filter(isPageTarget);
  } else if (targets.length === 0) {
    throw new PeekrError(
      ErrorCodes.noActiveTab,
      "Peekr has no live web pages. Open one in the panel or call openOrReuseTab(url).",
    );
  }

  const preferred = state.preferredTargetId
    ? targets.find((target) => target.targetId === state.preferredTargetId)
    : undefined;
  const chosen = preferred ?? targets[0];
  if (state.targetId === chosen.targetId && state.sockets.has(chosen.targetId)) {
    return chosen.targetId;
  }

  state.preferredTargetId = chosen.targetId;
  state.targetId = chosen.targetId;
  await socketFor(chosen.targetId, chosen.webSocketDebuggerUrl);
  return chosen.targetId;
}

export interface TabInfo {
  targetId: string;
  title: string;
  url: string;
  active: boolean;
}

export async function listTabs(): Promise<TabInfo[]> {
  const discovery = loadDiscovery();
  const targets = (await listTargetsHttp(discovery.port)).filter(isPageTarget);
  return targets.map((target) => ({
    targetId: target.targetId,
    title: target.title,
    url: target.url,
    active: target.targetId === (state.preferredTargetId ?? targets[0]?.targetId),
  }));
}

export async function switchTab(targetId: string): Promise<void> {
  const discovery = loadDiscovery();
  const target = (await listTargetsHttp(discovery.port)).find((entry) => entry.targetId === targetId);
  if (!target) {
    throw new PeekrError(ErrorCodes.noActiveTab, `No tab with targetId ${targetId}.`);
  }
  state.preferredTargetId = targetId;
  state.targetId = targetId;
  await socketFor(targetId, target.webSocketDebuggerUrl);
}

export interface OpenOptions {
  wait?: boolean;
  timeout?: number;
}

/** Reuse the first tab whose URL starts with `url`; otherwise open a new one. */
export async function openOrReuseTab(url: string, options: OpenOptions = {}): Promise<TabInfo> {
  const wanted = url.startsWith("http") ? url : `https://${url}`;
  const existing = (await listTabs()).find((tab) => tab.url.startsWith(wanted));
  if (existing) {
    await switchTab(existing.targetId);
    return existing;
  }
  const browser = await ensureBrowserSocket();
  const created = await browser.send<{ targetId: string }>("Target.createTarget", { url: wanted });
  state.preferredTargetId = created.targetId;
  state.targetId = created.targetId;
  if (options.wait !== false) await waitForLoad({ timeout: options.timeout });
  const tabs = await listTabs();
  return (
    tabs.find((tab) => tab.targetId === created.targetId)
    ?? { targetId: created.targetId, title: "", url: wanted, active: true }
  );
}

export async function closeTab(targetId?: string): Promise<void> {
  const id = targetId ?? state.targetId;
  if (!id) return;
  const browser = await ensureBrowserSocket();
  await browser.try("Target.closeTarget", { targetId: id });
  state.sockets.get(id)?.close();
  state.sockets.delete(id);
  if (id === state.targetId) {
    state.targetId = null;
  }
}

export interface PageInfo {
  url: string;
  title: string;
  w: number;
  h: number;
  sx: number;
  sy: number;
  pw: number;
  ph: number;
}

/** Live geometry + document state of the current page (ego pageInfo shape). */
export async function pageInfo(): Promise<PageInfo> {
  const socket = await currentSocket();
  const result = await socket.send<any>(
    "Runtime.evaluate",
    {
      expression: `(() => {
        const doc = document.documentElement;
        return {
          url: location.href,
          title: document.title,
          w: window.innerWidth, h: window.innerHeight,
          sx: window.scrollX, sy: window.scrollY,
          pw: Math.max(doc ? doc.scrollWidth : 0, window.innerWidth),
          ph: Math.max(doc ? doc.scrollHeight : 0, window.innerHeight),
          readyState: document.readyState
        };
      })()`,
      returnByValue: true,
    },
  );
  const value = result?.result?.value;
  if (!value) {
    throw new PeekrError(ErrorCodes.actionFailed, "pageInfo could not read the document.");
  }
  return value as PageInfo;
}

export interface WaitOptions {
  timeout?: number;
  /** Extra settle time in ms after the load event. */
  settle?: number;
}

/** Wait until the current page reaches `complete` (plus an optional settle). */
export async function waitForLoad(options: WaitOptions = {}): Promise<void> {
  const socket = await currentSocket();
  const timeoutMs = options.timeout ?? 20_000;
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const done = await socket
      .send<any>("Runtime.evaluate", { expression: "document.readyState", returnByValue: true })
      .catch(() => undefined);
    const readyState = done?.result?.value;
    if (readyState === "complete") break;
    if (Date.now() > deadline) {
      throw new PeekrError(
        ErrorCodes.actionFailed,
        `Page load timed out after ${timeoutMs} ms (readyState: ${readyState}).`,
      );
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  if (options.settle) await new Promise((resolvePromise) => setTimeout(resolvePromise, options.settle));
}

export async function gotoAndWait(url: string, options: WaitOptions = {}): Promise<PageInfo> {
  const socket = await currentSocket();
  const target = url.startsWith("http") ? url : `https://${url}`;
  await socket.send("Page.navigate", { url: target });
  await waitForLoad({ timeout: options.timeout, settle: options.settle ?? 250 });
  // Refs from the previous page are gone after navigation.
  state.refMap = new Map();
  return await pageInfo();
}
