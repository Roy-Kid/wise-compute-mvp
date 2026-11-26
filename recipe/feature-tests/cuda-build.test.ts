import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const helper = fileURLToPath(new URL("../applications/src/lammps/lammps-cuda.sh", import.meta.url));

test("LAMMPS caps concurrent NVCC processes and respects smaller builders", () => {
  const jobs = (available: number) => execFileSync("sh", ["-eu", "-c",
    '. "$1"; available=$2; wise_build_jobs() { printf "%s\n" "$available"; }; lammps_cuda_build_jobs',
    "sh", helper, String(available)], { encoding: "utf8" }).trim();
  assert.equal(jobs(32), "12");
  assert.equal(jobs(4), "4");
});

test("the CUDA preflight diagnoses an exhausted Linux file table", t => {
  const dir = mkdtempSync(join(tmpdir(), "wise-cuda-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, "file-nr");
  const check = (contents: string) => {
    writeFileSync(file, contents);
    return spawnSync("sh", ["-eu", "-c", '. "$1"; lammps_cuda_file_table_available "$2"',
      "sh", helper, file], { encoding: "utf8" });
  };
  assert.equal(check("99 0 100\n").status, 0);
  assert.equal(check("100 1 100\n").status, 0);
  const exhausted = check("100 0 100\n");
  assert.equal(exhausted.status, 1);
  assert.match(exhausted.stderr, /system file table is full/);
});

test("the CUDA preflight reports a missing compatibility driver before compilation", t => {
  const root = mkdtempSync(join(tmpdir(), "wise-cuda-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const result = spawnSync("sh", ["-eu", "-c", '. "$1"; lammps_cuda_link_flags', "sh", helper],
    { encoding: "utf8", env: { ...process.env, CUDA_HOME: root } });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /compatibility driver is missing/);
});
