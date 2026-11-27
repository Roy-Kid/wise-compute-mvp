import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { devcontainerCli, devcontainerTempEnv } from "../cli/src/devcontainer.ts";
import { readStack, resolveLocal } from "../cli/src/features.ts";

const [variant = "cpu", target = "all", ...extra] = process.argv.slice(2);
if (!["cpu", "cuda", "smp", "cloud"].includes(variant) || extra.length) {
  throw new Error("usage: npm run test:features -- [cpu|cuda|smp|cloud] [all|scenario]");
}

const recipe = join(import.meta.dirname, "..", "recipe");
// The checks next to the examples load the repository's SDK, not the one the image was built with.
const sdkFiles = ["feature.sh", "deps.sh", "build.sh"];
const tests = join(recipe, "feature-tests", "test", "_global");
const scenarioFile = variant === "cpu" ? "scenarios.json" : `scenarios.${variant}.json`;
const scenarios = JSON.parse(readFileSync(join(tests, scenarioFile), "utf8"));
const names = Object.keys(scenarios);
if (target !== "all" && !Object.hasOwn(scenarios, target)) {
  throw new Error(`Unknown ${variant} scenario ${target}. Choose ${names.join(", ")}, or all.`);
}
// A selected scenario runs after the earlier scenarios whose Features it uses.
const plan = target === "all" ? names : names.slice(0, names.indexOf(target) + 1)
  .filter(name => Object.keys(scenarios[name].features).every(id => Object.hasOwn(scenarios[target].features, id)));
const stack = readStack(recipe);
const { script } = devcontainerCli();
const root = mkdtempSync(join(tmpdir(), "materials-feature-tests-"));
const baseImage = process.env.FEATURE_TEST_BASE_IMAGE;
const aptSnapshot = process.env.FEATURE_TEST_APT_SNAPSHOT;
const gpu = process.env.FEATURE_TEST_GPU === "1";
const proxyArgs = ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "no_proxy", "NO_PROXY"]
  .filter(name => process.env[name]).flatMap(name => ["--build-arg", name]);

try {
  for (const name of plan) {
    const scenario = scenarios[name];
    const ids = Object.keys(scenario.features);
    const project = join(root, name);
    // Features are published from several collections. The CLI test command needs one flat src/ tree.
    for (const id of ids) {
      const feature = stack.find(item => item.id === id);
      if (!feature) throw new Error(`${name} names an unknown Feature ${id}`);
      const destination = join(project, "src", id);
      cpSync(feature.dir, destination, { recursive: true });
      const path = join(destination, "devcontainer-feature.json");
      const metadata = JSON.parse(readFileSync(path, "utf8"));
      const resolve = reference => {
        const dependency = resolveLocal(stack, reference);
        if (!dependency) throw new Error(`${id} names an unknown Feature ${reference}`);
        return dependency.id;
      };
      if (metadata.dependsOn) {
        metadata.dependsOn = Object.fromEntries(Object.entries(metadata.dependsOn).map(([reference, options]) => {
          const dependency = resolve(reference);
          if (!Object.hasOwn(scenario.features, dependency)) throw new Error(`${name} needs ${dependency} for ${id}`);
          return [`./${dependency}`, options];
        }));
      }
      if (metadata.installsAfter) {
        metadata.installsAfter = metadata.installsAfter.map(resolve)
          .filter(id => Object.hasOwn(scenario.features, id)).map(id => `./${id}`);
      }
      writeFileSync(path, JSON.stringify(metadata, null, 2) + "\n");
    }
    const global = join(project, "test", "_global");
    mkdirSync(global, { recursive: true });
    const base = variant === "cuda" ? "cuda" : "cpu";
    cpSync(join(recipe, "base", base, ".devcontainer"), join(global, name), {
      recursive: true, filter: source => basename(source) !== "devcontainer.json",
    });
    cpSync(join(tests, "examples"), join(global, "examples"), { recursive: true });
    cpSync(join(recipe, "delivery/selftest"), join(global, "examples/selftest"), { recursive: true });
    mkdirSync(join(global, "examples/sdk"));
    for (const file of sdkFiles) cpSync(join(recipe, "infra/src/core", file), join(global, "examples/sdk", file));
    if (variant === "cuda") {
      cpSync(join(recipe, "applications/src/lammps/lammps-cuda.sh"), join(global, "examples/lammps-cuda.sh"));
    }
    cpSync(join(tests, `${name}.sh`), join(global, `${name}.sh`));
    if (baseImage) scenario.build.args = { ...scenario.build.args, BASE_IMAGE: baseImage };
    if (aptSnapshot !== undefined) scenario.build.args = { ...scenario.build.args, APT_SNAPSHOT: aptSnapshot };
    if (proxyArgs.length) scenario.build.options = [...(scenario.build.options ?? []), ...proxyArgs];
    if (!gpu) scenario.runArgs = scenario.runArgs.filter(arg => !arg.startsWith("--gpus="));
    scenario.remoteEnv = { ...scenario.remoteEnv, MATERIALS_TEST_FEATURES: ids.join(" "),
      MATERIALS_TEST_VARIANT: variant };
    writeFileSync(join(global, "scenarios.json"), JSON.stringify({ [name]: scenario }, null, 2) + "\n");
    execFileSync(process.execPath, [script, "features", "test", "--project-folder", project, "--global-scenarios-only"],
      { env: devcontainerTempEnv(project), stdio: "inherit" });
  }
} finally {
  rmSync(root, { recursive: true, force: true });
}
