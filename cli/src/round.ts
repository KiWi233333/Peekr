import { closeSync, existsSync, mkdirSync, openSync, readFileSync, rmdirSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { createHash } from 'node:crypto';
import { discoveryFileURL, loadDiscovery, processAlive, type Discovery } from './discovery.js';
import { ErrorCodes, PeekrError } from './errors.js';

let lease: { path: string; ino: number; generation: string } | undefined;
let tail: Promise<unknown> = Promise.resolve();
let failure: unknown;
let stopped = false;
let yielded = false;

export function yieldRound(): void { yielded = true; }

export function generationOf(discovery: Discovery): string {
  return createHash('sha256').update(JSON.stringify([discovery.pid, discovery.port, discovery.controlPort, discovery.token])).digest('hex');
}

/** One browser round per app. Native/user control remains available while held. */
export function acquireLease(): string {
  const generation = generationOf(loadDiscovery());
  if (stopped) throw new PeekrError(ErrorCodes.spaceInactive, 'This round has ended.');
  if (lease) {
    if (lease.generation !== generation) throw new PeekrError(ErrorCodes.sessionChanged, 'Peekr restarted during this round; start a new round.');
    return generation;
  }
  const path = join(dirname(discoveryFileURL()), 'agent-round.lock');
  const reaper = `${path}.reap`;
  // Serialize stale-lock removal. Never steal a lease from a live process.
  if (existsSync(path)) {
    try {
      mkdirSync(reaper, { mode: 0o700 });
      try {
        const owner = JSON.parse(readFileSync(path, 'utf8'));
        if (Number.isInteger(owner.pid) && !processAlive(owner.pid)) unlinkSync(path);
      } finally { rmdirSync(reaper); }
    } catch { /* The atomic exclusive open below decides whether we may enter. */ }
  }
  try {
    const fd = openSync(path, 'wx', 0o600);
    try { writeFileSync(fd, JSON.stringify({ pid: process.pid })); }
    finally { closeSync(fd); }
    lease = { path, ino: statSync(path).ino, generation };
  } catch {
    throw new PeekrError(ErrorCodes.browserBusy, 'Another CLI round owns this browser. Wait for that round to end.');
  }
  return generation;
}

export function releaseLease(): void {
  if (!lease) return;
  try { if (statSync(lease.path).ino === lease.ino) unlinkSync(lease.path); } catch { /* already removed */ }
  lease = undefined;
}
process.once('exit', releaseLease);

export function rememberFailure(error: unknown): void {
  if (error instanceof PeekrError && error.hardStop) failure ??= error;
}

export function assertRound(): void {
  if (failure) throw failure;
  if (stopped) throw new PeekrError(ErrorCodes.spaceInactive, 'This round has ended.');
}

/** Serialize complete helper actions, not merely individual CDP messages. */
export function runOperation<T>(operation: () => Promise<T>): Promise<T> {
  const result = tail.then(async () => {
    try {
      assertRound();
      if (yielded) throw new PeekrError(ErrorCodes.spaceUserInControl, 'This round handed control to the user. Resume only in a new round after confirmation.');
      acquireLease();
      return await operation();
    }
    catch (error) { rememberFailure(error); throw error; }
  });
  tail = result.catch(() => undefined);
  return result;
}

export async function finishRound(): Promise<void> {
  await tail;
  assertRound();
}

export function stopRound(): void { stopped = true; releaseLease(); }
