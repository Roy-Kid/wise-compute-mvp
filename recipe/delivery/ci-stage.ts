// Build one local stage, or verify the completed image after restoring its checkpoint.
//   node recipe/delivery/ci-stage.ts cpu|cuda|smp 1..N|N.PART|release
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { DevContainerBuilder } from "../../cli/src/build.ts";
import { Docker } from "../../cli/src/docker.ts";
import { lammpsObjects, partCount, prepareStage, stageCount } from "./stages.ts";
import { verifyImage } from "./verify-image.ts";

const [variant, goal, ...extra] = process.argv.slice(2);
const [, stageText, partText] = /^(\d+)(?:\.(\d+))?$/.exec(goal ?? "") ?? [];
const stage = Number(stageText);
const part = partText === undefined ? undefined : Number(partText);
const validStage = Number.isInteger(stage) && stage >= 1 && stage <= stageCount;
if (!["cpu", "cuda", "smp"].includes(variant) || (goal !== "release" && !validStage) || extra.length) {
  throw new Error(`usage: node recipe/delivery/ci-stage.ts cpu|cuda|smp 1..${stageCount}|N.PART|release`);
}

const platform = "linux/amd64";
const docker = new Docker();
const checkpointDir = process.env.MATERIALS_CHECKPOINT_DIR;
const stageImage = (number: number) => `materials-build:${variant}-${number}`;

if (goal === "release") {
  const image = `wise-compute:materials-${variant}`;
  const { id } = await docker.inspectImage(stageImage(stageCount), platform);
  verifyImage(stageImage(stageCount), variant);
  await docker.tag(id, image);
} else {
  const previousImage = stage > 1 ? stageImage(stage - 1) : undefined;
  const build = prepareStage(variant, stage, previousImage, part);
  try {
    if (previousImage) await docker.inspectImage(previousImage, platform);
    const count = partCount(variant, stage);
    if (part === undefined && checkpointDir && count) {
      const objects = join(build.stack, "applications", "src", "lammps", "objects");
      mkdirSync(objects, { recursive: true });
      for (let index = 1; index <= count; index++) {
        const archive = join(checkpointDir, "parts", `checkpoint-${stage}.${index}.tar.zst`);
        execFileSync("tar", ["--zstd", "-xf", archive, "-C", objects], { stdio: "inherit" });
      }
    }
    const local = part === undefined ? stageImage(stage) : `materials-build:${variant}-${stage}.${part}`;
    const { images: [image] } = await new DevContainerBuilder(docker).build({
      workspace: build.workspace, config: build.config, localFeatures: build.stack, platform, output: { image: local },
    });
    if (part !== undefined && checkpointDir) {
      await docker.copyOut(image.id, `${lammpsObjects}/.`, join(checkpointDir, "objects"));
    }
  } finally {
    build.cleanup();
  }
}
