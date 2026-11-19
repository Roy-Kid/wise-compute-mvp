import { createRequire } from "node:module";
import { randomUUID } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { checked, run } from "./process.js";
import type { CommandResult, Run } from "./process.js";
import { localImage, validatePlatform } from "./image.js";
import type { LocalImage } from "./image.js";

const require = createRequire(import.meta.url);
const packagePath = require.resolve("@devcontainers/cli/package.json");
const executable = join(dirname(packagePath), "devcontainer.js");
const version: string = require(packagePath).version;

export interface Invocation {
  args: readonly string[];
  cwd?: string;
  signal?: AbortSignal;
}

export type BuildOutput =
  | { image: string }
  | { services: readonly { service: string; image: string }[] };

export interface BuildRequest {
  workspace: string;
  config?: string;
  platform?: string;
  output: BuildOutput;
  args?: readonly string[];
  signal?: AbortSignal;
}

export interface BuildResult {
  engineVersion: string;
  images: (LocalImage & { service?: string })[];
}

export interface BuildEngine {
  invoke(request: Invocation): Promise<CommandResult>;
  build(request: BuildRequest): Promise<BuildResult>;
}

export class DevContainerEngine implements BuildEngine {
  constructor(private readonly execute: Run = run, private readonly docker = "docker") {}

  invoke(request: Invocation): Promise<CommandResult> {
    return this.execute(process.execPath, [executable, ...request.args], {
      cwd: request.cwd, signal: request.signal, inherit: true,
    });
  }

  async build(request: BuildRequest): Promise<BuildResult> {
    if (request.platform) validatePlatform(request.platform);
    const reserved = new Set([
      "--workspace-folder", "--config", "--platform", "--image-name", "--push",
      "--output", "--docker-path", "--help", "--version", "--",
    ]);
    if (request.args?.some(arg => reserved.has(arg.split("=")[0]))) {
      throw new Error("Build output and workspace are controlled by the structured request; use invoke for native output modes");
    }
    const workspace = resolve(request.workspace);
    const staging = "image" in request.output ? `wise-build/staging:${randomUUID()}` : undefined;
    const outputs = "image" in request.output ? [request.output] : request.output.services;
    if (!outputs.length || outputs.some(item => !item.image || item.image.startsWith("-"))) {
      throw new Error("Build requires named image outputs");
    }
    const args = ["build", "--workspace-folder", workspace, "--docker-path", this.docker];
    if (request.config) args.push("--config", resolve(workspace, request.config));
    if (request.platform) args.push("--platform", request.platform);
    if (staging) args.push("--image-name", staging);
    try {
      checked(await this.execute(process.execPath, [executable, ...args, ...request.args ?? []], {
        cwd: workspace, signal: request.signal, logs: true,
      }));
      const images = await Promise.all(outputs.map(async output => {
        const image = await localImage(this.execute, this.docker, staging ?? output.image,
          request.platform, request.signal);
        if (staging) {
          checked(await this.execute(this.docker, ["image", "tag", image.id, output.image],
            { signal: request.signal }));
        }
        return { ...image, reference: output.image, ...("service" in output ? { service: output.service } : {}) };
      }));
      return { engineVersion: version, images };
    } finally {
      if (staging) await this.execute(this.docker, ["image", "rm", staging]).catch(() => undefined);
    }
  }
}
