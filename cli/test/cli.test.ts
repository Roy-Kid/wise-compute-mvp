import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { describe, test } from "node:test";
import { DevContainerBuilder } from "../src/build.ts";
import { Docker, RegistryError } from "../src/docker.ts";
import type { CommandResult, Run } from "../src/process.ts";
import { parseRemoteReference } from "../src/reference.ts";
import { OciRegistry } from "../src/registry.ts";

const digest = "sha256:" + "a".repeat(64);
const id = "sha256:" + "b".repeat(64);
const leaf = "sha256:" + "c".repeat(64);
const repository = "harbor.will/wise-compute/research";
const target = repository + ":v1";
const fixed = repository + "@" + digest;
const local = { Id: id, Os: "linux", Architecture: "amd64" };

const ok = (value: unknown = ""): CommandResult =>
  ({ code: 0, stdout: typeof value === "string" ? value : JSON.stringify(value), stderr: "" });
const fail = (stderr: string): CommandResult => ({ code: 1, stdout: "", stderr });

/** A fake process runner that records docker invocations and answers from `respond`. */
function fakeDocker(respond: (args: readonly string[]) => CommandResult) {
  const calls: (readonly string[])[] = [];
  const execute: Run = async (_program, args) => {
    calls.push(args);
    return respond(args);
  };
  return { calls, docker: new Docker(execute) };
}

const cli = (...args: string[]) => spawnSync(process.execPath,
  [join(import.meta.dirname, "../src/cli.ts"), ...args], { encoding: "utf8" });

describe("command line", () => {
  test("help lists the image and feature commands", () => {
    const help = cli("image", "--help");
    assert.equal(help.status, 0);
    for (const command of ["image build", "image push", "image pull", "feature publish"]) {
      assert.match(help.stdout, new RegExp(`wisehub ${command}\\b`));
    }
  });

  test("unknown commands and bad arguments are usage errors, not forwarded", () => {
    for (const args of [["image", "exec"], ["compute"], ["toString", "x"], ["image", "push", "only-one"],
      ["image", "pull", "--bogus", "x"], ["feature", "publish", "stack"], ["feature", "pack"]]) {
      const result = cli(...args);
      assert.equal(result.status, 2, args.join(" "));
      assert.match(result.stderr, /^wisehub: /);
    }
  });
});

describe("references", () => {
  test("remote references need an explicit registry host", () => {
    assert.deepEqual(parseRemoteReference(target), { repository, tag: "v1" });
    assert.deepEqual(parseRemoteReference(fixed), { repository, digest });
    assert.deepEqual(parseRemoteReference("localhost:5000/a/b:1"), { repository: "localhost:5000/a/b", tag: "1" });
    for (const bad of ["research:v1", "library/research:v1", "harbor.will/Research:v1", repository + "@sha256:short"]) {
      assert.throws(() => parseRemoteReference(bad), /Expected REGISTRY/, bad);
    }
  });
});

describe("build", () => {
  test("promotes the inspected image from a unique staging tag and forwards extra flags", async () => {
    let staging = "";
    const calls: (readonly string[])[] = [];
    const execute: Run = async (program, args) => {
      calls.push(args);
      if (program === process.execPath) {
        assert.equal(args[1], "build");
        assert.ok(args.includes("--experimental-frozen-lockfile"));
        staging = args[args.indexOf("--image-name") + 1];
        assert.match(staging, /^wise-build\/staging:/);
        return ok();
      }
      if (args[1] === "inspect") {
        assert.equal(args.at(-1), staging);
        return ok(local);
      }
      return ok();
    };
    const builder = new DevContainerBuilder(new Docker(execute), execute);
    const built = await builder.build({
      workspace: ".", platform: "linux/amd64", output: { image: "research:local" },
      args: ["--experimental-frozen-lockfile"],
    });
    assert.deepEqual(built.images, [{ reference: "research:local", id, platform: "linux/amd64" }]);
    assert.deepEqual(calls.slice(-2), [["image", "tag", id, "research:local"], ["image", "rm", staging]]);
  });

  test("selects a platform variant only when the default one differs, so older Docker can inspect", async () => {
    const inspects: (readonly string[])[] = [];
    const inspecting = (first: typeof local) => new Docker(async (_program, args) => {
      inspects.push(args);
      return ok(args.includes("--platform") ? local : first);
    });
    await inspecting(local).inspectImage("research:local", "linux/amd64");
    assert.equal(inspects.length, 1);
    assert.ok(!inspects[0].includes("--platform"));

    inspects.length = 0;
    const other = { ...local, Architecture: "arm64" };
    const image = await inspecting(other).inspectImage("research:local", "linux/amd64");
    assert.equal(image.platform, "linux/amd64");
    assert.deepEqual(inspects[1].slice(4, 6), ["--platform", "linux/amd64"]);
  });

  test("rejects flags that would bypass the structured output", async () => {
    const builder = new DevContainerBuilder(new Docker(async () => ok()), async () => ok());
    await assert.rejects(
      builder.build({ workspace: ".", output: { image: "x" }, args: ["--push=true"] }),
      /--push is set by wisehub/);
  });

  test("passes a base image override in a sibling config and cleans it up on a build failure", async t => {
    const workspace = mkdtempSync(join(tmpdir(), "wisehub-base-"));
    t.after(() => rmSync(workspace, { recursive: true, force: true }));
    const original = join(workspace, ".devcontainer.json");
    const text = `{
      // The base can change without editing the recipe.
      "build": { "dockerfile": "Dockerfile", "args": { "MODE": "debug" }, },
    }`;
    writeFileSync(original, text);
    let staged = "";
    const execute: Run = async (program, args) => {
      if (program !== process.execPath) return ok();
      staged = args[args.indexOf("--config") + 1];
      assert.equal(dirname(staged), workspace);
      assert.ok(basename(staged).startsWith("."));
      assert.deepEqual(JSON.parse(readFileSync(staged, "utf8")).build, {
        dockerfile: "Dockerfile", args: { MODE: "debug", BASE_IMAGE: fixed },
      });
      return fail("build failed");
    };
    const builder = new DevContainerBuilder(new Docker(execute), execute);
    await assert.rejects(builder.build({ workspace, baseImage: fixed, output: { image: "x" } }), /build failed/);
    assert.ok(staged);
    assert.equal(existsSync(staged), false);
    assert.equal(readFileSync(original, "utf8"), text);
  });
});

describe("push", () => {
  test("confirms the remote digest against the source config, then retries idempotently", async () => {
    let pushes = 0;
    const { docker } = fakeDocker(args => {
      if (args[1] === "inspect") return ok(local);
      if (args[1] === "tag") return ok();
      if (args[1] === "push") {
        pushes++;
        assert.deepEqual(args.slice(2), ["--platform", "linux/amd64", target]);
        return ok(`v1: digest: ${digest} size: 123\n`);
      }
      if (args.at(-1) === target && !pushes) return fail("manifest unknown");
      if (args.includes("--raw")) {
        assert.equal(args.at(-1), fixed);
        return ok({ config: { digest: id } });
      }
      return ok({ digest });
    });
    const registry = new OciRegistry(docker);
    const expected = { tag: target, digest, reference: fixed };
    assert.deepEqual(await registry.push("research:local", target, { immutable: true }), expected);
    assert.deepEqual(await registry.push("research:local", target, { immutable: true }), expected);
    assert.equal(pushes, 1);
  });

  test("an immutable publish refuses to tag or push over a different registry image", async () => {
    const { calls, docker } = fakeDocker(args => {
      if (args[0] === "image" && args[1] === "inspect") return ok(local);
      if (args.includes("--raw")) return ok({ config: { digest: leaf } });
      return ok({ digest });
    });
    await assert.rejects(new OciRegistry(docker).push("research:local", target, { immutable: true }),
      (error: unknown) => error instanceof RegistryError && error.kind === "conflict");
    assert.deepEqual(calls.filter(args => args[0] === "image").map(args => args[1]), ["inspect"]);
  });

  test("refuses a target without a tag", async () => {
    await assert.rejects(new OciRegistry(fakeDocker(() => ok()).docker).push("x", fixed), /explicit tag/);
  });

  test("reports a registry that stores a different image as an integrity failure", async () => {
    const { docker } = fakeDocker(args => {
      if (args[1] === "inspect") return ok(local);
      if (args[1] === "tag") return ok();
      if (args[1] === "push") return ok(`v1: digest: ${digest} size: 1\n`);
      if (args.includes("--raw")) return ok({ config: { digest: leaf } });
      if (args.at(-1) === target) return fail("manifest unknown");
      return ok({ digest });
    });
    await assert.rejects(new OciRegistry(docker).push("research:local", target),
      (error: unknown) => error instanceof RegistryError && error.kind === "integrity");
  });
});

describe("pull", () => {
  test("resolves a tag once and downloads only by digest", async () => {
    const { calls, docker } = fakeDocker(args => {
      if (args[0] === "buildx") return ok({ digest });
      if (args[1] === "inspect") return ok(local);
      return ok();
    });
    const pulled = await new OciRegistry(docker).pull(target, "linux/amd64");
    assert.equal(calls[0].at(-1), target);
    assert.deepEqual(calls[1], ["image", "pull", "--platform", "linux/amd64", fixed]);
    assert.equal(pulled.reference, fixed);
    assert.equal(pulled.image.id, id);
  });

  test("rejects a registry that answers with another digest", async () => {
    const { docker } = fakeDocker(() => ok({ digest: id }));
    await assert.rejects(new OciRegistry(docker).pull(fixed),
      (error: unknown) => error instanceof RegistryError && error.kind === "integrity");
  });

  test("classifies registry failures", async () => {
    for (const [stderr, kind] of [
      ["403 forbidden", "permission"],
      ["unauthorized: authentication required", "authentication"],
      ["manifest unknown", "missing"],
      ["received unexpected HTTP status: 503 Service Unavailable", "temporary"],
    ]) {
      const { docker } = fakeDocker(() => fail(stderr));
      await assert.rejects(new OciRegistry(docker).pull(fixed),
        (error: unknown) => error instanceof RegistryError && error.kind === kind, stderr);
    }
  });

  test("distinguishes a multi-platform index from the selected manifest", async () => {
    const { docker } = fakeDocker(args => {
      if (args.includes("--raw")) {
        assert.equal(args.at(-1), repository + "@" + leaf);
        return ok({ config: { digest: id } });
      }
      if (args[0] === "buildx") {
        return ok({ digest, manifests: [{ digest: leaf, platform: { os: "linux", architecture: "amd64" } }] });
      }
      if (args[1] === "inspect") return ok(local);
      return ok();
    });
    const pulled = await new OciRegistry(docker).pull(fixed, "linux/amd64");
    assert.equal(pulled.digest, digest);
    assert.equal(pulled.platformManifestDigest, leaf);
  });
});
