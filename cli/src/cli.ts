#!/usr/bin/env node
import { parseArgs } from "node:util";
import { DevContainerBuilder } from "./build.ts";
import { RegistryError } from "./docker.ts";
import { checkStack } from "./check.ts";
import { FeaturePublisher } from "./features.ts";
import { OciRegistry } from "./registry.ts";
import { exportImages, extendImage, listFeatures, recordFeatures } from "./release.ts";

const usage = `Usage:
  wisehub image build [--workspace-folder DIR] [--config FILE] [--platform OS/ARCH] [--base-image REF] [--local-features RECIPE]
                      (--image NAME | --service-image SERVICE=NAME ...) [-- devcontainer build flags]
  wisehub image push SOURCE REGISTRY/REPOSITORY:TAG
  wisehub image pull REGISTRY/REPOSITORY(:TAG|@DIGEST) [--platform OS/ARCH]
  wisehub image extend SOURCE --context DIR --image NAME [--platform OS/ARCH] [--build-arg NAME=VALUE ...]
  wisehub image export IMAGE:TAG ... --output DIR
  wisehub feature publish RECIPE --registry HOST --namespace NAMESPACE
  wisehub feature check RECIPE
  wisehub feature list IMAGE [--record FILE]

--local-features builds with the recipe's Feature sources in place of their registry references.
--base-image overrides the Dockerfile's BASE_IMAGE build argument.
feature publish pushes each collection RECIPE/<collection>/src to HOST/NAMESPACE/<collection>, lowest first.
image extend builds the Dockerfile in DIR on top of the local image SOURCE, which it receives as BASE_IMAGE.
image export saves each image as DIR/<tag>.tar.zst with its SHA-256 and writes DIR/manifest.json; needs zstd.
feature list prints the Features an image holds, as its core Feature registered them; --record writes
them into the "features" field of a JSON release record.
feature check compares every install.sh with the SDK of the core Feature and with the Feature's own
dependsOn and installsAfter, and fails when it finds a violation.

Results are printed to stdout as JSON; progress goes to stderr.
For any other Dev Container operation, run the devcontainer CLI directly.`;

class UsageError extends Error {}

function print(value: unknown): void {
  console.log(JSON.stringify(value, null, 2));
}

async function build(args: string[]): Promise<void> {
  const delimiter = args.indexOf("--");
  const { values } = parseArgs({
    args: delimiter === -1 ? args : args.slice(0, delimiter),
    options: {
      "workspace-folder": { type: "string", default: "." },
      config: { type: "string" },
      platform: { type: "string" },
      "base-image": { type: "string" },
      image: { type: "string" },
      "service-image": { type: "string", multiple: true },
      "local-features": { type: "string" },
    },
  });
  const services = (values["service-image"] ?? []).map(entry => {
    const [service, image, ...extra] = entry.split("=");
    if (!service || !image || extra.length) throw new UsageError(`Expected SERVICE=NAME, got ${entry}`);
    return { service, image };
  });
  if (Boolean(values.image) === Boolean(services.length)) {
    throw new UsageError("Declare either --image or one or more --service-image");
  }
  if (new Set(services.map(item => item.service)).size !== services.length) {
    throw new UsageError("Each Compose service may be declared once");
  }
  print(await new DevContainerBuilder().build({
    workspace: values["workspace-folder"],
    config: values.config,
    platform: values.platform,
    baseImage: values["base-image"],
    output: values.image ? { image: values.image } : { services },
    localFeatures: values["local-features"],
    args: delimiter === -1 ? [] : args.slice(delimiter + 1),
  }));
}

async function push(args: string[]): Promise<void> {
  const { positionals } = parseArgs({ args, allowPositionals: true, options: {} });
  if (positionals.length !== 2) throw new UsageError("push takes SOURCE and TARGET");
  print(await new OciRegistry().push(positionals[0], positionals[1]));
}

async function pull(args: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args, allowPositionals: true, options: { platform: { type: "string" } },
  });
  if (positionals.length !== 1) throw new UsageError("pull takes one REFERENCE");
  print(await new OciRegistry().pull(positionals[0], values.platform));
}

async function publish(args: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args, allowPositionals: true,
    options: { registry: { type: "string" }, namespace: { type: "string" } },
  });
  if (positionals.length !== 1 || !values.registry || !values.namespace) {
    throw new UsageError("feature publish takes RECIPE, --registry and --namespace");
  }
  print(await new FeaturePublisher().publish(positionals[0], values.registry, values.namespace));
}

async function extend(args: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args, allowPositionals: true,
    options: {
      context: { type: "string" }, image: { type: "string" }, platform: { type: "string" },
      "build-arg": { type: "string", multiple: true },
    },
  });
  if (positionals.length !== 1 || !values.context || !values.image) {
    throw new UsageError("image extend takes SOURCE, --context and --image");
  }
  const buildArgs: Record<string, string> = {};
  for (const entry of values["build-arg"] ?? []) {
    const split = entry.indexOf("=");
    if (split < 1) throw new UsageError(`Expected NAME=VALUE, got ${entry}`);
    buildArgs[entry.slice(0, split)] = entry.slice(split + 1);
  }
  if (Object.hasOwn(buildArgs, "BASE_IMAGE")) throw new UsageError("BASE_IMAGE is SOURCE; do not pass it as --build-arg");
  print(await extendImage({ source: positionals[0], context: values.context, image: values.image, platform: values.platform, buildArgs }));
}

async function exportArchives(args: string[]): Promise<void> {
  const { values, positionals } = parseArgs({ args, allowPositionals: true, options: { output: { type: "string" } } });
  if (!positionals.length || !values.output) throw new UsageError("image export takes one or more IMAGE:TAG and --output");
  if (positionals.some(reference => !/:[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(reference) || reference.includes("@"))) {
    throw new UsageError("image export needs a tag on every image; the tag names the archive");
  }
  print(await exportImages(positionals, values.output));
}

async function list(args: string[]): Promise<void> {
  const { values, positionals } = parseArgs({ args, allowPositionals: true, options: { record: { type: "string" } } });
  if (positionals.length !== 1) throw new UsageError("feature list takes one IMAGE");
  const listed = await listFeatures(positionals[0]);
  if (values.record) recordFeatures(values.record, listed.features);
  print(listed);
}

class CheckError extends Error {}

async function check(args: string[]): Promise<void> {
  const { positionals } = parseArgs({ args, allowPositionals: true, options: {} });
  if (positionals.length !== 1) throw new UsageError("feature check takes RECIPE");
  const findings = checkStack(positionals[0]);
  print({ findings });
  if (findings.length) throw new CheckError(`${findings.length} violation(s) of the Feature SDK contract`);
}

const commands: Record<string, Record<string, (args: string[]) => Promise<void>>> = {
  image: { build, push, pull, extend, export: exportArchives },
  feature: { publish, check, list },
};

async function main([group, command, ...rest]: string[]): Promise<number> {
  if (!group || group === "--help" || group === "-h" ||
      (Object.hasOwn(commands, group) && (!command || command === "--help" || command === "-h"))) {
    console.log(usage);
    return 0;
  }
  const handler = Object.hasOwn(commands, group) && command && Object.hasOwn(commands[group], command)
    ? commands[group][command] : undefined;
  if (!handler) throw new UsageError(`Unknown command: ${[group, command].filter(Boolean).join(" ")}`);
  await handler(rest);
  return 0;
}

try {
  process.exitCode = await main(process.argv.slice(2));
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  if (error instanceof UsageError || (error as { code?: string }).code?.startsWith("ERR_PARSE_ARGS")) {
    console.error(`wisehub: ${message}\n\n${usage}`);
    process.exitCode = 2;
  } else {
    console.error(`wisehub${error instanceof RegistryError ? ` [${error.kind}]` : ""}: ${message}`);
    process.exitCode = 1;
  }
}
