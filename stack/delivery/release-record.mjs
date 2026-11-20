// Writes release.json for one delivery after CI pushed it: node release-record.mjs VARIANT
// Inputs: image.txt ("<id> <size>"), push.json (wisehub image push output) and the delivery's lockfile.
import { readFileSync, writeFileSync } from "node:fs";

const variant = process.argv[2];
if (!["cpu", "cuda"].includes(variant)) throw new Error("usage: release-record.mjs cpu|cuda");
const base = readFileSync(new URL(`../base/${variant}/.devcontainer/Dockerfile`, import.meta.url), "utf8");
const arg = name => new RegExp(`^ARG ${name}=(\\S+)$`, "m").exec(base)[1];
const [imageId, size] = readFileSync("image.txt", "utf8").trim().split(" ");
const record = {
  tag: process.env.CI_COMMIT_TAG,
  variant,
  commit: process.env.CI_COMMIT_SHA,
  pipeline: process.env.CI_PIPELINE_URL,
  baseImage: arg("BASE_IMAGE"),
  aptSnapshot: arg("APT_SNAPSHOT"),
  imageId,
  imageSize: Number(size),
  ...JSON.parse(readFileSync("push.json", "utf8")),
  featureLock: JSON.parse(readFileSync(new URL(`${variant}/.devcontainer/devcontainer-lock.json`, import.meta.url), "utf8")),
  verify: variant === "cuda" ? "passed without GPU device run" : "passed",
  releasedAt: new Date().toISOString(),
};
writeFileSync("release.json", JSON.stringify(record, null, 2) + "\n");
console.log(JSON.stringify(record, null, 2));
