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
const features = readStack(stack).map(feature => {
  const meta = JSON.parse(readFileSync(join(feature.dir, "devcontainer-feature.json"), "utf8"));
  return {
    ...feature,
    install: readFileSync(join(feature.dir, "install.sh"), "utf8"),
    dependsOn: Object.keys(meta.dependsOn ?? {}) as string[],
    installsAfter: (meta.installsAfter ?? []) as string[],
    options: Object.keys(meta.options ?? {}),
  };
});
const byId = (id: string) => features.find(item => item.id === id)!;
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
type Resolved = { id: string; options: Record<string, unknown> };
// Resolved offline from the stack sources, the same way `wisehub image build --local-features` builds.
function installOrder(variant: string): Resolved[] {
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
    const users = features.filter(f => requirements(f).capabilities.includes("mpi") && ids.includes(f.id));
    assert.ok(users.length >= 5, `${variant}: the MPI users are found`);
    for (const user of users) assert.ok(ids.indexOf(mpi[0]) < ids.indexOf(user.id), `${variant}: ${mpi[0]} before ${user.id}`);
    for (const id of ["lammps", "quantum-espresso", "cp2k", "wannier90", "packmol", "numpy", "mpi4py"]) assert.ok(ids.includes(id), `${variant}: ${id}`);
  }
});

test("LAMMPS: KSPACE stays in, and only the CUDA delivery builds its KOKKOS variant", () => {
  for (const [variant, order] of Object.entries(resolved)) {
    const options = order.find(item => item.id === "lammps")!.options ?? {};
    assert.doesNotMatch(String(options.disablePackages ?? ""), /\bKSPACE\b/, variant);
    assert.equal(options.variant ?? "cpu", variant, `${variant}: lammps variant`);
  }
});

test("only the CUDA delivery requests GPU builds", () => {
  const requestsGpu = (item: Resolved) =>
    item.options?.variant === "cuda" || Boolean(item.options?.cudaCC) || Boolean(item.options?.gpuVersion);
  const gpu = (variant: string) => resolved[variant].filter(requestsGpu).map(item => item.id).sort();
  assert.deepEqual(gpu("cpu"), []);
  assert.deepEqual(gpu("cuda"), ["cp2k", "lammps", "quantum-espresso"]);
});

// lammps/install.sh is the single list of downloading packages and of the Features backing packages.
const lammps = byId("lammps");
function lammpsProviders() {
  const line = /^providers="([^"]*)"$/m.exec(byId("lammps").install)?.[1] ?? "";
  return new Map(line.split(" ").filter(Boolean).map(entry => entry.split(":") as [string, string]));
}
const providers = lammpsProviders();
const downloading = (/^downloading="([^"]*)"$/m.exec(lammps.install)?.[1] ?? "").split(" ").filter(Boolean);
/**
 * Packages a delivery asks LAMMPS for that would not build: a Feature-backed package whose Feature is
 * missing or installs too late, or a downloading package no Feature backs.
 */
function unprovided(order: Resolved[]): string[] {
  const ids = order.map(item => item.id);
  const extra = String(order.find(item => item.id === "lammps")?.options?.extraPackages ?? "").split(/[\s,]+/).filter(Boolean);
  return extra.filter(name => {
    const provider = providers.get(name);
    if (!provider) return downloading.includes(name);
    return !ids.includes(provider) || ids.indexOf(provider) > ids.indexOf("lammps");
  });
}

test("third-party LAMMPS packages come from Features installed before lammps", () => {
  assert.ok(providers.size > 0, "lammps/install.sh lists its third-party providers");
  assert.ok(downloading.includes("MBX") && downloading.includes("PLUMED"), "lammps/install.sh lists the downloading packages");
  for (const name of ["PLUMED", "H5MD", "NETCDF"]) assert.ok(providers.has(name), `${name} is backed by a Feature`);
  for (const provider of providers.values()) {
    assert.ok(features.some(feature => feature.id === provider), `${provider} is a stack Feature`);
    assert.ok(lammps.references.includes(reference(provider)), `lammps installs after ${provider}`);
  }
  for (const [variant, order] of Object.entries(resolved)) assert.deepEqual(unprovided(order), [], variant);
  // The check itself: a missing, a late and an unknown provider are all reported.
  const plumed = { variant: "cpu", extraPackages: "PLUMED, KIM, COMPRESS, H5MD" };
  assert.deepEqual(unprovided([{ id: "hdf5", options: {} }, { id: "lammps", options: plumed }]), ["PLUMED", "KIM"]);
  assert.deepEqual(unprovided([{ id: "lammps", options: plumed }, { id: "plumed", options: {} }]), ["PLUMED", "KIM", "H5MD"]);
  assert.deepEqual(unprovided([{ id: "plumed", options: {} }, { id: "lammps", options: { extraPackages: "PLUMED" } }]), []);
});

// Requirements are declared once, in install.sh, through the Feature SDK (infra/core/feature.sh):
//   wise_require FEATURE                hard: always needed
//   wise_require_if "$OPTION" FEATURE   needed when a boolean option is true
//   wise_require_capability CAP         needs whichever Feature does `wise_provide CAP`
type Requirements = { always: string[]; when: { option: string; feature: string }[]; capabilities: string[] };
function requirements(feature: typeof features[number]): Requirements {
  const sh = feature.install;
  const variable = (name: string) => new RegExp(`^${name}=\\$\\{([A-Z0-9]+):-`, "m").exec(sh)?.[1] ?? name;
  const when = [...sh.matchAll(/^wise_require_if "\$\{?([A-Za-z0-9_]+)(?::-[a-z]+\})?\}?" ([a-z0-9-]+)/gm)].map(match => {
    const env = /^[A-Z0-9_]+$/.test(match[1]) ? match[1] : variable(match[1]);
    const option = feature.options.find(name => name.toUpperCase() === env);
    assert.ok(option, `${feature.id}: wise_require_if reads ${match[1]}, which is no option`);
    return { option, feature: match[2] };
  });
  return {
    always: [...sh.matchAll(/^wise_require ([a-z0-9-]+)/gm)].map(match => match[1]),
    when,
    capabilities: [...sh.matchAll(/^wise_require_capability ([a-z0-9-]+)/gm)].map(match => match[1]),
  };
}
const providersOf = (capability: string) =>
  features.filter(feature => new RegExp(`^wise_provide ${capability}$`, "m").test(feature.install)).map(feature => feature.id);

test("every Feature uses the SDK: sources it under its own id and registers when done", () => {
  for (const feature of features) {
    if (feature.id === "core") continue;
    assert.match(feature.install, new RegExp(`^#!/bin/sh\nset -eu\n\\. /opt/wise/lib/wise/feature\\.sh ${feature.id}\n`), feature.id);
    assert.match(feature.install, /\nwise_done\n$/, `${feature.id} ends with wise_done`);
    assert.ok(feature.dependsOn.includes(reference("core")), `${feature.id} depends on core`);
    // Features ask the registry; they never probe each other's files.
    assert.doesNotMatch(feature.install, /pkg-config --exists|mpichversion\)|-[ex] \/opt\/wise\/bin\/mpi|ls [^\n]*\.so[^\n]*>\/dev\/null/, `${feature.id} probes another Feature`);
  }
});

test("declared requirements match dependsOn and installsAfter, with nothing stale", () => {
  for (const feature of features) {
    const req = requirements(feature);
    for (const id of req.always) assert.ok(feature.dependsOn.includes(reference(id)), `${feature.id}: wise_require ${id} needs dependsOn`);
    const soft = new Set([...req.when.map(item => item.feature), ...req.capabilities.flatMap(providersOf)]);
    if (feature.id === "lammps") for (const id of lammpsProviders().values()) soft.add(id);
    for (const cap of req.capabilities) assert.ok(providersOf(cap).length > 0, `${feature.id}: nothing provides ${cap}`);
    for (const id of soft) assert.ok(feature.installsAfter.includes(reference(id)), `${feature.id}: ${id} must be in installsAfter`);
    for (const ref of feature.installsAfter) {
      assert.ok(soft.has(parseFeatureReference(ref).id), `${feature.id}: installsAfter ${ref} has no wise_require_if, capability or provider`);
    }
  }
});

/** What a resolved delivery is missing: a requirement absent or installed after the Feature needing it. */
function unmet(order: Resolved[]): string[] {
  const ids = order.map(item => item.id);
  const before = (needed: string, by: string) => ids.includes(needed) && ids.indexOf(needed) < ids.indexOf(by);
  return order.flatMap(item => {
    const feature = features.find(entry => entry.id === item.id);
    if (!feature) return [];
    const req = requirements(feature);
    return [
      ...req.always.filter(id => !before(id, item.id)).map(id => `${item.id} needs ${id}`),
      ...req.when.filter(({ option, feature: id }) => item.options?.[option] === true && !before(id, item.id))
        .map(({ option, feature: id }) => `${item.id}.${option} needs ${id}`),
      ...req.capabilities.filter(cap => providersOf(cap).filter(id => before(id, item.id)).length !== 1)
        .map(cap => `${item.id} needs exactly one ${cap} provider before it`),
    ];
  });
}

test("each delivery meets every declared requirement, in install order", () => {
  for (const [variant, order] of Object.entries(resolved)) assert.deepEqual(unmet(order), [], variant);
  // The check itself.
  const cp2k = { id: "cp2k", options: { elpa: true, hdf5: false } };
  assert.deepEqual(unmet([{ id: "core", options: {} }, { id: "openmpi", options: {} }, { id: "fftw", options: {} },
    { id: "scalapack", options: {} }, cp2k]).filter(line => line.startsWith("cp2k")), ["cp2k.elpa needs elpa"]);
  assert.ok(unmet([{ id: "mpich", options: {} }, { id: "openmpi", options: {} }, { id: "fftw", options: {} }])
    .includes("fftw needs exactly one mpi provider before it"));
  assert.ok(unmet([{ id: "hdf5", options: {} }, { id: "netcdf", options: {} }]).includes("hdf5 needs exactly one mpi provider before it"));
});

test("one interconnect stack: Open MPI on UCX and libfabric, MPICH on libfabric, all on rdma-core", () => {
  const needs = (id: string) => requirements(byId(id)).always;
  assert.deepEqual(needs("openmpi").sort(), ["libfabric", "ucx"]);
  assert.deepEqual(needs("mpich"), ["libfabric"]);
  for (const id of ["ucx", "libfabric"]) assert.deepEqual(needs(id), ["rdma"], id);
  assert.deepEqual(providersOf("mpi").sort(), ["mpich", "openmpi"]);
});

test("one CPU baseline: x86-64-v3, set once by the openmp Feature", () => {
  const openmp = JSON.parse(readFileSync(join(features.find(item => item.id === "openmp")!.dir, "devcontainer-feature.json"), "utf8"));
  for (const flags of ["CFLAGS", "CXXFLAGS", "FFLAGS", "FCFLAGS"]) assert.match(openmp.containerEnv[flags], /-march=x86-64-v3\b/, flags);
  for (const feature of features) {
    assert.doesNotMatch(feature.install, /-march=(?!x86-64-v3\b)|-tp=(?!haswell\b)|--target-cpu=(?!haswell\b)/, `${feature.id} stays on the baseline`);
  }
});

test("every Feature is used by a delivery, except optional ones: the alternative MPI and third-party providers", () => {
  const used = new Set(Object.values(resolved).flat().map(item => item.id));
  const optional = new Set(["mpich", ...providers.values()]);
  assert.deepEqual(features.map(feature => feature.id).filter(id => !used.has(id) && !optional.has(id)), []);
});

test("verify.sh and benchmark.sh are valid sh", () => {
  for (const script of ["verify.sh", "benchmark.sh"]) execFileSync("sh", ["-n", join(stack, "delivery", script)]);
});
