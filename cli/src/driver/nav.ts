import { forgetPageRefs } from '../page-refs.js';
// Navigation driver: target discovery, sticky current-tab selection, per-page
// socket lifecycle, and URL loading. Mirrors ego-browser's nav.ts surface.

import { listTargetsHttp, TargetSocket } from "../cdp.js";
import { discoveryFileURL, loadDiscovery } from "../discovery.js";
import { ErrorCodes, PeekrError } from "../errors.js";
import { PageLedgerStore, pageLedgerFileURL } from "../page-ledger.js";
import { state } from "../state.js";
import { acquireLease, rememberFailure } from "../round.js";
import { assertAgentMayOperate, controlRequest } from "./spaces.js";

export function currentLedger(): PageLedgerStore {
  if (!state.space) throw new PeekrError(ErrorCodes.spaceRequired, 'Select a task space first.');
  acquireLease();
  return new PageLedgerStore(pageLedgerFileURL(discoveryFileURL()));
}

function nextPageLabel(store: PageLedgerStore): string {
  const used = new Set(store.list(state.space?.id).map(entry => entry.label));
  for (let index = 1; ; index++) if (!used.has(`p${index}`)) return `p${index}`;
}

function spacePath(): string {
  if (!state.space) throw new PeekrError(ErrorCodes.spaceRequired, 'Select a task space first.');
  return `/spaces/${encodeURIComponent(state.space.id)}/tabs`;
}

export async function socketFor(targetId: string, wsUrl?: string): Promise<TargetSocket> {
  const existing = state.sockets.get(targetId);
  if (existing) {
    if (existing.isOpen) return existing;
    state.sockets.delete(targetId);
    state.refMap.clear();
    throw new PeekrError(ErrorCodes.cdpUnavailable, 'Page socket disconnected; start a new round. No action was replayed.');
  }
  const url = wsUrl ?? (await listTargetsHttp(loadDiscovery().port)).find(target => target.targetId === targetId)?.webSocketDebuggerUrl;
  if (!url) throw new PeekrError(ErrorCodes.stalePage, `No live socket for page ${targetId}.`);
  const socket = await TargetSocket.open(url);
  // Recheck native ownership before every protocol dispatch, including polling waits.
  socket.beforeSend = async () => {
    try {
      await assertAgentMayOperate();
      if (!(await listTabs()).some(tab => tab.targetId === targetId)) {
        throw new PeekrError(ErrorCodes.targetNotOwned, 'Page no longer belongs to the selected task space.');
      }
    } catch (error) { rememberFailure(error); throw error; }
  };
  try {
    await socket.try('Page.enable');
    await socket.try('Runtime.enable');
    await socket.try('DOM.enable');
    state.sockets.set(targetId, socket);
    return socket;
  } catch (error) {
    socket.close();
    throw error;
  }
}

export async function currentSocket(options: { createIfMissing?: boolean } = {}): Promise<TargetSocket> {
  return socketFor(await ensureCurrentPage(options));
}

export async function ensureCurrentPage(_options: { createIfMissing?: boolean } = {}): Promise<string> {
  await assertAgentMayOperate();
  const tabs = await listTabs();
  const preferred = state.preferredTargetId;
  const chosen = preferred ? tabs.find(tab => tab.targetId === preferred) : tabs[0];
  if (!chosen) throw new PeekrError(preferred ? ErrorCodes.stalePage : ErrorCodes.noActiveTab,
    preferred ? 'Selected page disappeared; refusing to switch to another page.' : 'No managed pages in this task space.');
  if (state.targetId !== chosen.targetId) state.refMap.clear();
  state.targetId = chosen.targetId;
  state.preferredTargetId = chosen.targetId;
  await socketFor(chosen.targetId);
  return chosen.targetId;
}

export interface TabInfo {
  targetId: string;
  tabId?: string;
  title: string;
  url: string;
  active: boolean;
  label?: string;
}

export async function listTabs(): Promise<TabInfo[]> {
  await assertAgentMayOperate();
  const payload = await controlRequest<{ tabs: TabInfo[] }>('GET', spacePath());
  const store = currentLedger();
  const { active } = store.reconcile(state.space!.id, payload.tabs.map(tab => tab.targetId), acquireLease());
  const labels = new Map(active.map(entry => [entry.targetId, entry.label]));
  return payload.tabs.map(tab => ({ ...tab, label: labels.get(tab.targetId), active: tab.targetId === state.preferredTargetId }));
}

export async function switchTab(targetId: string): Promise<void> {
  const tab = (await listTabs()).find(entry => entry.targetId === targetId || entry.label === targetId);
  if (!tab) throw new PeekrError(ErrorCodes.targetNotOwned, 'Target is not a managed page in this space.');
  if (state.targetId !== tab.targetId) state.refMap.clear();
  state.preferredTargetId = tab.targetId;
  state.targetId = tab.targetId;
  await socketFor(tab.targetId);
}

export interface OpenOptions { wait?: boolean; timeout?: number; label?: string }

export function navigationURL(input: string): string {
  let url: URL;
  try { url = new URL(/^[a-z][a-z0-9+.-]*:/i.test(input) ? input : `https://${input}`); }
  catch { throw new PeekrError(ErrorCodes.invalidArgument, 'Invalid page URL.'); }
  if (!['http:', 'https:'].includes(url.protocol)) throw new PeekrError(ErrorCodes.invalidArgument, 'Only HTTP(S) page URLs are supported.');
  return url.href;
}

export async function openOrReuseTab(url: string, options: OpenOptions = {}): Promise<TabInfo> {
  await assertAgentMayOperate();
  const wanted = navigationURL(url);
  const tabs = await listTabs();
  const store = currentLedger();
  const entry = options.label ? store.resolve(state.space!.id, options.label) : undefined;
  if (entry && (entry.status !== 'active' || entry.generation !== acquireLease())) {
    throw new PeekrError(ErrorCodes.stalePage, `Page ${options.label} is stale or permanently closed. Use a new label.`);
  }
  // Explicit labels identify pages, never URL prefixes or unrelated tabs.
  const existing = options.label ? tabs.find(tab => tab.targetId === entry?.targetId) : tabs.find(tab => tab.url === wanted);
  if (existing) {
    await switchTab(existing.targetId);
    if (existing.url !== wanted) await gotoAndWait(wanted, { timeout: options.timeout });
    return existing;
  }
  const label = options.label ?? nextPageLabel(store);
  const { tab } = await controlRequest<{ tab: TabInfo }>('POST', spacePath(), { url: wanted });
  store.bind(state.space!.id, label, tab.targetId, { url: wanted, title: tab.title, generation: acquireLease() });
  state.refMap.clear();
  state.targetId = tab.targetId;
  state.preferredTargetId = tab.targetId;
  if (options.wait !== false) await waitForLoad({ timeout: options.timeout });
  return { ...tab, label, active: true };
}

export async function closeTab(targetId?: string): Promise<void> {
  const id = targetId ?? state.targetId;
  if (!id) throw new PeekrError(ErrorCodes.noActiveTab, 'No selected page.');
  const tab = (await listTabs()).find(entry => entry.targetId === id || entry.label === id);
  if (!tab) throw new PeekrError(ErrorCodes.targetNotOwned, 'Target is not owned by this space.');
  await switchTab(tab.targetId);
  await controlRequest('DELETE', `${spacePath()}/${encodeURIComponent(tab.targetId)}`);
  forgetPageRefs();
  state.sockets.get(tab.targetId)?.close();
  state.sockets.delete(tab.targetId);
  if (tab.label) currentLedger().unbind(state.space!.id, tab.label);
  if (state.targetId === tab.targetId) { state.targetId = null; state.preferredTargetId = null; state.refMap.clear(); }
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
export async function waitForLoad(options: WaitOptions = {}, loaderId?: string): Promise<void> {
  const socket = await currentSocket();
  const timeoutMs = options.timeout ?? 20_000;
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const done = await socket
      .send<any>("Runtime.evaluate", { expression: "document.readyState", returnByValue: true });
    const readyState = done?.result?.value;
    const info = await pageInfo();
    const frame = loaderId ? await socket.send<any>('Page.getFrameTree') : undefined;
    if (readyState === 'complete' && /^https?:/.test(info.url) && (!loaderId || frame?.frameTree?.frame?.loaderId === loaderId)) break;
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
  const target = navigationURL(url);
  forgetPageRefs();
  const result = await socket.send<{errorText?: string; loaderId?: string}>("Page.navigate", { url: target });
  if (result.errorText) throw new PeekrError(ErrorCodes.actionFailed, result.errorText);
  await waitForLoad({ timeout: options.timeout, settle: options.settle ?? 250 }, result.loaderId);
  // Refs from the previous page are gone after navigation.
  state.refMap = new Map();
  return await pageInfo();
}
