import assert from "node:assert/strict";
import { cpSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";
import { checkStack } from "../src/check.ts";

const recipe = join(import.meta.dirname, "../../recipe");

/** A copy of the recipe's Features with one file of one Feature rewritten. */
function changed(feature: string, file: string, edit: (text: string) => string): string {
  const root = mkdtempSync(join(tmpdir(), "wise-check-"));
  for (const collection of readdirSync(recipe)) {
    try { cpSync(join(recipe, collection, "src"), join(root, collection, "src"), { recursive: true }); } catch { /* not a collection */ }
  }
  const [collection, id] = feature.split("/");
  const path = join(root, collection, "src", id, file);
  const text = readFileSync(path, "utf8");
  const edited = edit(text);
  assert.notEqual(edited, text, "the edit changed nothing");
  writeFileSync(path, edited);
  return root;
}
const script = (feature: string, edit: (text: string) => string) => changed(feature, "install.sh", edit);
const meta = (feature: string, edit: (json: Record<string, any>) => void) =>
  changed(feature, "devcontainer-feature.json", text => { const json = JSON.parse(text); edit(json); return JSON.stringify(json, null, 2); });
const rules = (stack: string, feature: string) => checkStack(stack).filter(item => item.feature === feature).map(item => item.rule);
const after = "wise_sdk 4\n";

describe("feature check", () => {
  test("the recipe keeps the contract", () => {
    assert.deepEqual(checkStack(recipe), []);
  });

  test("C1: the script declares its SDK right after loading it and ends with wise_done", () => {
    assert.deepEqual(rules(script("applications/xtb", text => text.replace(after, "")), "applications/xtb"), ["C1"]);
    assert.deepEqual(rules(script("applications/xtb", text => text.replace("wise_id=xtb", "wise_id=other")), "applications/xtb"), ["C1"]);
    assert.deepEqual(rules(script("applications/xtb", text => text.replace(/wise_done\n$/, "wise_done\necho later\n")), "applications/xtb"), ["C1"]);
  });

  test("C2: the declared SDK exists and covers the functions the script uses", () => {
    assert.deepEqual(rules(script("applications/xtb", text => text.replace(after, "wise_sdk 5\n")), "applications/xtb"), ["C2"]);
    // gromacs asks wise_mpi, a function of SDK 4.
    assert.deepEqual(rules(script("applications/gromacs", text => text.replace(after, "wise_sdk 3\n")), "applications/gromacs"), ["C2"]);
    assert.deepEqual(rules(script("applications/xtb", text => text.replace(after, `${after}wise_unknown thing\n`)), "applications/xtb"), ["C2"]);
  });

  test("C3: a queried Feature is in installsAfter and not in dependsOn", () => {
    const unordered = meta("applications/kim", json => {
      json.installsAfter = json.installsAfter.filter((reference: string) => !reference.includes("/materials-python:"));
    });
    const [finding] = checkStack(unordered);
    assert.deepEqual([finding.feature, finding.rule], ["applications/kim", "C3"]);
    assert.match(finding.message, /asks for materials-python without naming it in installsAfter/);
    assert.deepEqual(rules(script("applications/gromacs", text => text.replace(after, `${after}wise_require fftw\n`)), "applications/gromacs"), ["C3"]);
  });

  test("C4: every provider of a queried capability is ordered before the script", () => {
    const unordered = meta("applications/gromacs", json => {
      json.installsAfter = json.installsAfter.filter((reference: string) => !reference.includes("/mpich:"));
    });
    assert.deepEqual(rules(unordered, "applications/gromacs"), ["C4"]);
  });

  test("C5: queries name a Feature or capability of the recipe literally", () => {
    assert.deepEqual(rules(script("applications/xtb", text => text.replace(after, `${after}wise_has "$feature" || true\n`)), "applications/xtb"), ["C5"]);
    assert.deepEqual(rules(script("applications/xtb", text => text.replace(after, `${after}wise_has nowhere || true\n`)), "applications/xtb"), ["C5"]);
    assert.deepEqual(rules(script("applications/xtb", text => text.replace(after, `${after}wise_require_capability nothing\n`)), "applications/xtb"), ["C5"]);
  });

  test("C6: only the SDK reads the registry", () => {
    const direct = script("applications/xtb", text => text.replace(after, `${after}test -e /usr/local/share/devcontainer-features/python || true\n`));
    assert.deepEqual(rules(direct, "applications/xtb"), ["C6"]);
  });

  test("C7: references resolve at a matching version and form no cycle", () => {
    assert.deepEqual(rules(meta("applications/xtb", json => { json.installsAfter = [...json.installsAfter, "harbor.will/wise/wise-compute-features/infra/nowhere:1"]; }),
      "applications/xtb"), ["C7"]);
    assert.deepEqual(rules(meta("applications/xtb", json => {
      json.dependsOn = { ...json.dependsOn, "harbor.will/wise/wise-compute-features/infra/core:9": {} };
    }), "applications/xtb"), ["C7"]);
    const cycle = meta("infra/core", json => { json.installsAfter = ["harbor.will/wise/wise-compute-features/applications/xtb:1"]; });
    assert.ok(checkStack(cycle).some(item => item.rule === "C7" && /cycle/.test(item.message)));
  });
});
