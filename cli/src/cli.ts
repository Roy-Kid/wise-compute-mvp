#!/usr/bin/env node
import { parseArgs } from "node:util";
import { DevContainerBuilder } from "./build.ts";
import { RegistryError } from "./docker.ts";
import { FeaturePublisher } from "./features.ts";
import { OciRegistry } from "./registry.ts";

const usage = `Usage:
  wisehub image build [--workspace-folder DIR] [--config FILE] [--platform OS/ARCH] [--base-image REF] [--local-features RECIPE]
                      (--image NAME | --service-image SERVICE=NAME ...) [-- devcontainer build flags]
  wisehub image push SOURCE REGISTRY/REPOSITORY:TAG
  wisehub image pull REGISTRY/REPOSITORY(:TAG|@DIGEST) [--platform OS/ARCH]
  wisehub feature publish RECIPE --registry HOST --namespace NAMESPACE

--local-features builds with the recipe's Feature sources in place of their registry references.
--base-image overrides the Dockerfile's BASE_IMAGE build argument.
feature publish pushes each collection RECIPE/<collection>/src to HOST/NAMESPACE/<collection>, lowest first.

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

const commands: Record<string, Record<string, (args: string[]) => Promise<void>>> = {
  image: { build, push, pull },
  feature: { publish },
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
