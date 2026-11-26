import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const helper = fileURLToPath(new URL("../applications/src/quantum-espresso/qe-cuda.sh", import.meta.url));

test("Quantum ESPRESSO 7.6 configures CUDA and OpenACC for A100 and H100", () => {
  const args = execFileSync("sh", ["-eu", "-c", `
    . "$1"
    cmake() { printf '%s\\n' "$@"; }
    architectures=$(qe_cuda_architectures '80,90')
    qe_cuda_cmake "$architectures" -S /source -B /build -DQE_ENABLE_HDF5=ON
  `, "sh", helper], { encoding: "utf8" }).trim().split("\n");
  assert.deepEqual(args, ["-DQE_GPU:STRING=openacc;cuda", "-DQE_GPU_ARCHS:STRING=sm_80;sm_90",
    "-DQE_ENABLE_MPI_GPU_AWARE=ON", "-DQE_ENABLE_OPENMP=OFF", "-S", "/source", "-B", "/build", "-DQE_ENABLE_HDF5=ON"]);
});

test("Quantum ESPRESSO rejects an invalid compute capability before downloading source", () => {
  for (const architecture of ["80,", "80,abc"]) {
    const result = spawnSync("sh", ["-eu", "-c", '. "$1"; qe_cuda_architectures "$2"',
      "sh", helper, architecture]);
    assert.equal(result.status, 1, architecture);
  }
});

test("Quantum ESPRESSO emits the RTX PRO 5000 Blackwell architecture", () => {
  const architecture = execFileSync("sh", ["-eu", "-c", '. "$1"; qe_cuda_architectures 120',
    "sh", helper], { encoding: "utf8" }).trim();
  assert.equal(architecture, "sm_120");
});
