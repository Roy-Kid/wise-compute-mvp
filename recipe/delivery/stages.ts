// A delivery compiles for longer than one hosted CI job may run, so it is built as a chain of images. Each stage
// adds its Features to the image of the stage before, and its tag is a hash of everything that went into it: a
// later run continues after the last unchanged stage.
import { createHash } from "node:crypto";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { parse } from "jsonc-parser";
import { parseFeatureReference, readStack } from "../../cli/src/features.ts";

/** Features of the later stages, in order: the long builds. The first stage holds all the others. */
export const laterStages = [["elpa"], ["lammps"], ["quantum-espresso"], ["cp2k-integrals"], ["cp2k-toolchain"], ["cp2k"]];
export const stageCount = laterStages.length + 1;

/** LAMMPS with CUDA takes longer than a CI job may run, so jobs of their own compile its objects in this many parts. */
const lammpsParts = 8;
export const lammpsObjects = "/opt/wise/share/wise/lammps-objects";
export const lammpsStage = laterStages.findIndex(ids => ids.includes("lammps")) + 2;
export function partCount(variant: string, stage: number): number {
  return variant === "cuda" && stage === lammpsStage ? lammpsParts : 0;
}

const recipe = join(import.meta.dirname, "..");
type Features = Record<string, Record<string, unknown>>;
type Config = { features: Features } & Record<string, unknown>;

function readDelivery(variant: string): Config {
  return parse(readFileSync(join(recipe, "delivery", variant, ".devcontainer", "devcontainer.json"), "utf8"),
    [], { allowTrailingComma: true });
}

/** What the Features of the later stages depend on, so that the first stage installs it. */
function laterDependencies(later: Set<string>): Features {
  const dependencies = readStack(recipe).filter(feature => later.has(feature.id)).map(feature =>
    JSON.parse(readFileSync(join(feature.dir, "devcontainer-feature.json"), "utf8")).dependsOn as Features | undefined);
  return Object.assign({}, ...dependencies);
}

/** The Features each stage asks for; every Feature of the delivery is in exactly one stage. */
export function stageFeatures(variant: string): Features[] {
  const delivery = readDelivery(variant).features;
  const later = new Set(laterStages.flat());
  const entries = Object.entries({ ...laterDependencies(later), ...delivery });
  const pick = (wanted: (id: string) => boolean) =>
    Object.fromEntries(entries.filter(([reference]) => wanted(parseFeatureReference(reference).id)));
  return [pick(id => !later.has(id)), ...laterStages.map(ids => pick(id => ids.includes(id)))];
}

function hashTree(hash: ReturnType<typeof createHash>, root: string): void {
  const files = readdirSync(root, { recursive: true, withFileTypes: true }).filter(entry => entry.isFile())
    .map(entry => join(entry.parentPath, entry.name)).sort();
  for (const file of files) {
    const content = readFileSync(file);
    hash.update(`${relative(root, file)}\0${content.length}\0`).update(content);
  }
}

/** Image tags of the stages. A change rebuilds its own stage and the ones after it. */
export function stageTags(variant: string): string[] {
  const later = new Set(laterStages.flat());
  const stack = readStack(recipe);
  let previous = variant;
  return stageFeatures(variant).map((features, index) => {
    const hash = createHash("sha256").update(previous).update(JSON.stringify(features));
    if (index === 0) hashTree(hash, join(recipe, "base", variant));
    const own = stack.filter(feature => index === 0 ? !later.has(feature.id) : laterStages[index - 1].includes(feature.id));
    for (const feature of own) hashTree(hash.update(`${feature.collection}/${feature.id}\0`), feature.dir);
    previous = hash.digest("hex");
    return `build-${variant}-${index + 1}-${previous.slice(0, 16)}`;
  });
}

/** Image tags of the parts of a stage; none for a stage built in one go. */
export function partTags(variant: string, stage: number): string[] {
  const count = partCount(variant, stage);
  return Array.from({ length: count }, (_, index) => `${stageTags(variant)[stage - 1]}-part-${index + 1}-of-${count}`);
}

export interface StageBuild {
  workspace: string;
  config: string;
  /** Feature sources for this stage. */
  stack: string;
  cleanup: () => void;
}

/** Writes what `devcontainer build` needs for one stage (from 1), or a part of it; later stages build on `previousImage`. */
export function prepareStage(variant: string, stage: number, previousImage?: string, part?: number): StageBuild {
  const selected = stageFeatures(variant)[stage - 1];
  const count = partCount(variant, stage);
  if (part !== undefined && !(part >= 1 && part <= count)) throw new Error(`Stage ${stage} of ${variant} has no part ${part}`);
  const features = part === undefined ? selected : Object.fromEntries(Object.entries(selected).map(([reference, options]) =>
    [reference, parseFeatureReference(reference).id === "lammps" ? { ...options, part: `${part}/${count}` } : options]));
  const delivery = join(recipe, "delivery", variant);
  if (stage === 1) {
    // Next to the delivery's own file, which names the Dockerfile by a relative path.
    const config = join(delivery, ".devcontainer", `devcontainer.wisehub-local-stage-${process.pid}.json`);
    writeFileSync(config, JSON.stringify({ ...readDelivery(variant), features }, null, 2));
    return { workspace: delivery, config, stack: recipe, cleanup: () => rmSync(config, { force: true }) };
  }
  if (!previousImage) throw new Error(`Stage ${stage} needs the image of stage ${stage - 1}`);
  const root = mkdtempSync(join(tmpdir(), "wise-stage-"));
  const cleanup = () => rmSync(root, { recursive: true, force: true });
  try {
    // The previous image already holds what these Features depend on; install.sh still checks it.
    for (const feature of readStack(recipe)) {
      const target = join(root, "stack", feature.collection, "src", feature.id);
      cpSync(feature.dir, target, { recursive: true });
      const meta = join(target, "devcontainer-feature.json");
      const { dependsOn: _, ...rest } = JSON.parse(readFileSync(meta, "utf8"));
      writeFileSync(meta, JSON.stringify(rest, null, 2));
    }
    const config = join(root, "workspace", ".devcontainer", "devcontainer.json");
    mkdirSync(dirname(config), { recursive: true });
    const { build: _, ...rest } = readDelivery(variant);
    writeFileSync(config, JSON.stringify({ ...rest, image: previousImage, features }, null, 2));
    return { workspace: join(root, "workspace"), config, stack: join(root, "stack"), cleanup };
  } catch (error) {
    cleanup();
    throw error;
  }
}
