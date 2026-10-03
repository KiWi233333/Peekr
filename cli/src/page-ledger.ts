import { chmodSync, existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { ErrorCodes, PeekrError } from './errors.js';

export interface PageLedgerEntry {
  spaceId: string;
  label: string;
  targetId: string;
  generation?: string;
  status?: 'active' | 'stale' | 'closed';
  url?: string;
  title?: string;
  updatedAt: string;
}
export interface LedgerReconciliation { active: PageLedgerEntry[]; stale: PageLedgerEntry[] }

/** Mutations are performed under the CLI round lease; no last-writer-wins merging. */
export class PageLedgerStore {
  private entries = new Map<string, PageLedgerEntry>();
  constructor(readonly fileURL: string) { this.load(); }
  list(spaceId?: string): PageLedgerEntry[] {
    return [...this.entries.values()].filter(entry => !spaceId || entry.spaceId === spaceId);
  }
  resolve(spaceId: string, label: string): PageLedgerEntry | undefined {
    return this.entries.get(this.key(spaceId, label));
  }
  bind(spaceId: string, label: string, targetId: string, metadata: Partial<Pick<PageLedgerEntry, 'url' | 'title' | 'generation'>> = {}): PageLedgerEntry {
    if (this.resolve(spaceId, label)) throw new PeekrError(ErrorCodes.stalePage, `Page label ${label} already exists; closed/stale labels cannot be reused.`);
    const entry: PageLedgerEntry = { spaceId, label, targetId, ...metadata, status: 'active', updatedAt: new Date().toISOString() };
    this.entries.set(this.key(spaceId, label), entry);
    this.save();
    return entry;
  }
  unbind(spaceId: string, label: string): void {
    const entry = this.resolve(spaceId, label);
    if (entry) { entry.status = 'closed'; entry.updatedAt = new Date().toISOString(); this.save(); }
  }
  clearSpace(spaceId: string): void {
    for (const [key, entry] of this.entries) if (entry.spaceId === spaceId) this.entries.delete(key);
    this.save();
  }
  reconcile(spaceId: string, liveTargetIds: Iterable<string>, generation?: string): LedgerReconciliation {
    const live = new Set(liveTargetIds);
    const result: LedgerReconciliation = { active: [], stale: [] };
    let changed = false;
    for (const entry of this.list(spaceId)) {
      const active = entry.status !== 'closed' && entry.status !== 'stale' && live.has(entry.targetId)
        && (generation === undefined || entry.generation === generation);
      if (active) result.active.push(entry);
      else {
        result.stale.push(entry);
        if (entry.status !== 'stale' && entry.status !== 'closed') { entry.status = 'stale'; changed = true; }
      }
    }
    if (changed) this.save();
    return result;
  }
  private key(spaceId: string, label: string): string { return `${spaceId}\u0000${label}`; }
  private load(): void {
    if (!existsSync(this.fileURL)) return;
    let raw: unknown;
    try { raw = JSON.parse(readFileSync(this.fileURL, 'utf8')); }
    catch { throw new PeekrError(ErrorCodes.stalePage, 'Page ledger is unreadable; refusing to overwrite it.'); }
    if (!Array.isArray(raw)) throw new PeekrError(ErrorCodes.stalePage, 'Invalid page ledger.');
    for (const entry of raw) {
      if (!entry || typeof entry.spaceId !== 'string' || typeof entry.label !== 'string' || typeof entry.targetId !== 'string') {
        throw new PeekrError(ErrorCodes.stalePage, 'Invalid page ledger entry.');
      }
      this.entries.set(this.key(entry.spaceId, entry.label), entry);
    }
  }
  private save(): void {
    const temporary = `${this.fileURL}.tmp-${process.pid}`;
    writeFileSync(temporary, JSON.stringify([...this.entries.values()], null, 2) + '\n', { mode: 0o600 });
    chmodSync(temporary, 0o600);
    renameSync(temporary, this.fileURL);
  }
}
export function pageLedgerFileURL(discovery: string): string { return join(dirname(discovery), 'page-ledger.json'); }
