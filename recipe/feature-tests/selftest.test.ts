import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const selftest = fileURLToPath(new URL("../delivery/selftest/materials-selftest", import.meta.url));
const run = (...args: string[]) => spawnSync("sh", [selftest, ...args], { encoding: "utf8" });

test("materials-selftest lists a test for every program of the delivery", () => {
  const names = run("--list").stdout.trim().split("\n");
  for (const name of ["gpu", "lammps", "quantum-espresso", "cp2k", "wannier90", "packmol", "multiwfn", "python"]) {
    assert.ok(names.includes(name), `no ${name} test`);
  }
});

test("materials-selftest rejects an unknown test", () => {
  assert.equal(run("nothing").status, 2);
});

test("materials-selftest skips what is not installed and reports the counts", () => {
  const work = mkdtempSync(join(tmpdir(), "selftest-"));
  try {
    const json = join(work, "result.json");
    // No machine that runs these unit tests has a program of this name.
    const result = spawnSync("sh", [selftest, "--logs", work, "--json", json, "cp2k"], {
      encoding: "utf8", env: { PATH: "/usr/bin:/bin", HOME: work },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /^\[SKIP\] cp2k +cp2k\.psmp or cp2k\.ssmp is not installed$/m);
    assert.match(result.stdout, /^passed 0 of 0 \(0%\), failed 0, skipped 1;/m);
    assert.deepEqual(JSON.parse(readFileSync(json, "utf8")).results,
      [{ name: "cp2k", status: "skip", seconds: 0, detail: "cp2k.psmp or cp2k.ssmp is not installed" }]);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
