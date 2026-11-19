#!/usr/bin/env node
import { constants } from "node:os";
import { parseArgs } from "node:util";
import { DevContainerEngine } from "./engine.js";
import { OciRegistry, RegistryError } from "./registry.js";

function print(value: unknown): void {
  console.log(JSON.stringify(value, null, 2));
}

async function main(args: string[]): Promise<number> {
  const [group, action, ...rest] = args;
  if (!group || group === "--help" || group === "-h") {
    console.log("Usage: wisehub image <command> [options]");
    return 0;
  }
  if (group !== "image") throw new Error("Expected wisehub image <command>");
  if (!action || action === "--help" || action === "-h") {
    console.log([
      "wisehub image build-local --workspace-folder DIR [--config FILE] [--platform OS/ARCH]",
      "                          (--image TAG | --service-image SERVICE=TAG ...) [-- native build flags]",
      "WISE_REGISTRY=HOST wisehub image push SOURCE REPOSITORY:TAG",
      "WISE_REGISTRY=HOST wisehub image pull REFERENCE [--platform OS/ARCH]",
      "",
      "Native commands: build, up, set-up, run-user-commands, read-configuration,",
      "                 exec, outdated, upgrade, features, templates",
    ].join("\n"));
    return 0;
  }
  if (action === "build-local") {
    const delimiter = rest.indexOf("--");
    const upstream = delimiter === -1 ? [] : rest.slice(delimiter + 1);
    const { values } = parseArgs({
      args: delimiter === -1 ? rest : rest.slice(0, delimiter),
      options: {
        "workspace-folder": { type: "string", default: "." },
        config: { type: "string" },
        platform: { type: "string" },
        image: { type: "string" },
        "service-image": { type: "string", multiple: true },
      },
    });
    const services = (values["service-image"] ?? []).map(entry => {
      const [service, image, extra] = entry.split("=");
      if (!service || !image || extra !== undefined) throw new Error("Expected SERVICE=IMAGE");
      return { service, image };
    });
    if (Boolean(values.image) === Boolean(services.length) ||
        new Set(services.map(item => item.service)).size !== services.length) {
      throw new Error("Declare one image or a set of distinct Compose service images");
    }
    print(await new DevContainerEngine().build({
      workspace: values["workspace-folder"],
      config: values.config,
      platform: values.platform,
      output: values.image ? { image: values.image } : { services },
      args: upstream,
    }));
    return 0;
  }
  if (action === "push" || action === "pull") {
    const registry = process.env.WISE_REGISTRY;
    if (!registry) throw new Error("Set WISE_REGISTRY to the OCI registry hostname");
    const backend = new OciRegistry(registry);
    if (action === "push" && rest.length === 2) {
      print(await backend.push(rest[0], rest[1]));
      return 0;
    }
    if (action === "pull") {
      const { values, positionals } = parseArgs({
        args: rest, allowPositionals: true, options: { platform: { type: "string" } },
      });
      if (positionals.length === 1) {
        print(await backend.pull(positionals[0], values.platform));
        return 0;
      }
    }
    throw new Error("Invalid image push or pull arguments; see wisehub image --help");
  }
  const result = await new DevContainerEngine().invoke({ args: args.slice(1) });
  return result.signal ? 128 + constants.signals[result.signal] : result.code;
}

try {
  process.exitCode = await main(process.argv.slice(2));
} catch (error) {
  const kind = error instanceof RegistryError ? ` [${error.kind}]` : "";
  console.error(`wisehub${kind}: ${error instanceof Error ? error.message : error}`);
  process.exitCode = 1;
}
