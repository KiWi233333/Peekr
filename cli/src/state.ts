// Process-wide harness state. One socket per live page (CEF's browser-level
// attach is broken; see cdp.ts), the sticky current-tab choice, the ref map
// from the most recent snapshot, and the selected task space. Everything here
// lives for one `peekr nodejs` invocation, mirroring ego-browser.

import type { TargetSocket } from "./cdp.js";

export interface RefInfo {
  /** `@N` handle shown to the agent; unique within the latest snapshot. */
  ref: number;
  /** CDP backend node id — stable across calls for the same element. */
  backendDOMNodeId?: number;
  /** Stable locator usable across snapshots. */
  locator?: string;
  role: string;
  name: string;
  /** Owning target id for OOPIF refs; undefined = the current page itself. */
  frameTargetId?: string;
  /** Same-origin frame chain (data-peekr-frame ids) + in-frame selector. */
  frame?: { chain: number[]; selector: string; epoch?: string };
  href?: string;
}

export interface SpaceContext {
  id: string;
  name: string;
  ownership: string;
}

export const state = {
  /** Live page sockets keyed by targetId (pages + OOPIF frames). */
  sockets: new Map<string, TargetSocket>(),
  preferredTargetId: null as string | null,
  targetId: null as string | null,
  refMap: new Map<number, RefInfo>(),
  /** Selected agent space; ownership checks hang off this. */
  space: null as SpaceContext | null,
};

export function resetRefs(refs: RefInfo[]): void {
  state.refMap = new Map(refs.map((entry) => [entry.ref, entry]));
}
