#!/usr/bin/env node
import { finishRound, stopRound } from './round.js';
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
import { runInstall } from "./install.js";
import { skillFiles } from "./skill-assets.js";
import { state } from "./state.js";
import { PublicApiValidationError, renderApiHelp, withApiValidation } from "./public-api-schema.js";

const USAGE = `peekr — drive Peekr's browser from any AI agent

Usage:
  peekr nodejs <<'EOF'
  const task = await taskSpace('research tokens')
  const page = task.page('p1')
  await page.goto('https://example.com')
  cliLog(await page.snapshot())
  EOF

  peekr doctor      check agent.json, CDP endpoint and control API
  peekr install     register peekr on PATH and install the skill for agent CLIs
                    [--target claude|codex|all] [--scope user|project] [--no-path]
  peekr help [topic] show this message or an API topic

Helpers (available as bare identifiers inside the heredoc):
  pages     taskSpace → page(label), pages(), handOff(), finish({keep})
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
  - Page handles restore refs across rounds only for the same document.
    Re-snapshot after navigation or DOM changes.
  - Native Agent Access is required. One CLI round owns the browser at a time.
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

const peekr = withApiValidation({ ...helpers } as Record<string, unknown>);
const ego = Object.freeze({ helpers: peekr });

async function runNodejs(sourceOverride?: string, jsonOutput = false): Promise<number> {
  const source = sourceOverride ?? await readStdin();
  if (!source.trim()) {
    process.stderr.write(`${USAGE}\n`);
    return 2;
  }
  const output: string[] = [];
  const roundHelpers = {
    ...helpers,
    cliLog: (value: unknown): void => {
      output.push(`${typeof value === "string" ? value : JSON.stringify(value, null, 2)}\n`);
    },
  };
  const validatedHelpers = withApiValidation(roundHelpers as Record<string, unknown>);
  const roundPeekr = validatedHelpers;
  const roundEgo = Object.freeze({ helpers: roundPeekr });
  const roundConsole = {
    log: (...values: unknown[]) => output.push(`${values.map((value) => typeof value === "string" ? value : JSON.stringify(value, null, 2)).join(" ")}\n`),
    error: (...values: unknown[]) => process.stderr.write(`${values.join(" ")}\n`),
    warn: (...values: unknown[]) => process.stderr.write(`${values.join(" ")}\n`),
  };
  let interrupted = false;
  const onInterrupt = () => {
    interrupted = true;
    stopRound();
    for (const socket of state.sockets.values()) socket.close();
    process.stderr.write(JSON.stringify({ ok: false, code: 'PEEKR_INTERRUPTED', hard_stop: false, message: 'Script interrupted. In-flight effects may be unknown; no action was replayed.' }) + '\n');
    process.exit(130);
  };
  process.once("SIGINT", onInterrupt);
  const names = [...helperNames(), "peekr", "ego", "console"];
  const values = [
    ...names.slice(0, -3).map((name) => validatedHelpers[name]),
    roundPeekr,
    roundEgo,
    roundConsole,
  ];
  let run: (...args: unknown[]) => Promise<unknown>;
  try {
    run = new AsyncFunction(...names, source) as (...args: unknown[]) => Promise<unknown>;
  } catch (err) {
    process.removeListener("SIGINT", onInterrupt);
    process.stderr.write(`${JSON.stringify({
      ok: false,
      code: "PEEKR_SCRIPT_SYNTAX_ERROR",
      message: err instanceof Error ? err.message : String(err),
      hard_stop: false,
    }, null, 2)}\n`);
    return 1;
  }
  try {
    await run(...values);
    await finishRound();
    if (interrupted) {
      process.stderr.write(JSON.stringify({ ok: false, code: "PEEKR_INTERRUPTED", message: "Script interrupted.", hard_stop: false }) + "\n");
      return 130;
    }
    if (jsonOutput) process.stdout.write(JSON.stringify({ ok: true, output: output.join("") }) + "\n");
    else process.stdout.write(output.join(""));
    return 0;
  } catch (err) {
    if (err instanceof PeekrError) {
      process.stderr.write(`${JSON.stringify(err.toJSON(), null, 2)}\n`);
    } else {
      process.stderr.write(`${JSON.stringify({
        ok: false,
        code: err instanceof PublicApiValidationError ? err.code : "PEEKR_ACTION_FAILED",
        message: err instanceof Error ? err.message : String(err),
        hard_stop: false,
      }, null, 2)}\n`);
    }
    return 1;
  } finally {
    process.removeListener("SIGINT", onInterrupt);
    for (const socket of state.sockets.values()) socket.close();
    stopRound();
  }
}

async function runDoctor(): Promise<number> {
  const report: Record<string, unknown> = { discoveryFile: discoveryFileURL() };
  try {
    const discovery = loadDiscovery();
    const { token: _token, ...safeDiscovery } = discovery;
    report.discovery = safeDiscovery;
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

function runOnboarding(): number {
  process.stdout.write([
    "Peekr Agent Access onboarding",
    "1. Open Peekr → Preferences → Browser → Agent Access.",
    "2. Enable Agent Access and relaunch Peekr.",
    "3. Run `peekr doctor`, then pipe a script to `peekr`.",
    "",
  ].join("\n"));
  return 0;
}

function runImport(args: string[]): number {
  if (args[0] === "list") {
    process.stdout.write(JSON.stringify({ ok: true, browsers: ["chrome"] }, null, 2) + "\n");
    return 0;
  }
  const browserIndex = args.indexOf("--browser");
  const browser = browserIndex >= 0 ? args[browserIndex + 1] : undefined;
  if (!browser) {
    process.stderr.write("Usage: peekr import list | peekr import --browser <browser> [--profile <name>]\n");
    return 2;
  }
  if (browser !== "chrome") {
    process.stderr.write(`Unsupported browser: ${browser}\n`);
    return 2;
  }
  process.stdout.write(JSON.stringify({
    ok: false,
    code: "PEEKR_IMPORT_REQUIRES_DESKTOP",
    message: "Chrome import is initiated from Peekr's desktop UI.",
  }, null, 2) + "\n");
  return 1;
}

function runUpgrade(): number {
  process.stdout.write(JSON.stringify({
    ok: false,
    code: "PEEKR_UPGRADE_NOT_CONFIGURED",
    message: "This checkout has no remote self-updater; install a newer Peekr bundle to upgrade.",
  }, null, 2) + "\n");
  return 1;
}

function parseNodejsSource(args: string[]): { source?: string; jsonOutput?: boolean; error?: string } {
  const jsonOutput = args.includes("--json");
  const normalized = args.filter((arg) => arg !== "--json");
  if (normalized.length === 0) return { jsonOutput };
  if (normalized[0] !== "-e" && normalized[0] !== "--eval") {
    return { error: "Usage: peekr nodejs [-e <script>]" };
  }
  if (!normalized[1]) return { error: "Missing script after -e" };
  if (normalized.length > 2) return { error: "Unexpected arguments after -e script" };
  return { source: normalized[1], jsonOutput };
}

export async function main(argv: string[] = process.argv.slice(2)): Promise<number> {
  if (argv[0] === "--json") return main(["nodejs", "--json", ...argv.slice(1)]);
  const command = argv[0];
  if (!command) {
    return process.stdin.isTTY ? 0 : runNodejs();
  }
  switch (command) {
    case "nodejs": {
      const parsed = parseNodejsSource(argv.slice(1));
      if (parsed.error) {
        process.stderr.write(`${parsed.error}\n`);
        return 2;
      }
      return runNodejs(parsed.source, parsed.jsonOutput);
    }
    case "doctor":
      return runDoctor();
    case "install":
      return runInstall(argv.slice(1));
    case "-v":
    case "--version":
      console.log(JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version);
      return 0;
    case "onboarding":
      return runOnboarding();
    case "import":
      return runImport(argv.slice(1));
    case "upgrade":
      return runUpgrade();
    case "help": {
      const topic = argv[1];
      process.stdout.write(topic ? renderApiHelp(topic) : USAGE);
      return 0;
    }
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
export { helperNames, helpers, peekr, ego, PeekrError, ErrorCodes, discoveryFileURL, loadDiscovery, state };
export { buildLocator, SnapshotRenderer } from "./driver/observe.js";
export { resetRefs } from "./state.js";
export { resolveRef } from "./ref-map.js";
export { skillFiles } from "./skill-assets.js";
export { PUBLIC_API_SCHEMA, renderApiHelp, validateApiCall } from "./public-api-schema.js";
export { TaskSpace, Page } from './page-model.js';
export { parseChord } from './driver/key-chords.js';
export { TargetSocket } from './cdp.js';
export { acquireLease, releaseLease, generationOf } from './round.js';
export { PageLedgerStore, pageLedgerFileURL } from "./page-ledger.js";

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main();
}
