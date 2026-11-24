import { CommandError, checked, run } from "./process.ts";
import type { Run } from "./process.ts";
import { digestPattern, platformMatches } from "./reference.ts";

export interface LocalImage {
  reference: string;
  /** Image config digest, which is also the local image ID. */
  id: string;
  platform: string;
}

/** A registry manifest or index, as resolved by Buildx. */
export interface Descriptor {
  digest: string;
  manifests?: { digest: string; platform?: { os: string; architecture: string; variant?: string } }[];
}

export type RegistryErrorKind =
  | "authentication" | "permission" | "missing" | "conflict" | "temporary" | "integrity" | "backend";

export class RegistryError extends Error {
  readonly kind: RegistryErrorKind;

  constructor(kind: RegistryErrorKind, message: string) {
    super(message);
    this.kind = kind;
  }
}

// Docker only reports registry failures as text. Order matters: the first match wins.
// Docker prints "denied: requested access to the resource is denied" both for missing
// credentials and for missing rights, so it is reported as permission.
const errorPatterns: [RegistryErrorKind, RegExp][] = [
  ["conflict", /immutable|conflict|\b409\b/i],
  ["authentication", /unauthorized|authentication required|no basic auth credentials|\b401\b/i],
  ["permission", /denied|forbidden|\b403\b/i],
  ["missing", /manifest unknown|not found|\b404\b/i],
  ["temporary", /timeout|temporarily|connection reset|too many requests|\b(429|502|503|504)\b/i],
];

export function classify(error: CommandError): RegistryError {
  const kind = errorPatterns.find(([, pattern]) => pattern.test(error.message))?.[0] ?? "backend";
  return new RegistryError(kind, error.message);
}

/** The Docker CLI, the only process that talks to the daemon and to registries. */
export class Docker {
  readonly binary: string;
  private readonly execute: Run;

  constructor(execute: Run = run, binary = "docker") {
    this.execute = execute;
    this.binary = binary;
  }

  private exec(args: readonly string[], options?: Parameters<Run>[2]): Promise<string> {
    return checked(this.binary, this.execute(this.binary, args, options));
  }

  /** Runs a command that reaches a registry, translating failures into RegistryError. */
  private async remote(args: readonly string[], options?: Parameters<Run>[2]): Promise<string> {
    try {
      return await this.exec(args, options);
    } catch (error) {
      throw error instanceof CommandError ? classify(error) : error;
    }
  }

  async inspectImage(reference: string, platform?: string): Promise<LocalImage> {
    const image = await this.inspectVariant(reference);
    if (!platform || platformMatches(platform, image.platform)) return image;
    // `inspect --platform` needs Docker 28.1, so ask for a variant only when the default one differs.
    const selected = await this.inspectVariant(reference, platform).catch(() => image);
    if (!platformMatches(platform, selected.platform)) {
      throw new Error(`Expected ${reference} to be ${platform}, got ${selected.platform}`);
    }
    return selected;
  }

  private async inspectVariant(reference: string, platform?: string): Promise<LocalImage> {
    const args = ["image", "inspect", "--format", "{{json .}}"];
    if (platform) args.push("--platform", platform);
    const image = JSON.parse(await this.exec([...args, "--", reference]));
    if (!digestPattern.test(image.Id) || !image.Os || !image.Architecture) {
      throw new Error(`Docker returned incomplete metadata for ${reference}`);
    }
    return { reference, id: image.Id, platform: [image.Os, image.Architecture, image.Variant].filter(Boolean).join("/") };
  }

  async tag(source: string, target: string): Promise<void> {
    await this.exec(["image", "tag", source, target]);
  }

  async removeImage(reference: string): Promise<void> {
    await this.exec(["image", "rm", reference]);
  }

  /** Pushes one platform of a tagged image and returns the manifest digest Docker reports. */
  async push(reference: string, platform: string): Promise<string> {
    const output = await this.remote(["image", "push", "--platform", platform, reference], { stdio: "tee" });
    const digest = /^.+: digest: (sha256:[a-f0-9]{64}) size: \d+\s*$/m.exec(output)?.[1];
    if (!digest) throw new RegistryError("integrity", "Docker push did not report a digest");
    return digest;
  }

  async pull(reference: string, platform?: string): Promise<void> {
    const args = ["image", "pull"];
    if (platform) args.push("--platform", platform);
    await this.remote([...args, reference], { stdio: "tee" });
  }

  /** Resolves a remote reference to its descriptor, or undefined when the registry has no such manifest. */
  async describe(reference: string): Promise<Descriptor | undefined> {
    let output: string;
    try {
      output = await this.remote(["buildx", "imagetools", "inspect", "--format", "{{json .Manifest}}", reference]);
    } catch (error) {
      if (error instanceof RegistryError && error.kind === "missing") return undefined;
      throw error;
    }
    const descriptor = JSON.parse(output) as Descriptor;
    if (!digestPattern.test(descriptor.digest)) {
      throw new RegistryError("integrity", `Registry returned an invalid digest for ${reference}`);
    }
    return descriptor;
  }

  /** The config digest of a single-platform manifest; undefined for an index. */
  async configDigest(reference: string): Promise<string | undefined> {
    const manifest = JSON.parse(await this.remote(["buildx", "imagetools", "inspect", "--raw", reference]));
    return manifest.config?.digest;
  }
}
