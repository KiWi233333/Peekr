// Minimal CDP client. Node ≥22 ships a global `WebSocket`, so no dependency
// is needed. CEF's browser-level flattened sessions (Target.attachToTarget)
// are broken — verified against CEF 148 — so the harness connects one socket
// per authorized page. Native control routes own all target lifecycle operations.

import { ErrorCodes, PeekrError } from "./errors.js";

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
    reject: (error: Error) => void;
    timer: NodeJS.Timeout;
  }> = [];
  private eventLog: CdpEvent[] = [];

  beforeSend?: () => Promise<void>;
  get isOpen(): boolean { return this.ws?.readyState === WebSocket.OPEN; }
  private constructor(readonly url: string) {}

  static async open(wsUrl: string): Promise<TargetSocket> {
    const url = new URL(wsUrl);
    if (url.protocol !== 'ws:' || !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) {
      throw new PeekrError(ErrorCodes.cdpUnavailable, 'Only local DevTools sockets are supported.');
    }
    const socket = new TargetSocket(wsUrl);
    await socket.openWs(wsUrl);
    return socket;
  }

  private openWs(wsUrl: string): Promise<void> {
    return new Promise((resolvePromise, reject) => {
      this.ws = new WebSocket(wsUrl);
      const timer = setTimeout(
        () => { this.ws.close(); reject(new PeekrError(ErrorCodes.cdpUnavailable, "DevTools WebSocket handshake timed out.")); },
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
        clearTimeout(timer);
        const error = new PeekrError(ErrorCodes.cdpUnavailable, 'DevTools connection closed; requests were not replayed.');
        reject(error);
        this.rejectPending(error);
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
    await this.beforeSend?.();
    if (!this.isOpen) throw new PeekrError(ErrorCodes.cdpUnavailable, 'DevTools socket is closed; start a new round.');
    const id = this.nextId++;
    return new Promise<T>((resolvePromise, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new PeekrError(ErrorCodes.cdpUnavailable, `CDP ${method} timed out.`));
      }, DEFAULT_TIMEOUT_MS);
      this.pending.set(id, { method, resolve: resolvePromise, reject, timer });
      try { this.ws.send(JSON.stringify({ id, method, params: params ?? {} })); }
      catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error as Error); }
    });
  }

  /** Send and ignore all failures (best-effort domain enables, cleanup). */
  async try<T = any>(method: string, params?: any): Promise<T | undefined> {
    try {
      return await this.send<T>(method, params);
    } catch (error) {
      if (error instanceof PeekrError && (error.hardStop || error.code === ErrorCodes.cdpUnavailable)) throw error;
      return undefined;
    }
  }

  waitForEvent(
    method: string,
    options: { predicate?: (params: any) => boolean; timeoutMs?: number } = {},
  ): Promise<CdpEvent> {
    if (!this.isOpen) return Promise.reject(new PeekrError(ErrorCodes.cdpUnavailable, 'DevTools socket is closed.'));
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
        reject,
        timer,
      });
    });
  }

  private rejectPending(error: Error): void {
    for (const entry of this.pending.values()) { clearTimeout(entry.timer); entry.reject(error); }
    this.pending.clear();
    for (const waiter of this.eventWaiters) { clearTimeout(waiter.timer); waiter.reject(error); }
    this.eventWaiters = [];
    this.eventLog = [];
  }

  close(): void {
    this.rejectPending(new PeekrError(ErrorCodes.cdpUnavailable, 'DevTools socket disposed.'));
    try {
      this.ws.close();
    } catch {
      // Closing an already-dead socket is fine.
    }
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
