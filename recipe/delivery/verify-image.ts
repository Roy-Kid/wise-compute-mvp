import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parse } from "jsonc-parser";
import { devcontainerCli, devcontainerTempEnv } from "../../cli/src/devcontainer.ts";
import { parseFeatureReference } from "../../cli/src/features.ts";

/** Runs the full-image scenario on an already built image. */
export function verifyImage(image: string, variant: string): void {
  if (!["cpu", "cuda", "smp"].includes(variant)) throw new Error(`Unknown delivery variant: ${variant}`);
  const recipe = new URL(`./${variant}/.devcontainer/devcontainer.json`, import.meta.url);
  const { features } = parse(readFileSync(recipe, "utf8"));
  const ids = Object.keys(features).map(reference => parseFeatureReference(reference).id);
  const gpu = variant === "cuda" && process.env.FEATURE_TEST_GPU === "1";
  const runArgs = ["--network=none", "--shm-size=2g", "--tmpfs=/tmp:exec,mode=1777"];
  if (gpu) runArgs.push("--gpus=1");
  const scenario = {
    image,
    features: {},
    containerUser: "nobody",
    remoteUser: "nobody",
    updateRemoteUserUID: false,
    userEnvProbe: "none",
    runArgs,
    remoteEnv: {
      MATERIALS_TEST_FEATURES: ids.join(" "),
      MATERIALS_TEST_VARIANT: variant,
    },
  };
  const fixtures = new URL("../feature-tests/test/_global/", import.meta.url);
  const project = mkdtempSync(join(tmpdir(), "materials-delivery-test-"));
  try {
    const global = join(project, "test", "_global");
    mkdirSync(join(project, "src"));
    mkdirSync(global, { recursive: true });
    cpSync(new URL("examples", fixtures), join(global, "examples"), { recursive: true });
    cpSync(new URL("./selftest", import.meta.url), join(global, "examples/selftest"), { recursive: true });
    if (variant === "cuda") {
      cpSync(new URL("../applications/src/lammps/lammps-cuda.sh", import.meta.url), join(global, "examples/lammps-cuda.sh"));
    }
    cpSync(new URL("full.sh", fixtures), join(global, "full.sh"));
    writeFileSync(join(global, "scenarios.json"), JSON.stringify({ full: scenario }, null, 2) + "\n");
    const { script } = devcontainerCli();
    execFileSync(process.execPath, [script, "features", "test", "--global-scenarios-only", "--project-folder", project],
      { env: devcontainerTempEnv(project), stdio: "inherit" });
  } finally {
    rmSync(project, { recursive: true, force: true });
  }
}

if (import.meta.main) {
  const [variant, image, ...extra] = process.argv.slice(2);
  if (!variant || !image || extra.length) throw new Error("usage: npm run test:delivery -- cpu|cuda|smp IMAGE");
  verifyImage(image, variant);
}
