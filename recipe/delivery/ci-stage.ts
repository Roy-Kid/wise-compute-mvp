// Builds one stage of a delivery, and any stage before it the registry lacks, or verifies the finished image:
//   node recipe/delivery/ci-stage.ts cpu|cuda 1..N|release
// STAGE_REPOSITORY holds the stage images. `release` leaves the verified image as wise-compute:materials-VARIANT.
import { setTimeout } from "node:timers/promises";
import { DevContainerBuilder } from "../../cli/src/build.ts";
import { Docker, RegistryError } from "../../cli/src/docker.ts";
import { OciRegistry } from "../../cli/src/registry.ts";
import { prepareStage, stageCount, stageTags } from "./stages.ts";
import { verifyImage } from "./verify-image.ts";

const [variant, goal, ...extra] = process.argv.slice(2);
const stage = Number(goal);
const validGoal = goal === "release" || (Number.isInteger(stage) && stage >= 1 && stage <= stageCount);
if (!["cpu", "cuda"].includes(variant) || !validGoal || extra.length) {
  throw new Error(`usage: node recipe/delivery/ci-stage.ts cpu|cuda 1..${stageCount}|release`);
}
const repository = process.env.STAGE_REPOSITORY;
if (!repository) throw new Error("STAGE_REPOSITORY names the repository of the stage images");

const platform = "linux/amd64";
const pushAttempts = 5;
const docker = new Docker();
const registry = new OciRegistry(docker);
const fetched = new Set<string>();
const targets = stageTags(variant).map(tag => `${repository}:${tag}`);

async function buildStage(number: number): Promise<void> {
  const target = targets[number - 1];
  const local = `wise-compute:${variant}-stage-${number}`;
  const previous = number === 1 ? undefined : `wise-compute:${variant}-stage-${number - 1}`;
  if (previous) await fetchStage(number - 1, previous);
  const build = prepareStage(variant, number, previous);
  try {
    await new DevContainerBuilder(docker).build({
      workspace: build.workspace, config: build.config, localFeatures: build.stack, platform, output: { image: local },
    });
  } finally {
    build.cleanup();
  }
  await push(local, target);
  fetched.add(local);
}

/** Pushes a stage; a registry hiccup must not discard hours of compilation. */
async function push(local: string, target: string): Promise<void> {
  for (let attempt = 1; ; attempt++) {
    try {
      await registry.push(local, target);
      return;
    } catch (error) {
      const permanent = error instanceof RegistryError && ["authentication", "permission", "conflict"].includes(error.kind);
      if (permanent || attempt === pushAttempts) throw error;
      console.error(`push attempt ${attempt} failed, retrying: ${error instanceof Error ? error.message : error}`);
      await setTimeout(attempt * 30_000);
    }
  }
}

async function fetchStage(number: number, local: string): Promise<void> {
  if (fetched.has(local)) return;
  const { image } = await registry.pull(targets[number - 1], platform);
  await docker.tag(image.id, local);
  fetched.add(local);
}

const last = goal === "release" ? stageCount : stage;
let available = last;
while (available > 0 && !await docker.describe(targets[available - 1])) available--;
console.log(available === last ? `${targets[last - 1]} is up to date`
  : `building stages ${available + 1} to ${last} of ${variant}`);
for (let number = available + 1; number <= last; number++) await buildStage(number);

if (goal === "release") {
  const image = `wise-compute:materials-${variant}`;
  await fetchStage(stageCount, image);
  verifyImage(docker.binary, image, variant);
}
