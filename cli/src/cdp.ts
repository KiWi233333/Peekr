// Minimal CDP client. Node ≥22 ships a global `WebSocket`, so no dependency
// is needed. CEF's browser-level flattened sessions (Target.attachToTarget)
// are broken — verified against CEF 148 — so the harness connects one socket
// per page (`/json/list` → webSocketDebuggerUrl) and keeps a browser-level
// socket only for Target.createTarget / Target.closeTarget, which do work.

import { ErrorCodes, PeekrError } from "./errors.js";
import type { Discovery } from "./discovery.js";

export interface CdpTarget {
  targetId: string;
  type: string;
  title: string;
  url: string;
  attached: boolean;
  webSocketDebuggerUrl?: string;
}

type Pending = {
  method: string;
  resolve: (value: any) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
};

export type CdpEvent = { method: string; params: any };

const DEFAULT_TIMEOUT_MS = 30_000;

/** One WebSocket bound to a single target (page or OOPIF frame). */
export class TargetSocket {
  private ws!: WebSocket;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private eventWaiters: Array<{
    method: string;
    predicate?: (params: any) => boolean;
    resolve: (event: CdpEvent) => void;
    timer: NodeJS.Timeout;
  }> = [];
  private eventLog: CdpEvent[] = [];

  private constructor(readonly url: string) {}

  static async open(wsUrl: string): Promise<TargetSocket> {
    const socket = new TargetSocket(wsUrl);
    await socket.openWs(wsUrl);
    return socket;
  }

  private openWs(wsUrl: string): Promise<void> {
    return new Promise((resolvePromise, reject) => {
      this.ws = new WebSocket(wsUrl);
      const timer = setTimeout(
        () => reject(new PeekrError(ErrorCodes.cdpUnavailable, "DevTools WebSocket handshake timed out.")),
        10_000,
      );
      this.ws.addEventListener("open", () => {
        clearTimeout(timer);
        resolvePromise();
      });
      this.ws.addEventListener("error", () => {
        clearTimeout(timer);
        reject(new PeekrError(ErrorCodes.cdpUnavailable, "DevTools WebSocket failed to connect."));
      });
      this.ws.addEventListener("message", (event) => this.receive(String(event.data)));
      this.ws.addEventListener("close", () => {
        for (const [, entry] of this.pending) {
          clearTimeout(entry.timer);
          entry.reject(new PeekrError(ErrorCodes.cdpUnavailable, "DevTools connection closed."));
        }
        this.pending.clear();
      });
    });
  }

  private receive(raw: string): void {
    let message: any;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (message.id !== undefined) {
      const entry = this.pending.get(message.id);
      if (!entry) return;
      this.pending.delete(message.id);
      clearTimeout(entry.timer);
      if (message.error) {
        entry.reject(
          new PeekrError(
            ErrorCodes.actionFailed,
            `CDP ${entry.method}: ${message.error.message ?? "error"}`,
            { cdpError: message.error },
          ),
        );
      } else {
        entry.resolve(message.result);
      }
      return;
    }
    if (message.method) {
      const event: CdpEvent = { method: message.method, params: message.params };
      this.eventLog.push(event);
      if (this.eventLog.length > 2_000) this.eventLog.splice(0, 1_000);
      for (let index = this.eventWaiters.length - 1; index >= 0; index--) {
        const waiter = this.eventWaiters[index];
        if (waiter.method !== event.method) continue;
        if (waiter.predicate && !waiter.predicate(event.params)) continue;
        this.eventWaiters.splice(index, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(event);
      }
    }
  }

  async send<T = any>(method: string, params?: any): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolvePromise, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new PeekrError(ErrorCodes.cdpUnavailable, `CDP ${method} timed out.`));
      }, DEFAULT_TIMEOUT_MS);
      this.pending.set(id, { method, resolve: resolvePromise, reject, timer });
      this.ws.send(JSON.stringify({ id, method, params: params ?? {} }));
    });
  }

  /** Send and ignore all failures (best-effort domain enables, cleanup). */
  async try<T = any>(method: string, params?: any): Promise<T | undefined> {
    try {
      return await this.send<T>(method, params);
    } catch {
      return undefined;
    }
  }

  waitForEvent(
    method: string,
    options: { predicate?: (params: any) => boolean; timeoutMs?: number } = {},
  ): Promise<CdpEvent> {
    for (let index = 0; index < this.eventLog.length; index++) {
      const event = this.eventLog[index];
      if (event.method !== method) continue;
      if (options.predicate && !options.predicate(event.params)) continue;
      this.eventLog.splice(index, 1);
      return Promise.resolve(event);
    }
    return new Promise((resolvePromise, reject) => {
      const timer = setTimeout(() => {
        this.eventWaiters = this.eventWaiters.filter((entry) => entry.timer !== timer);
        reject(new PeekrError(ErrorCodes.actionFailed, `Timed out waiting for ${method}.`));
      }, options.timeoutMs ?? DEFAULT_TIMEOUT_MS);
      this.eventWaiters.push({
        method,
        predicate: options.predicate,
        resolve: resolvePromise,
        timer,
      });
    });
  }

  close(): void {
    try {
      this.ws.close();
    } catch {
      // Closing an already-dead socket is fine.
    }
  }
}

/**
 * Browser-level control socket. Only the target lifecycle commands
 * (createTarget/closeTarget) are routed here — CEF implements those, but not
 * flattened attach sessions.
 */
export class BrowserSocket {
  private constructor(private readonly socket: TargetSocket) {}

  static async connect(port: number): Promise<BrowserSocket> {
    const version = await fetchJson<any>(port, "/json/version").catch(() => null);
    const wsUrl = version?.webSocketDebuggerUrl;
    if (!wsUrl) {
      throw new PeekrError(
        ErrorCodes.cdpUnavailable,
        `Peekr's DevTools endpoint on 127.0.0.1:${port} did not answer. Enable Agent Access, then quit and reopen Peekr.`,
      );
    }
    return new BrowserSocket(await TargetSocket.open(wsUrl));
  }

  send<T = any>(method: string, params?: any): Promise<T> {
    return this.socket.send<T>(method, params);
  }

  try<T = any>(method: string, params?: any): Promise<T | undefined> {
    return this.socket.try<T>(method, params);
  }

  close(): void {
    this.socket.close();
  }
}

export async function fetchJson<T>(port: number, path: string): Promise<T> {
  try {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, {
      signal: AbortSignal.timeout(5_000),
    });
    if (!response.ok) {
      throw new PeekrError(ErrorCodes.cdpUnavailable, `DevTools HTTP ${path} returned ${response.status}.`);
    }
    return (await response.json()) as T;
  } catch (err) {
    if (err instanceof PeekrError) throw err;
    throw new PeekrError(
      ErrorCodes.cdpUnavailable,
      `DevTools HTTP endpoint unreachable (${(err as Error).message}).`,
    );
  }
}

/** Enumerate targets through the HTTP endpoint (no socket needed). */
export async function listTargetsHttp(port: number): Promise<CdpTarget[]> {
  const raw = await fetchJson<any[]>(port, "/json/list");
  // The HTTP endpoint names the id field `id`; CDP responses use `targetId`.
  // Normalize here so everything downstream speaks one shape.
  return raw.map((entry) => ({
    targetId: entry.targetId ?? entry.id,
    type: entry.type,
    title: entry.title,
    url: entry.url,
    attached: entry.attached ?? false,
    webSocketDebuggerUrl: entry.webSocketDebuggerUrl,
  }));
}
