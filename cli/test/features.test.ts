import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";
import { FeaturePublisher, parseFeatureReference, publishOrder, readStack, stageLocalFeatures, tagMatches } from "../src/features.ts";
import type { Run } from "../src/process.ts";

const prefix = "harbor.will/willmat/wise";

/** Writes a stack: { "collection/id": { version, dependsOn?, installsAfter? } }. */
function stack(features: Record<string, { version?: string; dependsOn?: string[]; installsAfter?: string[] }>): string {
  const root = mkdtempSync(join(tmpdir(), "wise-stack-"));
  for (const [path, meta] of Object.entries(features)) {
    const [collection, id] = path.split("/");
    const dir = join(root, collection, "src", id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "devcontainer-feature.json"), JSON.stringify({
      id, version: meta.version ?? "1.0.0",
      ...(meta.dependsOn ? { dependsOn: Object.fromEntries(meta.dependsOn.map(ref => [ref, {}])) } : {}),
      ...(meta.installsAfter ? { installsAfter: meta.installsAfter } : {}),
    }));
    writeFileSync(join(dir, "install.sh"), "#!/bin/sh\nset -eu\n");
  }
  return root;
}

describe("feature references", () => {
  test("split into prefix, collection, id and tag", () => {
    assert.deepEqual(parseFeatureReference(`${prefix}/infra/openmpi:1`),
      { prefix, collection: "infra", id: "openmpi", tag: "1" });
    assert.deepEqual(parseFeatureReference("localhost:5000/ns/apps/lammps:1.2.3").prefix, "localhost:5000/ns");
    for (const bad of ["openmpi", "./infra/openmpi", `${prefix}/infra/openmpi`, "ghcr.io/openmpi:1"]) {
      assert.throws(() => parseFeatureReference(bad), /Expected REGISTRY/, bad);
    }
  });

  test("tags match versions the way the CLI publishes them", () => {
    assert.ok(tagMatches("1", "1.4.2") && tagMatches("1.4", "1.4.2") && tagMatches("1.4.2", "1.4.2") && tagMatches("latest", "3.0.0"));
    assert.ok(!tagMatches("1", "10.0.0") && !tagMatches("1.4", "1.40.0") && !tagMatches("2", "1.4.2"));
  });
});

describe("publish order", () => {
  test("puts collections after the collections they depend on", () => {
    const root = stack({
      "applications/lammps": { dependsOn: [`${prefix}/infra/openmp:1`], installsAfter: [`${prefix}/infra/openmpi:1`] },
      "applications/numpy": { dependsOn: [`${prefix}/toolchains/python:1`] },
      "infra/openmp": {}, "infra/openmpi": { dependsOn: [`${prefix}/infra/openmp:1`] },
      "toolchains/python": {},
    });
    assert.deepEqual(publishOrder(readStack(root), prefix), ["infra", "toolchains", "applications"]);
  });

  test("rejects references outside the stack, under another prefix, at a wrong version, or in a cycle", () => {
    const cases: [Record<string, any>, RegExp][] = [
      [{ "a/x": { dependsOn: [`${prefix}/b/missing:1`] } }, /not in the stack/],
      [{ "a/x": { dependsOn: ["ghcr.io/other/b/y:1"] }, "b/y": {} }, /is not under/],
      [{ "a/x": { dependsOn: [`${prefix}/b/y:2`] }, "b/y": {} }, /does not match b\/y at version 1.0.0/],
      [{ "a/x": { dependsOn: [`${prefix}/b/y:1`] }, "b/y": { dependsOn: [`${prefix}/a/x:1`] } }, /cycle/],
    ];
    for (const [features, error] of cases) assert.throws(() => publishOrder(readStack(stack(features)), prefix), error);
  });
});

describe("local Features", () => {
  test("rewrite stack references to staged copies and leave the repository untouched", () => {
    const root = stack({ "infra/openmpi": {}, "applications/lammps": { dependsOn: [`${prefix}/infra/openmpi:1`] } });
    const devcontainer = join(root, "delivery", ".devcontainer");
    mkdirSync(devcontainer, { recursive: true });
    const config = join(devcontainer, "devcontainer.json");
    writeFileSync(config, `{
  // comments survive
  "build": { "dockerfile": "../../base/Dockerfile" },
  "features": { "${prefix}/applications/lammps:1": { "kokkosCudaArch": "AMPERE80" }, "ghcr.io/devcontainers/features/git:1": {} }
}`);
    const original = readFileSync(config, "utf8");
    const { config: staged, cleanup } = stageLocalFeatures(config, root);
    const text = readFileSync(staged, "utf8");
    const token = /"\.\/(wisehub-local-[0-9a-f-]+)\/applications\/lammps": \{ "kokkosCudaArch": "AMPERE80" \}/.exec(text)?.[1];
    assert.ok(token, text);
    assert.match(text, /\/\/ comments survive/);
    assert.match(text, /"ghcr\.io\/devcontainers\/features\/git:1"/, "foreign Features stay remote");
    assert.match(text, /"\.\.\/\.\.\/base\/Dockerfile"/, "the config stays beside the original, so relative paths hold");
    const lammps = JSON.parse(readFileSync(join(devcontainer, token, "applications", "lammps", "devcontainer-feature.json"), "utf8"));
    assert.deepEqual(Object.keys(lammps.dependsOn), [`./${token}/infra/openmpi`]);
    cleanup();
    assert.deepEqual(readdirSync(devcontainer), ["devcontainer.json"]);
    assert.equal(readFileSync(config, "utf8"), original);
  });

  test("refuse a stack reference whose tag the source version does not satisfy", () => {
    const root = stack({ "infra/openmpi": { version: "2.0.0" } });
    const config = join(root, "devcontainer.json");
    writeFileSync(config, `{ "features": { "${prefix}/infra/openmpi:1": {} } }`);
    assert.throws(() => stageLocalFeatures(config, root), /does not match infra\/openmpi at version 2.0.0/);
    assert.deepEqual(readdirSync(root).sort(), ["devcontainer.json", "infra"]);
  });
});

describe("FeaturePublisher", () => {
  test("publishes each collection to its own namespace, lowest first, and reports what the CLI published", async () => {
    const root = stack({ "infra/openmp": {}, "applications/lammps": { dependsOn: [`${prefix}/infra/openmp:1`] } });
    const calls: (readonly string[])[] = [];
    const execute: Run = async (_program, args) => {
      calls.push(args);
      const id = args.includes(join(root, "infra", "src")) ? "openmp" : "lammps";
      return { code: 0, stdout: `log line\n{"${id}":{"publishedTags":["1","1.0","1.0.0","latest"],"digest":"sha256:x"}}`, stderr: "" };
    };
    const results = await new FeaturePublisher(execute).publish(root, "harbor.will", "willmat/wise");
    assert.deepEqual(results.map(result => [result.collection, result.namespace]),
      [["infra", "willmat/wise/infra"], ["applications", "willmat/wise/applications"]]);
    assert.deepEqual(calls.map(args => args.slice(1)), [
      ["features", "publish", join(root, "infra", "src"), "--registry", "harbor.will", "--namespace", "willmat/wise/infra"],
      ["features", "publish", join(root, "applications", "src"), "--registry", "harbor.will", "--namespace", "willmat/wise/applications"],
    ]);
    assert.deepEqual(results[1].features, { lammps: { publishedTags: ["1", "1.0", "1.0.0", "latest"], digest: "sha256:x" } });
  });

  test("publishes nothing when a reference points to another registry", async () => {
    const root = stack({ "infra/openmp": {}, "applications/lammps": { dependsOn: [`${prefix}/infra/openmp:1`] } });
    let called = false;
    const execute: Run = async () => { called = true; return { code: 0, stdout: "", stderr: "" }; };
    await assert.rejects(new FeaturePublisher(execute).publish(root, "harbor.will", "willmat/other"), /is not under harbor\.will\/willmat\/other/);
    assert.equal(called, false);
  });
});
