// `peekr install` — registers the CLI on PATH and ships the peekr-cli skill
// to agent CLIs (Claude Code, Codex). This is the single install path: the
// in-app button and the skill's install.sh both end up here.

import { chmodSync, existsSync, mkdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { discoveryFileURL, loadDiscovery } from "./discovery.js";
import { PeekrError } from "./errors.js";
import { skillFiles } from "./skill-assets.js";

type Target = "claude" | "codex";
type Scope = "user" | "project";

interface InstallOptions {
  targets: Target[];
  scope: Scope;
  registerPath: boolean;
}

const INSTALL_USAGE = `Usage: peekr install [--target claude|codex|all] [--scope user|project] [--no-path]

  --target   which agent CLI to ship the peekr-cli skill to (default: all)
  --scope    user = home directory, project = current directory (default: user)
  --no-path  skip registering ~/.local/bin/peekr
`;

function parseArgs(args: string[]): InstallOptions {
  const options: InstallOptions = { targets: ["claude", "codex"], scope: "user", registerPath: true };
  for (let i = 0; i < args.length; i += 1) {
    const flag = args[i];
    const value = (): string => {
      const next = args[++i];
      if (!next) throw new PeekrError("PEEKR_INSTALL_USAGE", `missing value for ${flag}`);
      return next;
    };
    switch (flag) {
      case "--target": {
        const target = value();
        if (target === "all") options.targets = ["claude", "codex"];
        else if (target === "claude" || target === "codex") options.targets = [target];
        else throw new PeekrError("PEEKR_INSTALL_USAGE", `unknown target: ${target}`);
        break;
      }
      case "--scope": {
        const scope = value();
        if (scope !== "user" && scope !== "project") {
          throw new PeekrError("PEEKR_INSTALL_USAGE", `unknown scope: ${scope}`);
        }
        options.scope = scope;
        break;
      }
      case "--no-path":
        options.registerPath = false;
        break;
      default:
        throw new PeekrError("PEEKR_INSTALL_USAGE", `unknown flag: ${flag}`);
    }
  }
  return options;
}

/** Home directory, overridable for tests; never documented for end users. */
function homeRoot(): string {
  return process.env.PEEKR_INSTALL_ROOT ?? homedir();
}

/** Writes a fresh launcher for the currently-running bundle onto PATH. */
function registerOnPath(): { launcher: string; onPath: boolean } {
  const bundlePath = realpathSync(process.argv[1]);
  const binDir = join(homeRoot(), ".local", "bin");
  mkdirSync(binDir, { recursive: true });
  const launcher = join(binDir, "peekr");
  writeFileSync(
    launcher,
    `#!/bin/sh\nexec /usr/bin/env node ${JSON.stringify(bundlePath)} "$@"\n`,
  );
  chmodSync(launcher, 0o755);
  const onPath = (process.env.PATH ?? "").split(delimiter).includes(binDir);
  return { launcher, onPath };
}

/** Replaces the target skill directory with the embedded files, idempotently. */
function installSkill(baseDir: string): { directory: string; files: number } {
  rmSync(baseDir, { recursive: true, force: true });
  const files = skillFiles();
  for (const [relativePath, contents] of Object.entries(files)) {
    const destination = join(baseDir, relativePath);
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, contents);
    if (relativePath.endsWith(".sh")) chmodSync(destination, 0o755);
  }
  return { directory: baseDir, files: Object.keys(files).length };
}

/** Non-fatal agent-access check; install succeeds even when Peekr is off. */
function verifyAgentAccess(): Record<string, unknown> {
  const report: Record<string, unknown> = { discoveryFile: discoveryFileURL() };
  try {
    loadDiscovery();
    report.ok = true;
  } catch (error) {
    report.ok = false;
    report.note =
      error instanceof PeekrError
        ? `${error.code}: enable Peekr → Preferences → Browser → Agent Access, then relaunch Peekr.`
        : String(error);
  }
  return report;
}

export async function runInstall(args: string[]): Promise<number> {
  if (args.includes("--help") || args.includes("-h")) {
    process.stdout.write(INSTALL_USAGE);
    return 0;
  }
  try {
    const options = parseArgs(args);
    const base = options.scope === "user" ? homeRoot() : process.cwd();
    const summary: Record<string, unknown> = { ok: true, scope: options.scope };

    if (options.registerPath) {
      if (!existsSync(process.argv[1])) {
        throw new PeekrError("PEEKR_INSTALL_USAGE", "cannot resolve the running bundle path");
      }
      const { launcher, onPath } = registerOnPath();
      summary.path = { launcher, onPath };
      if (!onPath) {
        summary.pathNote = `${dirname(launcher)} is not on PATH; add it to your shell profile.`;
      }
    }

    const installed: Record<string, unknown> = {};
    for (const target of options.targets) {
      installed[target] = installSkill(join(base, `.${target}`, "skills", "peekr-cli"));
    }
    summary.targets = installed;
    summary.agentAccess = verifyAgentAccess();

    console.log(JSON.stringify(summary, null, 2));
    return 0;
  } catch (error) {
    if (error instanceof PeekrError && error.code === "PEEKR_INSTALL_USAGE") {
      process.stderr.write(`${error.message}\n\n${INSTALL_USAGE}`);
    } else {
      console.log(JSON.stringify({
        ok: false,
        code: "PEEKR_ACTION_FAILED",
        message: error instanceof Error ? error.message : String(error),
        hard_stop: false,
      }, null, 2));
    }
    return 1;
  }
}
