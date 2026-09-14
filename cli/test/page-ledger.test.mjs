import { deepStrictEqual, strictEqual } from "node:assert";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { PageLedgerStore } from "../dist/peekr.js";

describe("page ledger", () => {
  it("persists labels independently from target ids and reconciles stale targets", () => {
    const root = mkdtempSync(join(tmpdir(), "peekr-ledger-"));
    const file = join(root, "page-ledger.json");
    try {
      const first = new PageLedgerStore(file);
      first.bind("space-1", "p1", "target-old", { url: "https://example.com", title: "Example" });
      first.bind("space-1", "p2", "target-live");
      const second = new PageLedgerStore(file);
      strictEqual(second.resolve("space-1", "p1")?.url, "https://example.com");
      const result = second.reconcile("space-1", ["target-live"]);
      deepStrictEqual(result.active.map((entry) => entry.label), ["p2"]);
      deepStrictEqual(result.stale.map((entry) => entry.label), ["p1"]);
      strictEqual(JSON.parse(readFileSync(file, "utf8")).length, 2);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
