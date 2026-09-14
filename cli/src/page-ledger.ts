import { chmodSync, existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

export interface PageLedgerEntry {
  spaceId: string;
  label: string;
  targetId: string;
  url?: string;
  title?: string;
  updatedAt: string;
}

export interface LedgerReconciliation {
  active: PageLedgerEntry[];
  stale: PageLedgerEntry[];
}

/** Durable Page identity store. Target IDs are transport handles; labels are the API identity. */
export class PageLedgerStore {
  private entries = new Map<string, PageLedgerEntry>();

  constructor(readonly fileURL: string) {
    this.load();
  }

  list(spaceId?: string): PageLedgerEntry[] {
    return [...this.entries.values()].filter((entry) => !spaceId || entry.spaceId === spaceId);
  }

  resolve(spaceId: string, label: string): PageLedgerEntry | undefined {
    return this.entries.get(this.key(spaceId, label));
  }

  bind(spaceId: string, label: string, targetId: string, metadata: Pick<PageLedgerEntry, "url" | "title"> = {}): PageLedgerEntry {
    const entry: PageLedgerEntry = {
      spaceId, label, targetId, ...metadata, updatedAt: new Date().toISOString(),
    };
    this.entries.set(this.key(spaceId, label), entry);
    this.save();
    return entry;
  }

  unbind(spaceId: string, label: string): void {
    this.entries.delete(this.key(spaceId, label));
    this.save();
  }

  reconcile(spaceId: string, liveTargetIds: Iterable<string>): LedgerReconciliation {
    const live = new Set(liveTargetIds);
    const active: PageLedgerEntry[] = [];
    const stale: PageLedgerEntry[] = [];
    for (const entry of this.list(spaceId)) {
      (live.has(entry.targetId) ? active : stale).push(entry);
    }
    return { active, stale };
  }

  private key(spaceId: string, label: string): string { return `${spaceId}\u0000${label}`; }

  private load(): void {
    if (!existsSync(this.fileURL)) return;
    try {
      const raw = JSON.parse(readFileSync(this.fileURL, "utf8"));
      if (!Array.isArray(raw)) return;
      for (const value of raw) {
        if (value && typeof value.spaceId === "string" && typeof value.label === "string" && typeof value.targetId === "string") {
          this.entries.set(this.key(value.spaceId, value.label), value as PageLedgerEntry);
        }
      }
    } catch {
      this.entries.clear();
    }
  }

  private save(): void {
    const temporary = `${this.fileURL}.tmp-${process.pid}`;
    writeFileSync(temporary, JSON.stringify([...this.entries.values()], null, 2) + "\n", { mode: 0o600 });
    chmodSync(temporary, 0o600);
    renameSync(temporary, this.fileURL);
  }
}

export function pageLedgerFileURL(discoveryFileURL: string): string {
  return join(dirname(discoveryFileURL), "page-ledger.json");
}
