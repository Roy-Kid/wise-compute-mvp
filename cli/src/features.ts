import { randomUUID } from "node:crypto";
import { cpSync, existsSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { checked, run } from "./process.ts";
import type { Run } from "./process.ts";
import { devcontainerCli } from "./devcontainer.ts";

/**
 * A stack is a directory of Feature collections laid out as `<stack>/<collection>/src/<id>/`.
 * Published, a Feature is `<registry>/<namespace>/<collection>/<id>:<version>`; that reference is the
 * only way Features and deliveries refer to each other.
 */
export interface StackFeature {
  collection: string;
  id: string;
  dir: string;
  version: string;
  /** dependsOn and installsAfter references, as written. */
  references: string[];
}

export interface FeatureReference {
  /** `<registry>/<namespace>`, everything before `<collection>/<id>`. */
  prefix: string;
  collection: string;
  id: string;
  tag: string;
}

const referencePattern = /^([a-z0-9.-]+(?::\d+)?(?:\/[a-z0-9._-]+)*)\/([a-z0-9._-]+)\/([a-z0-9._-]+):([A-Za-z0-9._-]+)$/;
const quotedReference = /"([a-z0-9.-]+(?::\d+)?(?:\/[a-z0-9._-]+)+:[A-Za-z0-9._-]+)"/g;

export function parseFeatureReference(reference: string): FeatureReference {
  const match = referencePattern.exec(reference);
  if (!match) throw new Error(`Expected REGISTRY/NAMESPACE/COLLECTION/ID:TAG, got ${reference}`);
  const [, prefix, collection, id, tag] = match;
  return { prefix, collection, id, tag };
}

/** A tag `1`, `1.2` or `1.2.3` matches versions with that prefix, as the Dev Container CLI publishes them. */
export function tagMatches(tag: string, version: string): boolean {
  return tag === "latest" || version === tag || version.startsWith(`${tag}.`);
}

export function readStack(stack: string): StackFeature[] {
  const root = resolve(stack);
  return readdirSync(root, { withFileTypes: true })
    .filter(entry => entry.isDirectory() && existsSync(join(root, entry.name, "src")))
    .flatMap(entry => readdirSync(join(root, entry.name, "src")).sort().map(id => {
      const dir = join(root, entry.name, "src", id);
      const meta = JSON.parse(readFileSync(join(dir, "devcontainer-feature.json"), "utf8"));
      if (meta.id !== id) throw new Error(`${dir}: id ${meta.id} does not match its directory`);
      return {
        collection: entry.name, id, dir, version: String(meta.version),
        references: [...Object.keys(meta.dependsOn ?? {}), ...(meta.installsAfter ?? [])],
      };
    }));
}

/** The stack Feature a reference names, if the stack holds it at a version the tag accepts. */
export function resolveLocal(features: readonly StackFeature[], reference: string): StackFeature | undefined {
  let parsed: FeatureReference;
  try {
    parsed = parseFeatureReference(reference);
  } catch {
    return undefined;
  }
  const feature = features.find(item => item.collection === parsed.collection && item.id === parsed.id);
  if (feature && !tagMatches(parsed.tag, feature.version)) {
    throw new Error(`${reference} does not match ${feature.collection}/${feature.id} at version ${feature.version}`);
  }
  return feature;
}

/**
 * Makes a delivery buildable from the stack sources instead of the registry, for development and merge
 * requests. The config and every stack Feature are copied next to the original config, with references
 * into the stack rewritten to those copies; nothing in the repository changes and `cleanup` removes it all.
 */
export function stageLocalFeatures(configFile: string, stack: string): { config: string; cleanup: () => void } {
  const features = readStack(stack);
  const configDir = dirname(resolve(configFile));
  const token = `wisehub-local-${randomUUID()}`;
  const staged = join(configDir, token);
  const rewrite = (text: string) => text.replace(quotedReference, (whole, reference: string) => {
    const feature = resolveLocal(features, reference);
    return feature ? JSON.stringify(`./${token}/${feature.collection}/${feature.id}`) : whole;
  });
  const config = join(configDir, `devcontainer.${token}.json`);
  const cleanup = () => {
    rmSync(staged, { recursive: true, force: true });
    rmSync(config, { force: true });
  };
  try {
    for (const feature of features) {
      const target = join(staged, feature.collection, feature.id);
      cpSync(feature.dir, target, { recursive: true });
      const meta = join(target, "devcontainer-feature.json");
      writeFileSync(meta, rewrite(readFileSync(meta, "utf8")));
    }
    writeFileSync(config, rewrite(readFileSync(configFile, "utf8")));
  } catch (error) {
    cleanup();
    throw error;
  }
  return { config, cleanup };
}

/** Collections in publish order: a collection comes after every collection its Features depend on. */
export function publishOrder(features: readonly StackFeature[], prefix: string): string[] {
  const after = new Map<string, Set<string>>();
  for (const feature of features) {
    const edges = after.get(feature.collection) ?? new Set<string>();
    after.set(feature.collection, edges);
    for (const reference of feature.references) {
      const parsed = parseFeatureReference(reference);
      if (parsed.prefix !== prefix) throw new Error(`${feature.collection}/${feature.id}: ${reference} is not under ${prefix}`);
      const target = resolveLocal(features, reference);
      if (!target) throw new Error(`${feature.collection}/${feature.id}: ${reference} is not in the stack`);
      if (target.collection !== feature.collection) edges.add(target.collection);
    }
  }
  const order: string[] = [];
  const visiting = new Set<string>();
  const visit = (collection: string) => {
    if (order.includes(collection)) return;
    if (visiting.has(collection)) throw new Error(`Collections depend on each other in a cycle through ${collection}`);
    visiting.add(collection);
    for (const dependency of [...after.get(collection)!].sort()) visit(dependency);
    visiting.delete(collection);
    order.push(collection);
  };
  for (const collection of [...after.keys()].sort()) visit(collection);
  return order;
}

export interface PublishResult {
  collection: string;
  namespace: string;
  /** What `devcontainer features publish` reported: per Feature id, its digest and published tags. */
  features: Record<string, unknown>;
}

/** Publishes every collection of a stack under `<registry>/<namespace>/<collection>`, lowest first. */
export class FeaturePublisher {
  private readonly execute: Run;

  constructor(execute: Run = run) {
    this.execute = execute;
  }

  async publish(stack: string, registry: string, namespace: string): Promise<PublishResult[]> {
    const root = resolve(stack);
    const features = readStack(root);
    const cli = devcontainerCli();
    const results: PublishResult[] = [];
    for (const collection of publishOrder(features, `${registry}/${namespace}`)) {
      const target = `${namespace}/${collection}`;
      // The CLI skips versions that already exist, so a published version is never overwritten.
      const stdout = await checked("devcontainer", this.execute(process.execPath,
        [cli.script, "features", "publish", join(root, collection, "src"), "--registry", registry, "--namespace", target],
        { stdio: "tee" }));
      results.push({ collection, namespace: target, features: parsePublishOutput(stdout) });
    }
    return results;
  }
}

function parsePublishOutput(stdout: string): Record<string, unknown> {
  const start = stdout.indexOf("{");
  if (start === -1) return {};
  return JSON.parse(stdout.slice(start));
}
