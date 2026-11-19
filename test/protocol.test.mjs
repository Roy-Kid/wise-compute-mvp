import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import test from "node:test";
import { DevContainerEngine } from "../dist/engine.js";
import { OciRegistry, RegistryError } from "../dist/registry.js";

const digest = "sha256:" + "a".repeat(64);
const id = "sha256:" + "b".repeat(64);
const repository = "harbor.will/wise-compute/research";
const target = repository + ":v1";
const fixed = repository + "@" + digest;
const result = (value = "", code = 0, stderr = "") => ({
  stdout: typeof value === "string" ? value : JSON.stringify(value), stderr, code, signal: null,
});
const local = { Id: id, Os: "linux", Architecture: "amd64" };

test("native command groups are available through the CLI", () => {
  const help = group => execFileSync(process.execPath,
    ["dist/cli.js", "image", ...group, "--help"], { encoding: "utf8" });
  for (const [group, commands] of [
    [[], ["build", "up", "set-up", "run-user-commands", "exec", "outdated", "upgrade", "read-configuration"]],
    [["features"], ["test", "package", "publish", "info", "resolve-dependencies", "generate-docs"]],
    [["templates"], ["apply", "publish", "metadata", "generate-docs"]],
  ]) {
    const output = help(group);
    for (const command of commands) assert.match(output, new RegExp(group.length ? `devcontainer ${[...group, command].join(" ")}\\b` : `\\b${command}\\b`));
  }
});

test("image is the only public command group", () => {
  for (const group of ["devcontainer", "compute", "artifact"]) {
    const rejected = spawnSync(process.execPath, ["dist/cli.js", group, "--help"], { encoding: "utf8" });
    assert.equal(rejected.status, 1);
    assert.match(rejected.stderr, /Expected wisehub image/);
  }
});

test("native invocation preserves argument boundaries, TTY and status", async () => {
  const args = ["exec", "--workspace-folder", "with space", "--", "echo", "$HOME", "--literal"];
  const engine = new DevContainerEngine(async (program, forwarded, execution) => {
    assert.equal(program, process.execPath);
    assert.deepEqual(forwarded.slice(1), args);
    assert.equal(execution.inherit, true);
    return result("", 7);
  });
  assert.equal((await engine.invoke({ args })).code, 7);
});

test("structured build promotes the inspected image from a unique staging tag", async () => {
  let staging;
  const engine = new DevContainerEngine(async (program, args) => {
    if (program === process.execPath) {
      assert.equal(args[1], "build");
      assert.ok(args.includes("--frozen-lockfile"));
      staging = args[args.indexOf("--image-name") + 1];
      assert.match(staging, /^wise-build\/staging:/);
    } else if (args[1] === "inspect") {
      assert.equal(args.at(-1), staging);
      return result(local);
    } else if (args[1] === "tag") {
      assert.deepEqual(args.slice(2), [id, "research:local"]);
    } else {
      assert.deepEqual(args, ["image", "rm", staging]);
    }
    return result();
  });
  const built = await engine.build({
    workspace: ".", platform: "linux/amd64", output: { image: "research:local" },
    args: ["--frozen-lockfile"],
  });
  assert.deepEqual(built.images, [{ reference: "research:local", id, platform: "linux/amd64" }]);
});

test("push confirms the remote digest and matches the source config, then retries idempotently", async () => {
  let pushes = 0;
  const backend = new OciRegistry("harbor.will", async (_, args) => {
    if (args[0] === "image" && args[1] === "inspect") return result(local);
    if (args[1] === "tag") return result();
    if (args[1] === "push") {
      pushes++;
      assert.deepEqual(args.slice(2), ["--platform", "linux/amd64", target]);
      return result(`v1: digest: ${digest} size: 123\n`);
    }
    if (args.at(-1) === target && !pushes) return result("", 1, "manifest unknown");
    if (args.includes("--raw")) {
      assert.equal(args.at(-1), fixed);
      return result({ config: { digest: id } });
    }
    return result({ digest });
  });
  const expected = { tag: target, digest, reference: fixed };
  assert.deepEqual(await backend.push("research:local", target), expected);
  assert.deepEqual(await backend.push("research:local", target), expected);
  assert.equal(pushes, 1);
});

test("pull resolves the tag once and uses only its digest for the download", async () => {
  const calls = [];
  const backend = new OciRegistry("harbor.will", async (_, args) => {
    calls.push(args);
    if (args[0] === "buildx") return result({ digest });
    if (args[1] === "inspect") return result(local);
    return result();
  });
  const pulled = await backend.pull(target, "linux/amd64");
  assert.equal(calls[0].at(-1), target);
  assert.deepEqual(calls[1], ["image", "pull", "--platform", "linux/amd64", fixed]);
  assert.equal(pulled.reference, fixed);
  assert.equal(pulled.image.id, id);
});

test("download rejects mismatched digests and classifies permission failures", async () => {
  const mismatch = new OciRegistry("harbor.will", async () => result({ digest: id }));
  await assert.rejects(mismatch.pull(fixed), error => error instanceof RegistryError && error.kind === "integrity");
  const denied = new OciRegistry("harbor.will", async () => result("", 1, "403 forbidden"));
  await assert.rejects(denied.pull(fixed), error => error instanceof RegistryError && error.kind === "permission");
});

test("multi-platform pull distinguishes the index from the selected manifest", async () => {
  const leaf = "sha256:" + "c".repeat(64);
  const backend = new OciRegistry("harbor.will", async (_, args) => {
    if (args.includes("--raw")) {
      assert.equal(args.at(-1), repository + "@" + leaf);
      return result({ config: { digest: id } });
    }
    if (args[0] === "buildx") {
      return result({ digest, manifests: [{ digest: leaf, platform: { os: "linux", architecture: "amd64" } }] });
    }
    if (args[1] === "inspect") return result(local);
    return result();
  });
  const pulled = await backend.pull(fixed, "linux/amd64");
  assert.equal(pulled.digest, digest);
  assert.equal(pulled.platformManifestDigest, leaf);
});
