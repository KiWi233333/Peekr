import { mkdirSync, readFileSync, writeFileSync, renameSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { createHash } from 'node:crypto';
import { discoveryFileURL } from './discovery.js';
import { acquireLease } from './round.js';
import { state, resetRefs, type RefInfo } from './state.js';
import type { TargetSocket } from './cdp.js';
import { ErrorCodes, PeekrError } from './errors.js';

const hash = (value: string) => createHash('sha256').update(value).digest('hex');
function directory(space: string): string { return join(dirname(discoveryFileURL()), 'page-refs', hash(space)); }
function path(): string | undefined {
  return state.space && state.targetId ? join(directory(state.space.id), `${hash(state.targetId)}.json`) : undefined;
}
export async function documentEpoch(socket: TargetSocket): Promise<string> {
  const result = await socket.send<any>('Runtime.evaluate', { expression: 'JSON.stringify([location.href, performance.timeOrigin])', returnByValue: true });
  if (typeof result?.result?.value !== 'string') throw new PeekrError(ErrorCodes.unknownRef, 'Cannot verify snapshot document identity.');
  return result.result.value;
}
export function savePageRefs(epoch: string, refs: RefInfo[]): void {
  const file = path();if (!file) return;
  mkdirSync(dirname(file), {recursive: true, mode: 0o700});
  const temporary = `${file}.tmp-${process.pid}`;
  writeFileSync(temporary, JSON.stringify({generation:acquireLease(),epoch,refs}), {mode:0o600});
  renameSync(temporary,file);
}
export async function restorePageRefs(socket: TargetSocket): Promise<void> {
  const file=path();if(!file)return;
  resetRefs([]);
  let saved: {generation:string;epoch:string;refs:RefInfo[]};
  try {saved=JSON.parse(readFileSync(file,'utf8'));} catch { return; }
  if(saved.generation!==acquireLease() || !Array.isArray(saved.refs))return;
  if(saved.epoch===await documentEpoch(socket))resetRefs(saved.refs);
}
export function forgetPageRefs(): void { const file=path();if(file)rmSync(file,{force:true});resetRefs([]); }
export function forgetSpaceRefs(space: string): void { rmSync(directory(space),{recursive:true,force:true}); }
