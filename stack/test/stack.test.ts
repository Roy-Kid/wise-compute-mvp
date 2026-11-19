import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { accessSync, constants, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import {
  devcontainer, featureIds, featuresRoot, installOrder, loadStack, readFeature, recipesRoot, renderRecipe,
} from "../src/stack.ts";

const scratch = mkdtempSync(join(tmpdir(), "wise-stack-"));
after(() => rmSync(scratch, { recursive: true, force: true }));
const stack = loadStack();
const cpuBase = stack.variants.cpu.buildArgs.BASE_IMAGE;

/** resolve-dependencies prints log lines before its JSON graph. */
function resolvedOrder(workspace: string): string[] {
  const output = devcontainer(["features", "resolve-dependencies", "--workspace-folder", workspace]);
  const graph = JSON.parse(output.slice(output.indexOf("\n{") + 1)) as { installOrder: { id: string }[] };
  return graph.installOrder.map(item => item.id);
}

describe("Feature collection", () => {
  for (const id of featureIds()) {
    test(`${id} follows the Feature contract`, () => {
      const metadata = readFeature(id);
      assert.equal(metadata.id, id);
      assert.match(metadata.version, /^\d+\.\d+\.\d+$/);
      // Install order belongs to recipes; cross-Feature references would break once published to OCI.
      assert.equal(metadata.dependsOn, undefined);
      assert.equal(metadata.installsAfter, undefined);

      const install = join(featuresRoot, "src", id, "install.sh");
      accessSync(install, constants.X_OK);
      assert.match(readFileSync(install, "utf8"), /^#!\/bin\/sh\nset -eu\n/);
      execFileSync("sh", ["-n", install]);

      const tests = join(featuresRoot, "test", id);
      const scenarioFile = join(tests, "scenarios.json");
      if (!existsSync(scenarioFile)) {
        execFileSync("sh", ["-n", join(tests, "test.sh")]);
        return;
      }
      const scenarios = JSON.parse(readFileSync(scenarioFile, "utf8")) as Record<string, { image: string }>;
      for (const [name, scenario] of Object.entries(scenarios)) {
        assert.equal(scenario.image, cpuBase, `${id}/${name} must test on the CPU base image`);
        execFileSync("sh", ["-n", join(tests, `${name}.sh`)]);
      }
    });
  }

  test("scenario prerequisites install in the declared order", () => {
    // Mirrors how `features test` lays out a scenario: each Feature copied to .devcontainer/<id>.
    for (const id of featureIds().filter(id => existsSync(join(featuresRoot, "test", id, "scenarios.json")))) {
      const scenarios = JSON.parse(readFileSync(join(featuresRoot, "test", id, "scenarios.json"), "utf8"));
      for (const [name, scenario] of Object.entries<{ features: object; overrideFeatureInstallOrder: string[] }>(scenarios)) {
        const workspace = join(scratch, "scenario", id, name);
        for (const feature of Object.keys(scenario.features)) {
          cpSync(join(featuresRoot, "src", feature), join(workspace, ".devcontainer", feature), { recursive: true });
        }
        const config = { ...scenario, features: Object.fromEntries(Object.keys(scenario.features).map(f => [`./${f}`, {}])) };
        writeFileSync(join(workspace, ".devcontainer", "devcontainer.json"), JSON.stringify(config));
        assert.deepEqual(resolvedOrder(workspace), scenario.overrideFeatureInstallOrder);
      }
    }
  });

  test("the official CLI packages the whole collection", () => {
    const output = join(scratch, "packages");
    devcontainer(["features", "package", join(featuresRoot, "src"), "--output-folder", output]);
    const collection = JSON.parse(readFileSync(join(output, "devcontainer-collection.json"), "utf8"));
    assert.deepEqual(collection.features.map((item: { id: string }) => item.id).sort(), featureIds());
  });
});

describe("recipes", () => {
  test("stack.json rejects unknown Features and unpinned images", () => {
    const bad = join(scratch, "bad.json");
    writeFileSync(bad, JSON.stringify({
      aptSnapshot: "latest",
      tiers: { compute: ["openmpi", "nope"] },
      variants: { cpu: { buildArgs: { BASE_IMAGE: "ubuntu:24.04" } } },
    }));
    assert.throws(() => loadStack(bad), (error: Error) =>
      /aptSnapshot/.test(error.message) && /unknown Feature nope/.test(error.message) &&
      /cpu.BASE_IMAGE must be pinned/.test(error.message));
  });

  test("every variant applies the apt snapshot in its Dockerfile", () => {
    for (const name of Object.keys(stack.variants)) {
      const dockerfile = readFileSync(join(recipesRoot, name, "Dockerfile"), "utf8");
      assert.match(dockerfile, /APT::Snapshot/);
      assert.match(dockerfile, /^FROM \$\{BASE_IMAGE\}$/m);
    }
  });

  for (const variant of Object.keys(stack.variants)) {
    test(`the ${variant} recipe renders to a workspace the official CLI resolves in stack order`, () => {
      const workspace = renderRecipe(stack, { variant, outDir: join(scratch, "local") });
      const config = JSON.parse(readFileSync(join(workspace, ".devcontainer", "devcontainer.json"), "utf8"));
      assert.equal(config.build.args.APT_SNAPSHOT, stack.aptSnapshot);
      assert.deepEqual(resolvedOrder(workspace), installOrder(stack).map(id => `./features/${id}`));
    });
  }

  test("a registry render references published Features by exact version", () => {
    const workspace = renderRecipe(stack, {
      variant: "cpu", outDir: join(scratch, "oci"), featureRegistry: "harbor.will/wise-compute/features",
    });
    const config = JSON.parse(readFileSync(join(workspace, ".devcontainer", "devcontainer.json"), "utf8"));
    assert.ok(Object.hasOwn(config.features, "harbor.will/wise-compute/features/openmpi:1.0.0"));
    assert.equal(config.overrideFeatureInstallOrder[0], "harbor.will/wise-compute/features/openmp");
    assert.equal(existsSync(join(workspace, ".devcontainer", "features")), false);
  });

  test("rendering replaces stale output", () => {
    const outDir = join(scratch, "stale");
    mkdirSync(join(outDir, "cpu", ".devcontainer", "features", "removed"), { recursive: true });
    renderRecipe(stack, { variant: "cpu", outDir });
    assert.deepEqual(readdirSync(join(outDir, "cpu", ".devcontainer", "features")).sort(), [...installOrder(stack)].sort());
  });
});
