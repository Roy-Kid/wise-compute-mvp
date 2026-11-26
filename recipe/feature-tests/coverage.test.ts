import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { parse } from "jsonc-parser";
import { readStack, resolveLocal } from "../../cli/src/features.ts";

type Options = Record<string, string | boolean>;
type Features = Record<string, Options>;
type Scenarios = Record<string, { features: Features }>;

const variants = ["cpu", "cuda"] as const;
const stack = readStack(fileURLToPath(new URL("../", import.meta.url)));
const global = new URL("./test/_global/", import.meta.url);
const scenarios = Object.fromEntries(variants.map(variant => {
  const file = variant === "cpu" ? "scenarios.json" : "scenarios.cuda.json";
  return [variant, JSON.parse(readFileSync(new URL(file, global), "utf8")) as Scenarios];
}));

for (const variant of variants) {
  test(`${variant} scenarios start with OpenMP and exercise the delivery Feature options`, () => {
    const plan = scenarios[variant];
    assert.equal(Object.keys(plan)[0], "openmp");
    assert.deepEqual(Object.keys(plan.openmp.features), ["core", "openmp"]);
    for (const [name, scenario] of Object.entries(plan)) {
      assert.ok(existsSync(new URL(`${name}.sh`, global)), `${name} has no test script`);
      for (const id of Object.keys(scenario.features)) {
        const feature = stack.find(item => item.id === id);
        assert.ok(feature, `${name} references unknown Feature ${id}`);
        const { dependsOn = {} } = JSON.parse(readFileSync(join(feature.dir, "devcontainer-feature.json"), "utf8"));
        for (const reference of Object.keys(dependsOn)) {
          const dependency = resolveLocal(stack, reference);
          assert.ok(dependency && Object.hasOwn(scenario.features, dependency.id), `${name} needs ${reference}`);
        }
      }
    }

    const file = new URL(`../delivery/${variant}/.devcontainer/devcontainer.json`, import.meta.url);
    const { features } = parse(readFileSync(file, "utf8")) as { features: Features };
    for (const [reference, options] of Object.entries(features)) {
      const feature = resolveLocal(stack, reference);
      assert.ok(feature, `Unresolved delivery Feature ${reference}`);
      assert.ok(Object.values(plan).some(scenario => {
        const tested = scenario.features[feature.id];
        return tested && Object.entries(options).every(([key, value]) => tested[key] === value);
      }), `${variant} has no scenario for ${reference} with the delivery options`);
    }
  });
}

test("the native scenarios cover every local Feature", () => {
  const covered = new Set(Object.values(scenarios).flatMap(plan =>
    Object.values(plan).flatMap(scenario => Object.keys(scenario.features))));
  assert.deepEqual(stack.filter(feature => !covered.has(feature.id)).map(feature => feature.id), []);
});
