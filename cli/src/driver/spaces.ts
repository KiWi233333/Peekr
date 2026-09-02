// Task-space operations over Peekr's local control API. Spaces map 1:1 onto
// Peekr workspaces with a three-state ownership (user / agent /
// agentDelegatedToUser), enforced app-side and mirrored here. When the
// control API is absent (older app build without the bridge), space helpers
// fail with a clear error while plain page ops keep working CDP-only.

import { loadDiscovery } from "../discovery.js";
import { ErrorCodes, PeekrError } from "../errors.js";
import { state, type SpaceContext } from "../state.js";

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

async function controlRequest<T>(
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

/** Numeric ids must exist; strings match by name or id, else create. */
export async function useOrCreateSpace(nameOrId: string | number): Promise<SpaceInfo> {
  if (typeof nameOrId === "number" || /^\d+$/.test(String(nameOrId).trim())) {
    const numeric = Number(nameOrId);
    const found = (await listSpaces()).find((space) => Number(space.id) === numeric);
    if (!found) {
      throw new PeekrError(
        ErrorCodes.spaceNotFound,
        `No space with id ${numeric}. Use listSpaces() or pass an intent name to create one.`,
      );
    }
    state.space = found;
    return found;
  }
  const name = String(nameOrId).trim();
  const existing = (await listSpaces()).find(
    (space) => space.name === name || space.id === name,
  );
  const space: SpaceInfo = existing
    ?? await controlRequest<{ space: SpaceInfo }>("POST", "/spaces", { name }).then((payload) => payload.space);
  state.space = space;
  return space;
}

async function spaceAction(path: string, body?: unknown): Promise<SpaceInfo> {
  const payload = await controlRequest<{ space: SpaceInfo }>("POST", path, body);
  state.space = payload.space;
  return payload.space;
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
export async function completeSpace(id?: string | number, options: { keep?: boolean } = {}): Promise<{ done: boolean; skipped?: string }> {
  const target = id ?? state.space?.id;
  if (!target) return { done: false, skipped: "no-space-selected" };
  const encoded = encodeURIComponent(String(target));
  if (options.keep) {
    await controlRequest("POST", `/spaces/${encoded}/complete`, { keep: true });
    return { done: true };
  }
  await controlRequest("DELETE", `/spaces/${encoded}`);
  state.space = null;
  return { done: true };
}

/** Read-only poll until the space is agent-controlled again (or timeout). */
export async function waitForAgentControl(id?: string | number, timeoutSeconds = 120): Promise<SpaceInfo> {
  const target = id ?? state.space?.id;
  if (!target) {
    throw new PeekrError(ErrorCodes.spaceNotFound, "waitForAgentControl needs a space id.");
  }
  const deadline = Date.now() + timeoutSeconds * 1_000;
  for (;;) {
    const spaces = await listSpaces().catch(() => undefined);
    const space = spaces?.find((entry) => entry.id === String(target));
    if (space && space.ownership !== "user") {
      state.space = space;
      return space;
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
 * operation hard-stops. Cached briefly so a burst of ops costs one lookup.
 */
export async function assertAgentMayOperate(): Promise<void> {
  if (!state.space) return;
  try {
    const discovery = loadDiscovery();
    if (!discovery.controlPort) return; // CDP-only mode: no ownership enforcement possible
  } catch {
    return;
  }
  const spaces = await listSpaces().catch(() => undefined);
  if (!spaces) return;
  const fresh = spaces.find((space) => space.id === state.space!.id);
  if (!fresh) {
    throw new PeekrError(
      ErrorCodes.spaceInactive,
      `Space ${state.space.id} no longer exists (closed or completed).`,
    );
  }
  state.space = fresh;
  if (fresh.ownership === "user") {
    throw new PeekrError(
      ErrorCodes.spaceUserInControl,
      `Space "${fresh.name || fresh.id}" is controlled by the user right now.`,
    );
  }
}
