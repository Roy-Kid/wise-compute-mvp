import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { DevContainerBuilder } from "../../cli/dist/build.js";
import { Docker, RegistryError } from "../../cli/dist/docker.js";
import { OciRegistry } from "../../cli/dist/registry.js";

const [variant, mode, ...extra] = process.argv.slice(2);
if (!["cpu", "cuda"].includes(variant) || (mode !== undefined && mode !== "--publish") || extra.length) {
  throw new Error("usage: node stack/delivery/ci-image.mjs cpu|cuda [--publish]");
}

const platform = "linux/amd64";
const commit = process.env.CI_COMMIT_SHA;
const repository = process.env.MATERIALS_REPOSITORY;
const publish = mode === "--publish";
if (publish && (!repository || !/^[a-f0-9]{40}$/.test(commit ?? ""))) {
  throw new Error("Publishing needs MATERIALS_REPOSITORY and a full CI_COMMIT_SHA");
}
const target = publish ? `${repository}:materials-${variant}-${commit}` : undefined;
const docker = new Docker();
const registry = new OciRegistry(docker);

// A retried publish can reuse a completed image, even if rebuilding would produce a different digest.
let existing;
if (target) {
  try {
    existing = await registry.pull(target, platform);
  } catch (error) {
    if (!(error instanceof RegistryError && error.kind === "missing")) throw error;
  }
}

const image = existing?.reference ?? `wise-compute:materials-${variant}`;
if (!existing) {
  await new DevContainerBuilder(docker).build({
    workspace: fileURLToPath(new URL(`./${variant}/`, import.meta.url)),
    localFeatures: fileURLToPath(new URL("../", import.meta.url)),
    platform,
    output: { image },
    args: publish ? ["--label", `org.opencontainers.image.revision=${commit}`,
      "--label", `org.wise.compute.variant=${variant}`] : [],
  });
}

const info = JSON.parse(execFileSync(docker.binary, ["image", "inspect", "--format", "{{json .}}", image], { encoding: "utf8" }));
const labels = info.Config?.Labels;
if (target && (labels?.["org.opencontainers.image.revision"] !== commit || labels?.["org.wise.compute.variant"] !== variant)) {
  throw new Error(`${image} does not identify the expected commit and variant`);
}
writeFileSync("image.txt", `${info.Id} ${info.Size}\n`);

execFileSync(docker.binary, ["run", "--rm", "-i", "--user", "65534:65534", "--network", "none",
  "--tmpfs", "/tmp:mode=1777", "--shm-size=2g", "-e", "WISE_VERIFY_GPU=0", "--entrypoint", "/bin/sh",
  image, "-s", variant], {
  input: readFileSync(new URL("verify.sh", import.meta.url)),
  stdio: ["pipe", "inherit", "inherit"],
});

if (target) {
  const pushed = await registry.push(image, target, { immutable: true });
  const base = readFileSync(new URL(`../base/${variant}/.devcontainer/Dockerfile`, import.meta.url), "utf8");
  const arg = name => new RegExp(`^ARG ${name}=(\\S+)$`, "m").exec(base)[1];
  const record = {
    ...pushed,
    variant,
    commit,
    pipeline: process.env.CI_PIPELINE_URL,
    baseImage: arg("BASE_IMAGE"),
    aptSnapshot: arg("APT_SNAPSHOT"),
    imageId: info.Id,
    imageSize: info.Size,
    verify: variant === "cuda" ? "passed without GPU device run" : "passed",
    verifiedAt: new Date().toISOString(),
  };
  const output = JSON.stringify(record, null, 2);
  writeFileSync("release.json", `${output}\n`);
  console.log(output);
}
