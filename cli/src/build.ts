import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { parse } from "jsonc-parser";
import type { ParseError } from "jsonc-parser";
import { devcontainerCli } from "./devcontainer.ts";
import { Docker } from "./docker.ts";
import type { LocalImage } from "./docker.ts";
import { stageLocalFeatures } from "./features.ts";
import { checked, run } from "./process.ts";
import type { Run } from "./process.ts";
import { parsePlatform, parseRemoteReference } from "./reference.ts";

export type BuildOutput =
  | { image: string }
  | { services: readonly { service: string; image: string }[] };

export interface BuildRequest {
  workspace: string;
  config?: string;
  platform?: string;
  /** Override the Dockerfile's BASE_IMAGE build argument with a fully qualified image reference. */
  baseImage?: string;
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

function stageBaseImage(source: string, baseImage: string): string {
  const errors: ParseError[] = [];
  const config = parse(readFileSync(source, "utf8"), errors, { allowTrailingComma: true }) as {
    build?: { dockerfile?: string; args?: Record<string, string> };
  } | null | undefined;
  if (errors.length) throw new Error(`Invalid Dev Container configuration: ${source}`);
  if (typeof config?.build?.dockerfile !== "string") {
    throw new Error("--base-image requires a Dev Container configuration with build.dockerfile");
  }
  config.build.args = { ...config.build.args, BASE_IMAGE: baseImage };
  // Keep relative Dockerfile and Feature paths and the lockfile naming convention.
  const prefix = basename(source).startsWith(".") ? "." : "";
  const staged = join(dirname(source), `${prefix}devcontainer.wisehub-local-${randomUUID()}.json`);
  writeFileSync(staged, JSON.stringify(config, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  return staged;
}

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
    if (request.baseImage !== undefined) parseRemoteReference(request.baseImage);
    const extra = request.args ?? [];
    const clash = extra.map(arg => arg.split("=")[0]).find(flag => reservedFlags.has(flag));
    if (clash) throw new Error(`${clash} is set by wisehub image build; call devcontainer directly for other output modes`);

    const outputs = "image" in request.output ? [request.output] : request.output.services;
    if (!outputs.length || outputs.some(item => !item.image || item.image.startsWith("-"))) {
      throw new Error("Build requires named image outputs");
    }
    const cli = devcontainerCli();
    const workspace = resolve(request.workspace);
    const config = request.config ? resolve(workspace, request.config) : undefined;
    const nested = join(workspace, ".devcontainer/devcontainer.json");
    const source = config ?? (existsSync(nested) ? nested : join(workspace, ".devcontainer.json"));
    const local = request.localFeatures
      ? stageLocalFeatures(source, request.localFeatures)
      : undefined;
    let override: string | undefined;
    let staging: string | undefined;
    try {
      if (request.baseImage !== undefined) override = stageBaseImage(local?.config ?? source, request.baseImage);
      const buildConfig = override ?? local?.config ?? config;
      const args = ["build", "--workspace-folder", workspace, "--docker-path", this.docker.binary];
      if (buildConfig) args.push("--config", buildConfig);
      if (local) args.push("--no-lockfile");
      if (request.platform) args.push("--platform", request.platform);
      // Promote by ID after building, so concurrent builds cannot supply each other's images.
      if ("image" in request.output) {
        staging = `wise-build/staging:${randomUUID()}`;
        args.push("--image-name", staging);
      }
      await checked("devcontainer", this.execute(process.execPath, [cli.script, ...args, ...extra],
        { cwd: workspace, stdio: "tee" }));
      const images = await Promise.all(outputs.map(async output => {
        const image = await this.docker.inspectImage(staging ?? output.image, request.platform);
        if (staging) await this.docker.tag(image.id, output.image);
        return { ...image, reference: output.image, ...("service" in output ? { service: output.service } : {}) };
      }));
      return { engineVersion: cli.version, images };
    } finally {
      if (override) rmSync(override, { force: true });
      local?.cleanup();
      if (staging) await this.docker.removeImage(staging).catch(() => undefined);
    }
  }
}
