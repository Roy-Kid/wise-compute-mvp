// Static checks for the five tiers of stack/. Building and running the images happens in CI.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { test } from "node:test";
import { devcontainerCli } from "../../cli/src/devcontainer.ts";
import { parseFeatureReference, publishOrder, readStack, stageLocalFeatures } from "../../cli/src/features.ts";

const stack = join(import.meta.dirname, "..");
const tiers = ["base", "infra", "toolchains", "applications", "delivery"] as const;
const featureTiers = ["infra", "toolchains", "applications"] as const;
const variants = ["cpu", "cuda"];

// Every Feature and delivery refers to Features by their published reference under this prefix.
const prefix = "harbor.will/willmat/wise";
const features = readStack(stack).map(feature => ({ ...feature, install: readFileSync(join(feature.dir, "install.sh"), "utf8") }));
const reference = (id: string) => {
  const feature = features.find(item => item.id === id)!;
  return `${prefix}/${feature.collection}/${id}:${feature.version.split(".")[0]}`;
};
const tierOf = (collection: string) => featureTiers.indexOf(collection as typeof featureTiers[number]);

// read-configuration resolves the Feature graph exactly as `devcontainer build` does, but first asks
// Docker for an existing container; a stub that reports none keeps the test free of Docker.
const stub = mkdtempSync(join(tmpdir(), "wise-docker-"));
writeFileSync(join(stub, "docker"), "#!/bin/sh\nexit 0\n");
chmodSync(join(stub, "docker"), 0o755);
// Resolved offline from the stack sources, the same way `wisehub image build --local-features` builds.
function installOrder(variant: string) {
  const workspace = join(stack, "delivery", variant);
  const { config, cleanup } = stageLocalFeatures(join(workspace, ".devcontainer", "devcontainer.json"), stack);
  try {
    const output = execFileSync(process.execPath, [devcontainerCli().script, "read-configuration", "--workspace-folder", workspace,
      "--config", config, "--include-features-configuration"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, PATH: `${stub}${delimiter}${process.env.PATH}` } });
    return (JSON.parse(output).featuresConfiguration.featureSets as { features: { id: string; value: Record<string, unknown> }[] }[])
      .map(set => ({ id: set.features[0].id, options: set.features[0].value }));
  } finally {
    cleanup();
  }
}
const resolved = Object.fromEntries(variants.map(variant => [variant, installOrder(variant)]));

test("stack/ has exactly the five tiers", () => {
  for (const tier of tiers) assert.ok(existsSync(join(stack, tier)), tier);
});

test("Features follow the native contract: id = directory, SemVer, strict POSIX install.sh", () => {
  // readStack already rejects an id that differs from its directory.
  assert.deepEqual([...new Set(features.map(feature => feature.collection))].sort(), [...featureTiers].sort());
  for (const feature of features) {
    assert.match(feature.version, /^\d+\.\d+\.\d+$/, feature.id);
    assert.match(feature.install, /^#!\/bin\/sh\nset -eu\n/, feature.id);
    execFileSync("sh", ["-n", join(feature.dir, "install.sh")]);
  }
  assert.equal(new Set(features.map(feature => feature.id)).size, features.length, "Feature ids are unique across tiers");
});

test("dependencies are published references that only point to the same or a lower tier", () => {
  for (const feature of features) {
    for (const ref of feature.references) {
      const target = parseFeatureReference(ref);
      assert.equal(target.prefix, prefix, `${feature.id}: ${ref}`);
      assert.equal(ref, reference(target.id), `${feature.id}: ${ref} names the tier and major version of ${target.id}`);
      assert.ok(tierOf(target.collection) <= tierOf(feature.collection),
        `${feature.collection}/${feature.id} must not depend on ${target.collection}/${target.id}`);
    }
  }
  assert.deepEqual(publishOrder(features, prefix), [...featureTiers]);
});

test("NVIDIA software comes only from the CUDA base image", () => {
  for (const feature of features) {
    assert.doesNotMatch(feature.install, /nvidia\.com|nvcr\.io|\/opt\/nvidia|\/usr\/local\/cuda|apt-get install[^\n]*(cuda|nvidia|nvhpc)/i,
      `${feature.id} must use CUDA_HOME / NVHPC_ROOT from the base image`);
  }
  for (const variant of variants) {
    assert.match(readFileSync(join(stack, "base", variant, ".devcontainer", "Dockerfile"), "utf8"), /^ARG BASE_IMAGE=\S+@sha256:[0-9a-f]{64}$/m);
  }
});

test("each delivery builds on its own base and refers to Features only by published reference", () => {
  for (const variant of variants) {
    const config = readFileSync(join(stack, "delivery", variant, ".devcontainer", "devcontainer.json"), "utf8");
    assert.match(config, new RegExp(`"dockerfile": "\\.\\./\\.\\./\\.\\./base/${variant}/\\.devcontainer/Dockerfile"`));
    const refs = [...config.matchAll(/"([^"\s]+\/[^"\s]+:[^"\s]+)": \{/g)].map(match => match[1]);
    assert.ok(refs.length > 0);
    for (const ref of refs) assert.equal(ref, reference(parseFeatureReference(ref).id), `${variant}: ${ref}`);
  }
});

test("each delivery installs one MPI, below everything that needs it, and no Feature twice", () => {
  for (const [variant, order] of Object.entries(resolved)) {
    const ids = order.map(item => item.id);
    assert.equal(new Set(ids).size, ids.length, `${variant}: a Feature is installed twice`);
    const mpi = ids.filter(id => id === "openmpi" || id === "mpich");
    assert.equal(mpi.length, 1, `${variant}: select exactly one MPI Feature`);
    const users = features.filter(f => f.references.includes(reference(mpi[0])) && ids.includes(f.id));
    assert.ok(users.length >= 5, `${variant}: the MPI users are found`);
    for (const user of users) assert.ok(ids.indexOf(mpi[0]) < ids.indexOf(user.id), `${variant}: ${mpi[0]} before ${user.id}`);
    for (const id of ["lammps", "quantum-espresso", "cp2k", "wannier90", "packmol", "numpy", "mpi4py"]) assert.ok(ids.includes(id), `${variant}: ${id}`);
  }
});

test("only the CUDA delivery requests GPU builds", () => {
  const gpu = (variant: string) => resolved[variant].filter(item => Object.values(item.options ?? {}).some(Boolean)).map(item => item.id).sort();
  assert.deepEqual(gpu("cpu"), []);
  assert.deepEqual(gpu("cuda"), ["cp2k", "lammps", "quantum-espresso"]);
});

test("every Feature is used by a delivery, except the alternative MPI", () => {
  const used = new Set(Object.values(resolved).flat().map(item => item.id));
  assert.deepEqual(features.map(feature => feature.id).filter(id => !used.has(id)), ["mpich"]);
});

test("verify.sh is valid sh", () => {
  execFileSync("sh", ["-n", join(stack, "delivery", "verify.sh")]);
});
