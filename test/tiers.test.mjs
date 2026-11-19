import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const read = path => JSON.parse(readFileSync(path, "utf8"));
const native = (...args) => execFileSync(process.execPath, ["dist/cli.js", "image", ...args], {
  encoding: "utf8",
});

for (const variant of ["cpu", "cuda"]) {
  test(`the ${variant} delivery composes all three Feature tiers`, () => {
    const workspace = `stack/delivery/${variant}`;
    const base = read(`stack/base/${variant}/.devcontainer/devcontainer.json`);
    const delivery = read(`${workspace}/.devcontainer/devcontainer.json`);
    assert.equal(variant === "cpu" ? delivery.image : delivery.build.args.CUDA_RUNTIME, base.image);
    assert.match(base.image, /ubuntu24\.04@sha256:[a-f0-9]{64}$|ubuntu:24\.04@sha256:[a-f0-9]{64}$/);
    for (const name of ["python", "conda", "uv", "rust", "nodejs"]) {
      assert.ok(Object.hasOwn(delivery.features, `./toolchains/${name}`));
    }
    const output = native("features", "resolve-dependencies", "--workspace-folder", workspace);
    const graph = JSON.parse(output.slice(output.indexOf("\n{") + 1));
    const ids = graph.installOrder.map(item => item.id);
    assert.deepEqual([...ids].sort(), Object.keys(delivery.features).sort());
    for (const prerequisite of ["./toolchains/python", "./compute/openmpi"]) {
      assert.ok(ids.indexOf(prerequisite) < ids.indexOf("./applications/mpi4py"));
    }
    assert.ok(!ids.includes("./compute/mpich"));
  });
}

for (const tier of ["stack/compute", "stack/toolchains", "stack/applications"]) {
  test(`the official CLI packages the ${tier} collection`, () => {
    const workspace = mkdtempSync(join(tmpdir(), "wise-features-"));
    try {
      const source = join(tier, "src");
      const output = join(workspace, "packages");
      native("features", "package", source, "--output-folder", output);
      const collection = read(join(output, "devcontainer-collection.json"));
      assert.deepEqual(collection.features.map(item => item.id).sort(), readdirSync(source).sort());
      for (const id of readdirSync(source)) {
        execFileSync("bash", ["-n", join(source, id, "install.sh")]);
        execFileSync("bash", ["-n", join(tier, "test", id, "test.sh")]);
      }
    } finally {
      rmSync(workspace, { recursive: true, force: true });
    }
  });
}

test("the five-tier layout replaces the legacy project layout", () => {
  for (const old of ["features", "images", ".devcontainer", "wisehub.py", "run_job.sh"]) {
    assert.equal(existsSync(old), false, old);
  }
});
