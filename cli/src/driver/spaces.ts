import { forgetSpaceRefs } from '../page-refs.js';
// Task-space operations over Peekr's local control API. Spaces map 1:1 onto
// Peekr workspaces with a three-state ownership (user / agent /
// agentDelegatedToUser), enforced app-side and mirrored here. When the
// control API is absent, all browser operations fail closed.

import { discoveryFileURL, loadDiscovery } from "../discovery.js";
import { ErrorCodes, PeekrError } from "../errors.js";
import { state, type SpaceContext } from "../state.js";
import { acquireLease, assertRound, yieldRound } from "../round.js";
import { PageLedgerStore, pageLedgerFileURL } from "../page-ledger.js";

export interface SpaceInfo extends SpaceContext {
  agentOwner: string;
  tabCount: number;
  selectedTabID?: string;
}

interface ControlConfig {
  controlPort: number;
  token?: string;
}

async function controlConfig(): Promise<ControlConfig> {
  const discovery = loadDiscovery();
  if (!discovery.controlPort) {
    throw new PeekrError(
      ErrorCodes.agentAccessDisabled,
      "This Peekr build does not expose the control API. Update Peekr, enable Agent Access, and relaunch.",
    );
  }
  return { controlPort: discovery.controlPort, token: discovery.token };
}

export async function controlRequest<T>(
  method: string,
  path: string,
  body?: unknown,
): Promise<T> {
  const { controlPort, token } = await controlConfig();
  let response: Response;
  try {
    response = await fetch(`http://127.0.0.1:${controlPort}${path}`, {
      method,
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (err) {
    throw new PeekrError(
      ErrorCodes.cdpUnavailable,
      `Control API unreachable: ${(err as Error).message}. Is Peekr running with Agent Access enabled?`,
    );
  }
  const payload = await response.json().catch(() => undefined) as any;
  if (!response.ok || payload?.ok === false) {
    throw new PeekrError(
      payload?.code ?? ErrorCodes.actionFailed,
      payload?.message ?? `Control API ${method} ${path} failed (HTTP ${response.status}).`,
      payload?.data,
    );
  }
  return payload as T;
}

export async function listSpaces(): Promise<SpaceInfo[]> {
  const payload = await controlRequest<{ spaces: SpaceInfo[] }>("GET", "/spaces");
  return payload.spaces;
}

export function selectSpace(space: SpaceInfo): SpaceInfo {
  if (state.space?.id !== space.id) {
    state.targetId = null;
    state.preferredTargetId = null;
    state.refMap.clear();
  }
  state.space = space;
  return space;
}

export async function readSpace(id: string): Promise<SpaceInfo> {
  const space = (await listSpaces()).find(entry => entry.id === id);
  if (!space) throw new PeekrError(ErrorCodes.spaceInactive, `Space ${id} no longer exists.`);
  return space;
}

/** An exact id wins; duplicate names are ambiguous and must never silently select a space. */
export async function useOrCreateSpace(nameOrId: string | number): Promise<SpaceInfo> {
  const name = String(nameOrId).trim();
  if (!name) throw new PeekrError(ErrorCodes.invalidArgument, 'A task space name or id is required.');
  const spaces = await listSpaces();
  const exact = spaces.find(space => space.id === name);
  const matches = exact ? [exact] : spaces.filter(space => space.name === name);
  if (matches.length > 1) throw new PeekrError(ErrorCodes.invalidArgument, 'Ambiguous space name; use its id.');
  if (!matches.length && (/^[0-9]+$/.test(name) || /^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(name))) {
    throw new PeekrError(ErrorCodes.spaceNotFound, `No space with id ${name}.`);
  }
  const space = matches[0] ?? (await controlRequest<{space: SpaceInfo}>('POST', '/spaces', { name })).space;
  selectSpace(space);
  await assertAgentMayOperate();
  return space;
}

async function spaceAction(path: string, body?: unknown): Promise<SpaceInfo> {
  const payload = await controlRequest<{ space: SpaceInfo }>("POST", path, body);
  return selectSpace(payload.space);
}

/** Take a user-owned (or handed-off) space over as the agent's own. */
export async function claimSpace(id: string | number): Promise<SpaceInfo> {
  return spaceAction(`/spaces/${encodeURIComponent(String(id))}/claim`);
}

/** Agent hands control to the user (e.g. login, captcha) — space stays ours. */
export async function handOffSpace(id?: string | number): Promise<{ done: boolean; skipped?: string; space?: SpaceInfo }> {
  const target = id ?? state.space?.id;
  if (!target) return { done: false, skipped: "no-space-selected" };
  const space = await spaceAction(`/spaces/${encodeURIComponent(String(target))}/handoff`);
  yieldRound();
  return { done: true, space };
}

/** Resume after the user confirms "continue" — re-grabs a handed-off space. */
export async function takeOverSpace(id?: string | number): Promise<SpaceInfo> {
  const target = id ?? state.space?.id;
  if (!target) {
    throw new PeekrError(ErrorCodes.spaceNotFound, "No space selected; pass an id or select one first.");
  }
  return spaceAction(`/spaces/${encodeURIComponent(String(target))}/claim`);
}

/**
 * Finish the task. `keep: false` (default) closes the space; `keep: true`
 * leaves the pages up for the user to inspect.
 */
export async function completeSpace(id?: string | number, options: { keep?: boolean | string[] } = {}): Promise<{ done: boolean; closed: boolean }> {
  const target = String(id ?? state.space?.id ?? '');
  if (!target) throw new PeekrError(ErrorCodes.spaceRequired, 'Select a task space first.');
  selectSpace(await readSpace(target));
  await assertAgentMayOperate();
  const store = new PageLedgerStore(pageLedgerFileURL(discoveryFileURL()));
  const { tabs } = await controlRequest<{ tabs: Array<{ targetId: string }> }>('GET', `/spaces/${encodeURIComponent(target)}/tabs`);
  const live = store.reconcile(target, tabs.map(tab => tab.targetId), acquireLease()).active;
  let keep: string[] = [];
  if (options.keep === true) keep = tabs.map(tab => tab.targetId);
  else if (Array.isArray(options.keep)) {
    keep = options.keep.map(label => {
      const entry = live.find(page => page.label === label);
      if (!entry) throw new PeekrError(ErrorCodes.stalePage, `Cannot retain unknown page ${label}.`);
      return entry.targetId;
    });
  }
  const result = await controlRequest<{ closed: boolean }>('POST', `/spaces/${encodeURIComponent(target)}/finish`, { keep });
  store.clearSpace(target);
  forgetSpaceRefs(target);
  state.space = null;
  state.targetId = null;
  state.preferredTargetId = null;
  state.refMap.clear();
  return { done: true, closed: result.closed };
}

/** Read-only poll until the space is agent-controlled again (or timeout). */
export async function waitForAgentControl(id?: string | number, timeoutSeconds = 120): Promise<SpaceInfo> {
  const target = id ?? state.space?.id;
  if (!target) {
    throw new PeekrError(ErrorCodes.spaceNotFound, "waitForAgentControl needs a space id.");
  }
  const deadline = Date.now() + timeoutSeconds * 1_000;
  for (;;) {
    const spaces = await listSpaces();
    const space = spaces.find((entry) => entry.id === String(target));
    if (!space) throw new PeekrError(ErrorCodes.spaceInactive, `Space ${target} no longer exists.`);
    if (space && space.ownership === "agent") {
      return selectSpace(space);
    }
    if (Date.now() > deadline) {
      throw new PeekrError(
        ErrorCodes.spaceUserInControl,
        `Space ${target} is still user-controlled after ${timeoutSeconds}s.`,
      );
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 1_000));
  }
}

/**
 * Guard for browser ops: with a selected space that the user now owns, every
 * operation hard-stops. Ownership is refreshed before every protocol dispatch.
 */
export async function assertAgentMayOperate(): Promise<void> {
  assertRound();
  acquireLease();
  if (!state.space) throw new PeekrError(ErrorCodes.spaceRequired, 'Select a task space before operating the browser.');
  const fresh = await readSpace(state.space.id);
  state.space = fresh;
  if (fresh.ownership !== 'agent') {
    throw new PeekrError(ErrorCodes.spaceUserInControl, `Space "${fresh.name || fresh.id}" is controlled by the user.`);
  }
}
