import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const stackRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
export const featuresRoot = join(stackRoot, "features");
export const recipesRoot = join(stackRoot, "recipes");

const pinnedImage = /^[^@\s]+@sha256:[a-f0-9]{64}$/;
const snapshot = /^\d{8}T\d{6}Z$/;

export interface Variant {
  buildArgs: { BASE_IMAGE: string } & Record<string, string>;
}

export interface Stack {
  aptSnapshot: string;
  tiers: Record<string, string[]>;
  variants: Record<string, Variant>;
}

export interface FeatureMetadata {
  id: string;
  version: string;
  name: string;
  dependsOn?: unknown;
  installsAfter?: unknown;
}

const readJson = (path: string): unknown => JSON.parse(readFileSync(path, "utf8"));

export function featureIds(): string[] {
  return readdirSync(join(featuresRoot, "src")).sort();
}

export function readFeature(id: string): FeatureMetadata {
  return readJson(join(featuresRoot, "src", id, "devcontainer-feature.json")) as FeatureMetadata;
}

/** Install order is the tier order in stack.json, flattened. */
export function installOrder(stack: Stack): string[] {
  return Object.values(stack.tiers).flat();
}

/** Loads stack.json and rejects anything a build would otherwise discover late. */
export function loadStack(path = join(stackRoot, "stack.json")): Stack {
  const stack = readJson(path) as Stack;
  const problems: string[] = [];
  if (!snapshot.test(stack.aptSnapshot)) problems.push("aptSnapshot must look like 20261101T000000Z");
  const order = installOrder(stack);
  const known = new Set(featureIds());
  for (const id of order) if (!known.has(id)) problems.push(`unknown Feature ${id}`);
  if (new Set(order).size !== order.length) problems.push("a Feature is listed more than once");
  for (const [name, variant] of Object.entries(stack.variants)) {
    for (const [arg, value] of Object.entries(variant.buildArgs)) {
      if (arg.endsWith("_IMAGE") && !pinnedImage.test(value)) problems.push(`${name}.${arg} must be pinned by digest`);
    }
    if (!variant.buildArgs.BASE_IMAGE) problems.push(`${name} needs BASE_IMAGE`);
    if (!existsSync(join(recipesRoot, name, "Dockerfile"))) problems.push(`recipes/${name}/Dockerfile is missing`);
  }
  if (problems.length) throw new Error(`Invalid ${path}:\n  ${problems.join("\n  ")}`);
  return stack;
}

export interface RenderOptions {
  variant: string;
  outDir: string;
  /** OCI namespace the Feature collection is published under, e.g. harbor.will/wise-compute/features. */
  featureRegistry?: string;
}

/**
 * Writes a standard Dev Container workspace for one variant and returns its folder.
 * Without a registry, Feature sources are copied into the workspace as local Features.
 */
export function renderRecipe(stack: Stack, options: RenderOptions): string {
  const variant = stack.variants[options.variant];
  if (!variant) throw new Error(`Unknown variant ${options.variant}; expected ${Object.keys(stack.variants).join(", ")}`);
  const workspace = join(options.outDir, options.variant);
  const config = join(workspace, ".devcontainer");
  rmSync(workspace, { recursive: true, force: true });
  mkdirSync(config, { recursive: true });
  cpSync(join(recipesRoot, options.variant), config, { recursive: true });

  const refs = installOrder(stack).map(id => {
    if (!options.featureRegistry) {
      cpSync(join(featuresRoot, "src", id), join(config, "features", id), { recursive: true });
      return { ref: `./features/${id}`, id: `./features/${id}` };
    }
    const base = `${options.featureRegistry}/${id}`;
    return { ref: `${base}:${readFeature(id).version}`, id: base };
  });
  const devcontainer = {
    name: `WiseHub ${options.variant}`,
    build: { dockerfile: "Dockerfile", args: { ...variant.buildArgs, APT_SNAPSHOT: stack.aptSnapshot } },
    features: Object.fromEntries(refs.map(({ ref }) => [ref, {}])),
    overrideFeatureInstallOrder: refs.map(({ id }) => id),
  };
  writeFileSync(join(config, "devcontainer.json"), JSON.stringify(devcontainer, null, 2) + "\n");
  return workspace;
}

const require = createRequire(import.meta.url);
const devcontainerBin = join(dirname(require.resolve("@devcontainers/cli/package.json")), "devcontainer.js");

/** Runs the pinned official Dev Container CLI; throws with its output on failure. */
export function devcontainer(args: string[], options: { inherit?: boolean } = {}): string {
  const result = spawnSync(process.execPath, [devcontainerBin, ...args], {
    encoding: "utf8", stdio: options.inherit ? "inherit" : "pipe",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`devcontainer ${args.join(" ")} exited with ${result.status}\n${result.stderr ?? ""}`);
  }
  return result.stdout ?? "";
}
