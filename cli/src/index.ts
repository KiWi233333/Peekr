#!/usr/bin/env node
// peekr — command-line harness for AI agents to drive Peekr's Chromium pages.
//
//   peekr nodejs <<'EOF' … EOF   run a script with the helper surface
//   peekr doctor                 check discovery file, CDP and control API
//   peekr help                   usage
//
// The heredoc body runs as an async function whose parameters are the helper
// functions (snapshotText, click, useOrCreateSpace, …). Results leave the
// script only through cliLog(); failures print one structured JSON object.

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { helperNames, helpers, PeekrError, ErrorCodes } from "./driver/helpers.js";
import { discoveryFileURL, loadDiscovery } from "./discovery.js";
import { listTargetsHttp } from "./cdp.js";
import { listSpaces } from "./driver/spaces.js";
import { state } from "./state.js";

const USAGE = `peekr — drive Peekr's browser from any AI agent

Usage:
  peekr nodejs <<'EOF'
  const task = await useOrCreateSpace('research tokens')
  await openOrReuseTab('https://example.com')
  cliLog(await snapshotText())
  EOF

  peekr doctor      check agent.json, CDP endpoint and control API
  peekr help        this message

Helpers (available as bare identifiers inside the heredoc):
  spaces    useOrCreateSpace listSpaces claimSpace handOffSpace
            takeOverSpace completeSpace waitForAgentControl
  nav       listTabs openOrReuseTab switchTab closeTab gotoAndWait
            currentTab pageInfo waitForLoad
  observe   snapshotText snapshotRaw screenshot
  act       click doubleClick hover scrollBy pressKey typeText fillInput
  wait      wait waitForElement
  eval      js cdp
  output    cliLog

Notes:
  - @N refs are valid only for the most recent snapshot; re-snapshot after
    every navigation or mutation.
  - A space taken over by the user hard-stops every browser operation.
`;

async function readStdin(): Promise<string> {
  return new Promise((resolvePromise, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => (data += chunk));
    process.stdin.on("end", () => resolvePromise(data));
    process.stdin.on("error", reject);
  });
}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

async function runNodejs(): Promise<number> {
  const source = await readStdin();
  if (!source.trim()) {
    process.stderr.write(USAGE);
    return 1;
  }
  const names = helperNames();
  const values = names.map((name) => (helpers as Record<string, unknown>)[name]);
  const run = new AsyncFunction(...names, source);
  try {
    await run(...values);
    return 0;
  } catch (err) {
    if (err instanceof PeekrError) {
      console.log(JSON.stringify(err.toJSON(), null, 2));
    } else {
      console.log(JSON.stringify({
        ok: false,
        code: "PEEKR_ACTION_FAILED",
        message: err instanceof Error ? err.message : String(err),
        hard_stop: false,
      }, null, 2));
    }
    return 1;
  } finally {
    for (const socket of state.sockets.values()) socket.close();
    state.browser?.close();
  }
}

async function runDoctor(): Promise<number> {
  const report: Record<string, unknown> = { discoveryFile: discoveryFileURL() };
  try {
    const discovery = loadDiscovery();
    report.discovery = discovery;
    const targets = await listTargetsHttp(discovery.port);
    report.cdp = {
      reachable: true,
      pages: targets
        .filter((target) => target.type === "page")
        .map((target) => ({ title: target.title, url: target.url })),
    };
    if (discovery.controlPort) {
      const spaces = await listSpaces();
      report.control = { reachable: true, spaces: spaces.length };
    } else {
      report.control = { reachable: false, note: "control API absent in this Peekr build" };
    }
    report.ok = true;
  } catch (err) {
    report.ok = false;
    report.error = err instanceof PeekrError ? err.toJSON() : String(err);
  }
  console.log(JSON.stringify(report, null, 2));
  return report.ok ? 0 : 1;
}

async function main(): Promise<number> {
  const command = process.argv[2] ?? "help";
  switch (command) {
    case "nodejs":
      return runNodejs();
    case "doctor":
      return runDoctor();
    case "-v":
    case "--version":
      console.log(JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version);
      return 0;
    case "help":
    case "--help":
    case "-h":
      process.stdout.write(USAGE);
      return 0;
    default:
      process.stderr.write(`Unknown command: ${command}\n\n${USAGE}`);
      return 1;
  }
}

// Importable for tests; side effects (CLI run) only when executed directly.
export { helperNames, helpers, PeekrError, ErrorCodes, discoveryFileURL, loadDiscovery, state };
export { buildLocator, SnapshotRenderer } from "./driver/observe.js";
export { resetRefs } from "./state.js";
export { resolveRef } from "./ref-map.js";

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main();
}
