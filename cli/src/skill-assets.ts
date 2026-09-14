import files from "peekr-skill-assets";

/** skills/peekr-cli/** contents, embedded into the bundle at build time. */
export function skillFiles(): Record<string, string> {
  return files;
}
