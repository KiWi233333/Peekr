import { build } from "esbuild";
import { chmod, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const outfile = resolve(root, "dist/peekr.js");

await mkdir(dirname(outfile), { recursive: true });
await build({
  entryPoints: [resolve(root, "src/index.ts")],
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  outfile,
  sourcemap: "inline",
  legalComments: "inline",
  logLevel: "info",
});

// esbuild does not preserve the executable bit on its own output.
await chmod(outfile, 0o755);
