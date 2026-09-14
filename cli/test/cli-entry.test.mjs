import { deepStrictEqual, match, strictEqual } from "node:assert";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";

const root = join(fileURLToPath(new URL("..", import.meta.url)), "dist", "peekr.js");

function run(args, input) {
  const result = spawnSync(process.execPath, [root, ...args], {
    input,
    encoding: "utf8",
    env: { ...process.env, PEEKR_AGENT_DISCOVERY: "/tmp/peekr-missing-agent.json" },
  });
  return result;
}

describe("CLI entry points", () => {
  it("supports help, version, onboarding and import discovery", () => {
    const help = run(["--help"]);
    strictEqual(help.status, 0);
    match(help.stdout, /Usage:/);

    const version = run(["--version"]);
    strictEqual(version.status, 0);
    match(version.stdout, /^0\.1\.0\n$/);

    const onboarding = run(["onboarding"]);
    strictEqual(onboarding.status, 0);
    match(onboarding.stdout, /Agent Access onboarding/);

    const imports = run(["import", "list"]);
    strictEqual(imports.status, 0);
    deepStrictEqual(JSON.parse(imports.stdout), { ok: true, browsers: ["chrome"] });
  });

  it("runs eval scripts and direct stdin with both namespaces", () => {
    const evalResult = run(["nodejs", "-e", "cliLog([typeof peekr, typeof ego.helpers, typeof taskSpace].join(','))"]);
    strictEqual(evalResult.status, 0);
    strictEqual(evalResult.stdout.trim(), "object,object,function");
    strictEqual(evalResult.stderr, "");

    const stdinResult = run([], "cliLog('stdin-ok')\n");
    strictEqual(stdinResult.status, 0);
    strictEqual(stdinResult.stdout.trim(), "stdin-ok");
  });

  it("returns stable usage failures", () => {
    const empty = run(["nodejs", "-e"]);
    strictEqual(empty.status, 2);
    match(empty.stderr, /Missing script after -e/);

    const unknown = run(["unknown-command"]);
    strictEqual(unknown.status, 1);
    match(unknown.stderr, /Unknown command/);

    const syntax = run(["nodejs", "-e", "{"]);
    strictEqual(syntax.status, 1);
    match(syntax.stderr, /PEEKR_SCRIPT_SYNTAX_ERROR/);
  });

  it("flushes script output only after a successful round", () => {
    const result = run(["nodejs", "-e", "console.log('first'); cliLog({ second: true })"]);
    strictEqual(result.status, 0);
    strictEqual(result.stderr, "");
    strictEqual(result.stdout, 'first\n{\n  "second": true\n}\n');
  });

  it("supports machine-readable JSON output", () => {
    const result = run(["nodejs", "--json", "-e", "cliLog({ ok: true })"]);
    strictEqual(result.status, 0);
    deepStrictEqual(JSON.parse(result.stdout), { ok: true, output: '{\n  "ok": true\n}\n' });
  });

  it("validates schema-declared options before browser transport", () => {
    const result = run(["nodejs", "-e", "await peekr.openOrReuseTab('https://example.com', { timeout: 0 })"]);
    strictEqual(result.status, 1);
    match(result.stderr, /PEEKR_INVALID_ARGUMENT/);
    match(result.stderr, /positive number/);
  });
});
