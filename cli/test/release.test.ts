import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";
import { Docker } from "../src/docker.ts";
import type { CommandResult, Run } from "../src/process.ts";
import { exportImages, extendImage, listFeatures, parseFeatures, recordFeatures } from "../src/release.ts";

const id = (letter: string) => "sha256:" + letter.repeat(64);
const ok = (stdout = ""): CommandResult => ({ code: 0, stdout, stderr: "" });
const inspected = (letter: string) => ok(JSON.stringify({ Id: id(letter), Os: "linux", Architecture: "amd64" }));

/** Records every process; `respond` answers by program and arguments. */
function fake(respond: (program: string, args: readonly string[]) => CommandResult) {
  const calls: string[][] = [];
  const execute: Run = async (program, args) => {
    calls.push([program, ...args]);
    return respond(program, args);
  };
  return { calls, execute, docker: new Docker(execute) };
}

describe("image extend", () => {
  test("builds the context on the source image and reports both images", async () => {
    const { calls, execute, docker } = fake((_program, args) =>
      args[0] === "image" ? inspected(args.at(-1) === "materials:cpu" ? "a" : "b") : ok());
    const result = await extendImage({
      source: "materials:cpu", context: "/recipe/compute", image: "compute:cpu", platform: "linux/amd64",
      buildArgs: { VERSION: "1.0.0", COMPUTE_TARGET: "aliyun-acs" },
    }, docker, execute);
    assert.deepEqual(calls[1], ["docker", "build", "--build-arg", "BASE_IMAGE=materials:cpu", "--platform", "linux/amd64",
      "--build-arg", "VERSION=1.0.0", "--build-arg", "COMPUTE_TARGET=aliyun-acs", "--tag", "compute:cpu", "/recipe/compute"]);
    assert.deepEqual(result, { reference: "compute:cpu", id: id("b"), platform: "linux/amd64",
      base: { reference: "materials:cpu", id: id("a"), platform: "linux/amd64" } });
  });

  test("does not build on a source that is missing or that the caller also names as an argument", async () => {
    const missing = fake(() => ({ code: 1, stdout: "", stderr: "No such image: gone" }));
    await assert.rejects(extendImage({ source: "gone", context: ".", image: "x" }, missing.docker, missing.execute), /No such image/);
    assert.equal(missing.calls.length, 1);
    const named = fake(() => inspected("a"));
    await assert.rejects(extendImage({ source: "a", context: ".", image: "x", buildArgs: { BASE_IMAGE: "b" } }, named.docker, named.execute),
      /BASE_IMAGE is the source image/);
    assert.equal(named.calls.length, 0);
  });
});

describe("feature list", () => {
  test("reads the registry with the listing program instead of the image's entry point", async () => {
    const { calls, execute, docker } = fake((_program, args) => args[0] === "image" ? inspected("a") : ok("core 3.2.0\nold -\n"));
    const listed = await listFeatures("compute:cpu", docker, execute);
    assert.deepEqual(calls[1].slice(0, 9), ["docker", "run", "--rm", "--network", "none", "--entrypoint", "sh", id("a"), "-c"]);
    assert.match(calls[1][9], /exec wise-features/);
    assert.deepEqual(listed.features, { core: "3.2.0", old: null });
  });

  test("rejects output that is not a listing", () => {
    assert.throws(() => parseFeatures("core 3.2.0 extra\n"), /unexpected line/);
    assert.throws(() => parseFeatures("core\n"), /unexpected line/);
  });

  test("a release record takes the table and keeps its other fields", () => {
    const file = join(mkdtempSync(join(tmpdir(), "wise-record-")), "release.json");
    writeFileSync(file, JSON.stringify({ app: "materials-full", features: { gone: "1.0.0" } }));
    recordFeatures(file, { core: "3.2.0", lammps: "3.0.1" });
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), { app: "materials-full", features: { core: "3.2.0", lammps: "3.0.1" } });
    assert.throws(() => recordFeatures(file, { core: "3.2.0", old: null }), /No version is recorded for old/);
    assert.throws(() => recordFeatures(file, {}), /lists no Feature/);
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")).features, { core: "3.2.0", lammps: "3.0.1" });
  });
});

describe("image export", () => {
  /** docker writes the tar it is asked for; zstd turns it into the named archive and removes it. */
  const saving = (zstd: (args: readonly string[]) => CommandResult) => fake((program, args) => {
    if (program === "zstd") return zstd(args);
    if (args[1] === "inspect") return inspected(args.at(-1)!.includes("cpu") ? "a" : "b");
    writeFileSync(args[3], `tar of ${args[4]}`);
    return ok();
  });
  const compress = (args: readonly string[]) => {
    const tar = args[args.indexOf("--rm") + 1];
    writeFileSync(args.at(-1)!, `zstd(${readFileSync(tar, "utf8")})`);
    rmSync(tar);
    return ok();
  };

  test("writes an archive named by the tag, its checksum and one manifest", async () => {
    const directory = mkdtempSync(join(tmpdir(), "wise-export-"));
    const { calls, execute, docker } = saving(compress);
    const references = ["harbor.will/wise/image:full-cpu-1.0.0", "harbor.will/wise/image:full-cuda-1.0.0"];
    const result = await exportImages(references, directory, docker, execute, () => new Date("2026-01-02T03:04:05Z"));
    const content = "zstd(tar of harbor.will/wise/image:full-cpu-1.0.0)";
    const digest = createHash("sha256").update(content).digest("hex");
    assert.deepEqual(readdirSync(directory).sort(), ["full-cpu-1.0.0.tar.zst", "full-cpu-1.0.0.tar.zst.sha256",
      "full-cuda-1.0.0.tar.zst", "full-cuda-1.0.0.tar.zst.sha256", "manifest.json"]);
    assert.equal(readFileSync(join(directory, "full-cpu-1.0.0.tar.zst.sha256"), "utf8"), `${digest}  full-cpu-1.0.0.tar.zst\n`);
    assert.equal(statSync(join(directory, "full-cpu-1.0.0.tar.zst")).mode & 0o777, 0o644);
    assert.deepEqual(result.images[0], { reference: references[0], id: id("a"), platform: "linux/amd64",
      file: "full-cpu-1.0.0.tar.zst", bytes: content.length, sha256: digest });
    assert.deepEqual(JSON.parse(readFileSync(join(directory, "manifest.json"), "utf8")),
      { exported: "2026-01-02T03:04:05.000Z", images: result.images });
    assert.deepEqual(calls.filter(call => call[0] === "zstd")[0].slice(0, 6), ["zstd", "-T0", "-3", "--quiet", "--force", "--rm"]);
  });

  test("a failed compression leaves no archive behind", async () => {
    const directory = mkdtempSync(join(tmpdir(), "wise-export-"));
    const { execute, docker } = saving(() => ({ code: 1, stdout: "", stderr: "zstd: No space left on device" }));
    await assert.rejects(exportImages(["image:full-cpu-1.0.0"], directory, docker, execute), /No space left/);
    assert.deepEqual(readdirSync(directory), []);
  });

  test("needs distinct tags, which name the archives", async () => {
    const { calls, execute, docker } = saving(compress);
    const directory = join(mkdtempSync(join(tmpdir(), "wise-export-")), "new");
    await assert.rejects(exportImages(["image@" + id("a")], directory, docker, execute), /needs a tag/);
    await assert.rejects(exportImages(["one:v1", "two:v1"], directory, docker, execute), /share the tag v1/);
    assert.equal(calls.length, 0);
    assert.equal(existsSync(directory), false);
  });
});
