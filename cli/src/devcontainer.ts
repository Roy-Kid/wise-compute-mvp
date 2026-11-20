import { createRequire } from "node:module";
import { dirname, join } from "node:path";

/** The pinned official Dev Container CLI that ships as a dependency of this package. */
export function devcontainerCli(): { script: string; version: string } {
  const require = createRequire(import.meta.url);
  const manifest = require.resolve("@devcontainers/cli/package.json");
  return { script: join(dirname(manifest), "devcontainer.js"), version: require(manifest).version };
}
