import { build } from "esbuild";
import { chmod, mkdir, readdir, readFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const outfile = resolve(root, "dist/peekr.js");
const skillsDir = resolve(root, "../skills/peekr-cli");

// Embeds skills/peekr-cli/** into the bundle so `peekr install` can ship the
// skill to agent CLIs from anywhere (app bundle, PATH launcher, checkout)
// without guessing relative paths. Fails the build when the directory is
// absent — it is the single source of truth for the install command.
const skillAssetsPlugin = {
  name: "peekr-skill-assets",
  setup(buildApi) {
    buildApi.onResolve({ filter: /^peekr-skill-assets$/ }, () => ({
      path: "peekr-skill-assets",
      namespace: "peekr-skill-assets",
    }));
    buildApi.onLoad({ filter: /.*/, namespace: "peekr-skill-assets" }, async () => {
      const files = {};
      const walk = async (dir) => {
        for (const entry of await readdir(dir, { withFileTypes: true })) {
          const full = join(dir, entry.name);
          if (entry.isDirectory()) await walk(full);
          else files[relative(skillsDir, full)] = await readFile(full, "utf8");
        }
      };
      await walk(skillsDir);
      return { contents: `export default ${JSON.stringify(files)};` };
    });
  },
};

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
  plugins: [skillAssetsPlugin],
});

// esbuild does not preserve the executable bit on its own output.
await chmod(outfile, 0o755);
