import { randomUUID } from "node:crypto";
import { resolve } from "node:path";
import { devcontainerCli } from "./devcontainer.ts";
import { Docker } from "./docker.ts";
import type { LocalImage } from "./docker.ts";
import { stageLocalFeatures } from "./features.ts";
import { checked, run } from "./process.ts";
import type { Run } from "./process.ts";
import { parsePlatform } from "./reference.ts";

export type BuildOutput =
  | { image: string }
  | { services: readonly { service: string; image: string }[] };

export interface BuildRequest {
  workspace: string;
  config?: string;
  platform?: string;
  output: BuildOutput;
  /**
   * Stack directory whose Features replace their registry references for this build (development and
   * merge requests). The lockfile does not apply to such a build.
   */
  localFeatures?: string;
  /** Extra `devcontainer build` flags, e.g. --frozen-lockfile. */
  args?: readonly string[];
}

export interface BuildResult {
  engineVersion: string;
  images: (LocalImage & { service?: string })[];
}

/** Flags this wrapper sets itself from the structured request. */
const reservedFlags = new Set([
  "--workspace-folder", "--config", "--platform", "--image-name", "--push",
  "--output", "--docker-path", "--no-lockfile", "--help", "--version", "--",
]);

/** Builds a Dev Container workspace into named local images and reports what Docker actually holds. */
export class DevContainerBuilder {
  private readonly docker: Docker;
  private readonly execute: Run;

  constructor(docker = new Docker(), execute: Run = run) {
    this.docker = docker;
    this.execute = execute;
  }

  async build(request: BuildRequest): Promise<BuildResult> {
    if (request.platform) parsePlatform(request.platform);
    const extra = request.args ?? [];
    const clash = extra.map(arg => arg.split("=")[0]).find(flag => reservedFlags.has(flag));
    if (clash) throw new Error(`${clash} is set by wisehub image build; call devcontainer directly for other output modes`);

    const outputs = "image" in request.output ? [request.output] : request.output.services;
    if (!outputs.length || outputs.some(item => !item.image || item.image.startsWith("-"))) {
      throw new Error("Build requires named image outputs");
    }
    // A single image is built under a unique staging name and promoted by ID, so a concurrent
    // build cannot make us report someone else's image. Compose names come from the Compose file.
    const staging = "image" in request.output ? `wise-build/staging:${randomUUID()}` : undefined;

    const cli = devcontainerCli();
    const workspace = resolve(request.workspace);
    const config = request.config ? resolve(workspace, request.config) : undefined;
    const local = request.localFeatures
      ? stageLocalFeatures(config ?? resolve(workspace, ".devcontainer/devcontainer.json"), request.localFeatures)
      : undefined;
    const args = ["build", "--workspace-folder", workspace, "--docker-path", this.docker.binary];
    if (local) args.push("--config", local.config, "--no-lockfile");
    else if (config) args.push("--config", config);
    if (request.platform) args.push("--platform", request.platform);
    if (staging) args.push("--image-name", staging);
    try {
      await checked("devcontainer", this.execute(process.execPath, [cli.script, ...args, ...extra],
        { cwd: workspace, stdio: "tee" }));
      const images = await Promise.all(outputs.map(async output => {
        const image = await this.docker.inspectImage(staging ?? output.image, request.platform);
        if (staging) await this.docker.tag(image.id, output.image);
        return { ...image, reference: output.image, ...("service" in output ? { service: output.service } : {}) };
      }));
      return { engineVersion: cli.version, images };
    } finally {
      local?.cleanup();
      if (staging) await this.docker.removeImage(staging).catch(() => undefined);
    }
  }
}
