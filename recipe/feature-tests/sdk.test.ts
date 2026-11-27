// The Feature SDK of the core Feature, run in a plain shell against a registry in a temporary directory.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const core = join(import.meta.dirname, "../infra/src/core");

/** A Feature directory and an empty registry; `run` executes a script body as that Feature's install.sh. */
function image(id = "demo", version = "1.2.3") {
  const root = mkdtempSync(join(tmpdir(), "wise-sdk-"));
  const registry = join(root, "registry");
  const feature = join(root, id);
  mkdirSync(join(root, "bin"));
  mkdirSync(feature);
  // wise_done refreshes the linker cache, which needs root.
  writeFileSync(join(root, "bin/ldconfig"), "#!/bin/sh\n");
  chmodSync(join(root, "bin/ldconfig"), 0o755);
  writeFileSync(join(feature, "devcontainer-feature.json"),
    JSON.stringify({ id, version, options: { version: { type: "string", default: "9" } } }, null, 2));
  const run = (body: string, env: Record<string, string> = {}, sdk = core) => {
    writeFileSync(join(feature, "install.sh"), `#!/bin/sh\nset -eu\nwise_id=${id}\n. "$WISE_SDK_DIR/feature.sh"\n${body}\n`);
    return spawnSync("sh", ["./install.sh"], {
      cwd: feature, encoding: "utf8",
      env: { PATH: `${join(root, "bin")}:${process.env.PATH}`, WISE_REGISTRY: registry, WISE_SDK_DIR: sdk, ...env },
    });
  };
  return { root, registry, run };
}

test("wise_sdk accepts the SDK of the image and refuses a later one", () => {
  const { run } = image();
  assert.equal(run("wise_sdk 4; echo reached").stdout, "reached\n");
  const later = run("wise_sdk 99; echo reached");
  assert.equal(later.status, 1);
  assert.equal(later.stdout, "");
  assert.match(later.stderr, /demo: needs Feature SDK 99 and this image has SDK 4; install the core Feature again first/);
  assert.equal(run("wise_sdk; echo reached").status, 1);
});

test("a script for SDK 4 stops at once on an image whose SDK has no wise_sdk", () => {
  const { root, run } = image();
  const old = join(root, "sdk3");
  mkdirSync(old);
  writeFileSync(join(old, "feature.sh"), 'wise_fail() { echo "$wise_id: $*" >&2; exit 1; }\nwise_has() { false; }\n');
  // The failure this guards against: an unknown function in a condition counts as false and the script goes on.
  const silent = run("if wise_mpi; then echo with-mpi; else echo without-mpi; fi", {}, old);
  assert.equal(silent.stdout, "without-mpi\n");
  const stopped = run("wise_sdk 4\nif wise_mpi; then echo with-mpi; else echo without-mpi; fi", {}, old);
  assert.notEqual(stopped.status, 0);
  assert.equal(stopped.stdout, "");
});

test("wise_done records id, version and SDK; wise_has and wise_version read them", () => {
  const { registry, run } = image("demo", "1.2.3");
  assert.equal(run("wise_has demo && echo yes || echo no").stdout, "no\n");
  assert.equal(run("wise_sdk 4; wise_done").status, 0);
  assert.equal(readFileSync(join(registry, "demo"), "utf8"), "id=demo\nversion=1.2.3\nsdk=4\n");
  assert.equal(run("wise_has demo && wise_version demo").stdout, "1.2.3\n");
  assert.equal(run("wise_version other").status, 1);
  // The directory of capabilities is not a Feature.
  assert.equal(run("wise_has provides && echo yes || echo no").stdout, "no\n");
});

test("a Feature registered by an SDK before 4 is installed and has no version", () => {
  const { registry, run } = image();
  mkdirSync(registry);
  writeFileSync(join(registry, "old"), "");
  assert.equal(run('wise_has old && echo "[$(wise_version old)]"').stdout, "[]\n");
});

test("wise_done refuses a Feature without a version", () => {
  const { root, run } = image();
  writeFileSync(join(root, "demo/devcontainer-feature.json"), "{}");
  const result = run("wise_done");
  assert.equal(result.status, 1);
  assert.match(result.stderr, /found no version/);
});

test("conditional requirements", () => {
  const { registry, run } = image();
  mkdirSync(registry);
  writeFileSync(join(registry, "elpa"), "id=elpa\nversion=2.0.0\nsdk=4\n");
  assert.equal(run("wise_require_if true elpa; wise_require_if false hdf5; echo ok").stdout, "ok\n");
  const missing = run('wise_require_if true hdf5 "hdf5=true"; echo ok');
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /demo: needs the hdf5 Feature \(hdf5=true\); add it to the delivery/);
});

test("a capability has one provider: a Feature or the base image", () => {
  const { registry, run } = image("openmpi");
  assert.equal(run("wise_mpi && echo yes || echo no").stdout, "no\n");
  assert.equal(run("wise_require_capability mpi").status, 1);
  assert.equal(run("wise_provide mpi; wise_provider mpi; wise_mpi && echo yes").stdout, "openmpi\nyes\n");
  assert.equal(readFileSync(join(registry, "provides/mpi"), "utf8"), "openmpi\n");
  const second = run("wise_provide mpi");
  assert.equal(second.status, 1);
  assert.match(second.stderr, /mpi is already provided by openmpi; select one/);

  const base = image("mpich");
  assert.equal(base.run("wise_provider mpi; wise_mpi && echo yes", { WISE_BASE_MPI: "openmpi" }).stdout, "openmpi\nyes\n");
  assert.equal(base.run("wise_provide mpi", { WISE_BASE_MPI: "openmpi" }).status, 1);
  assert.equal(existsSync(join(base.registry, "provides/mpi")), false);
});

test("wise-features lists what the registry holds", () => {
  const { registry, run } = image("demo", "1.2.3");
  mkdirSync(registry);
  writeFileSync(join(registry, "old"), "");
  run("wise_provide thing; wise_done");
  const listed = spawnSync("sh", [join(core, "wise-features")], { encoding: "utf8", env: { PATH: process.env.PATH!, WISE_REGISTRY: registry } });
  assert.equal(listed.stdout, "demo 1.2.3\nold -\n");
});
