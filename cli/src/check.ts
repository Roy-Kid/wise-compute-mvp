// Checks a recipe's Features against the SDK contract of its core Feature without building anything.
// Dev Container installs what a Feature's dependsOn names; what an install script asks the image about
// (another Feature, a capability) must be ordered before it through installsAfter. docs/feature-sdk.md
// states the rules C1 to C7.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { parseFeatureReference, readStack, resolveLocal, type StackFeature } from "./features.ts";

export interface Finding {
  /** `collection/id` of the Feature. */
  feature: string;
  rule: "C1" | "C2" | "C3" | "C4" | "C5" | "C6" | "C7";
  message: string;
}

const sdkFiles = ["feature.sh", "deps.sh", "build.sh"];
const sdkPath = "/usr/local/lib/devcontainer-features/feature.sh";
const literal = /^[a-z0-9][a-z0-9-]*$/;

interface Sdk {
  version: number;
  /** The SDK each function is in since. */
  since: Map<string, number>;
}

function readSdk(core: StackFeature): Sdk {
  const text = sdkFiles.map(file => readFileSync(join(core.dir, file), "utf8")).join("\n");
  const version = /^WISE_SDK=(\d+)$/m.exec(text);
  if (!version) throw new Error(`${core.dir}: feature.sh does not set WISE_SDK`);
  const since = new Map<string, number>();
  for (const line of text.split("\n")) {
    const definition = /^(wise_[a-z_]+)\(\)/.exec(line);
    if (!definition) continue;
    const introduced = /# since (\d+)\./.exec(line);
    if (!introduced) throw new Error(`${core.dir}: ${definition[1]} does not say since which SDK it exists`);
    since.set(definition[1], Number(introduced[1]));
  }
  return { version: Number(version[1]), since };
}

interface Script {
  /** Lines that hold code, without comment lines. */
  lines: string[];
  functions: Set<string>;
  /** Features asked for by wise_has, wise_require and wise_require_if. */
  features: Set<string>;
  /** Capabilities asked for by wise_provider, wise_require_capability and wise_mpi. */
  capabilities: Set<string>;
  provides: Set<string>;
  /** Arguments that are not written out. */
  opaque: string[];
}

function readScript(text: string): Script {
  const lines = text.split("\n").map(line => line.trim()).filter(line => line && !line.startsWith("#"));
  const script: Script = { lines, functions: new Set(), features: new Set(), capabilities: new Set(), provides: new Set(), opaque: [] };
  const argument = (call: string, value: string | undefined, into: Set<string>) => {
    const name = (value ?? "").replace(/^["']|["');|&]+$/g, "");
    if (literal.test(name)) into.add(name);
    else script.opaque.push(`${call} ${value ?? ""}`.trim());
  };
  for (const line of lines) {
    for (const [, name] of line.matchAll(/(?<![$\w{])(wise_[a-z_]+)\b(?!=)/g)) script.functions.add(name);
    for (const [, call, first, second] of line.matchAll(/(?<![$\w{])(wise_[a-z_]+)(?:[ \t]+(\S+))?(?:[ \t]+(\S+))?/g)) {
      if (call === "wise_has" || call === "wise_require" || call === "wise_version") argument(call, first, script.features);
      else if (call === "wise_require_if") argument(call, second, script.features);
      else if (call === "wise_provider" || call === "wise_require_capability") argument(call, first, script.capabilities);
      else if (call === "wise_provide") argument(call, first, script.provides);
      else if (call === "wise_mpi") script.capabilities.add("mpi");
    }
  }
  return script;
}

/** Every violation of the SDK contract in the stack; none when the recipe is sound. */
export function checkStack(stack: string): Finding[] {
  const features = readStack(stack);
  const core = features.find(feature => feature.id === "core");
  if (!core) throw new Error(`${stack} holds no core Feature`);
  const sdk = readSdk(core);
  const name = (feature: StackFeature) => `${feature.collection}/${feature.id}`;
  const findings: Finding[] = [];
  const scripts = new Map<StackFeature, Script>();
  for (const feature of features) {
    const path = join(feature.dir, "install.sh");
    if (existsSync(path)) scripts.set(feature, readScript(readFileSync(path, "utf8")));
    else findings.push({ feature: name(feature), rule: "C1", message: "has no install.sh" });
  }
  const providers = new Map<string, StackFeature[]>();
  for (const [feature, script] of scripts) {
    for (const capability of script.provides) providers.set(capability, [...(providers.get(capability) ?? []), feature]);
  }

  // C7 first: the other rules compare against resolved references.
  const edges = new Map<StackFeature, { depends: Set<string>; after: Set<string>; all: StackFeature[] }>();
  for (const feature of features) {
    const meta = JSON.parse(readFileSync(join(feature.dir, "devcontainer-feature.json"), "utf8"));
    const resolved = { depends: new Set<string>(), after: new Set<string>(), all: [] as StackFeature[] };
    const add = (reference: string, into: Set<string>) => {
      try {
        parseFeatureReference(reference);
        const target = resolveLocal(features, reference);
        if (!target) throw new Error(`${reference} is not a Feature of this recipe`);
        into.add(target.id);
        resolved.all.push(target);
      } catch (error) {
        findings.push({ feature: name(feature), rule: "C7", message: error instanceof Error ? error.message : String(error) });
      }
    };
    for (const reference of Object.keys(meta.dependsOn ?? {})) add(reference, resolved.depends);
    for (const reference of meta.installsAfter ?? []) add(reference, resolved.after);
    edges.set(feature, resolved);
  }
  const state = new Map<StackFeature, "visiting" | "done">();
  const visit = (feature: StackFeature, path: string[]) => {
    if (state.get(feature) === "done") return;
    if (state.get(feature) === "visiting") {
      findings.push({ feature: name(feature), rule: "C7", message: `is in a cycle: ${[...path, feature.id].join(" -> ")}` });
      return;
    }
    state.set(feature, "visiting");
    for (const target of edges.get(feature)!.all) visit(target, [...path, feature.id]);
    state.set(feature, "done");
  };
  for (const feature of features) visit(feature, []);

  for (const [feature, script] of scripts) {
    const report = (rule: Finding["rule"], message: string) => findings.push({ feature: name(feature), rule, message });
    const { depends, after } = edges.get(feature)!;

    // C1: core installs the SDK before it can load it; every other script starts the same way.
    if (feature !== core) {
      const head = ["#!/bin/sh", "set -eu", `wise_id=${feature.id}`, `. ${sdkPath}`];
      const [shebang] = readFileSync(join(feature.dir, "install.sh"), "utf8").split("\n");
      const start = [shebang, ...script.lines.slice(0, 3)];
      if (head.some((line, index) => start[index] !== line)) {
        report("C1", `install.sh must start with: ${head.join(" ; ")}`);
      }
    }
    const declared = script.lines.map(line => /^wise_sdk (\S+)$/.exec(line)?.[1]).filter(value => value !== undefined);
    const position = script.lines.findIndex(line => line.startsWith("wise_sdk "));
    if (declared.length !== 1 || !/^\d+$/.test(declared[0]) || (feature !== core && position !== 3)) {
      report("C1", "install.sh must call `wise_sdk <number>` once, right after loading feature.sh");
    }
    if (script.lines.at(-1) !== "wise_done") report("C1", "install.sh must end with wise_done");

    // C2
    const needed = Math.max(0, ...[...script.functions].map(used => sdk.since.get(used) ?? 0));
    for (const used of script.functions) {
      if (!sdk.since.has(used)) report("C2", `calls ${used}, which the SDK does not define`);
    }
    if (declared.length === 1 && /^\d+$/.test(declared[0])) {
      const asked = Number(declared[0]);
      if (asked > sdk.version) report("C2", `asks for SDK ${asked}; the recipe's SDK is ${sdk.version}`);
      if (asked < needed) report("C2", `asks for SDK ${asked} and uses functions of SDK ${needed}`);
    }

    // C5
    for (const call of script.opaque) report("C5", `\`${call}\` must name its Feature or capability literally`);
    for (const target of script.features) {
      if (!features.some(other => other.id === target)) report("C5", `asks for ${target}, which is not a Feature of this recipe`);
    }
    for (const capability of script.capabilities) {
      if (!providers.has(capability)) report("C5", `asks for the capability ${capability}, which no Feature provides`);
    }

    // C3
    for (const target of script.features) {
      if (depends.has(target)) report("C3", `asks for ${target}, which dependsOn already installs; drop the query`);
      else if (!after.has(target) && features.some(other => other.id === target)) {
        report("C3", `asks for ${target} without naming it in installsAfter, so the order is not fixed`);
      }
    }

    // C4
    for (const capability of script.capabilities) {
      for (const provider of providers.get(capability) ?? []) {
        if (provider !== feature && !depends.has(provider.id) && !after.has(provider.id)) {
          report("C4", `asks for the capability ${capability} without naming its provider ${provider.id} in dependsOn or installsAfter`);
        }
      }
    }

    // C6
    if (feature !== core && script.lines.some(line => /WISE_REGISTRY|share\/devcontainer-features/.test(line))) {
      report("C6", "reads the registry directly; use wise_has, wise_version or a capability");
    }
  }
  return findings.sort((a, b) => a.feature.localeCompare(b.feature) || a.rule.localeCompare(b.rule));
}
