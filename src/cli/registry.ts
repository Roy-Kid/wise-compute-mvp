import { digestPattern, localImage, validatePlatform } from "./image.js";
import type { LocalImage } from "./image.js";
import { checked, CommandError, run } from "./process.js";
import type { Run } from "./process.js";

export interface PushResult {
  tag: string;
  digest: string;
  reference: string;
}

export interface PullResult {
  digest: string;
  reference: string;
  image: LocalImage;
  platformManifestDigest?: string;
}

interface RegistryDescriptor {
  digest: string;
  manifests?: {
    digest: string;
    platform?: { os: string; architecture: string; variant?: string };
  }[];
}

export interface ImageBackend {
  push(source: string, target: string, signal?: AbortSignal): Promise<PushResult>;
  pull(reference: string, platform?: string, signal?: AbortSignal): Promise<PullResult>;
}

type ErrorKind = "authentication" | "permission" | "missing" | "conflict" | "temporary" | "integrity" | "backend";

export class RegistryError extends Error {
  constructor(readonly kind: ErrorKind, message: string) {
    super(message);
  }
}

function registryError(error: unknown): never {
  if (!(error instanceof CommandError)) throw error;
  const patterns: [ErrorKind, RegExp][] = [
    ["conflict", /immutable|conflict|\b409\b/i],
    ["authentication", /unauthorized|authentication required|\b401\b/i],
    ["permission", /denied|forbidden|\b403\b/i],
    ["missing", /manifest unknown|not found|\b404\b/i],
    ["temporary", /timeout|temporarily|connection reset|too many requests|\b(429|502|503|504)\b/i],
  ];
  const match = patterns.find(([, pattern]) => pattern.test(error.message));
  throw new RegistryError(match?.[0] ?? "backend", error.message);
}

const host = /^(?:[a-z0-9]+(?:[.-][a-z0-9]+)*)(?::[0-9]+)?$/;
const path = /^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:\/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*$/;
const tag = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/;

export class OciRegistry implements ImageBackend {
  constructor(private readonly registry: string, private readonly execute: Run = run,
              private readonly docker = "docker") {
    if (!host.test(registry) || !(/[.:]/.test(registry) || registry === "localhost")) {
      throw new Error("Expected an explicit OCI registry hostname, optionally with a port");
    }
  }

  private repository(reference: string, push: boolean): string {
    const prefix = this.registry + "/";
    if (!reference.startsWith(prefix)) throw new Error(`Expected a reference under ${prefix}`);
    const suffix = reference.slice(prefix.length);
    const delimiter = suffix.includes("@") ? "@" : ":";
    const [name, revision, ...extra] = delimiter === "@" ? suffix.split("@") : suffix.split(":");
    if (!path.test(name) || !revision || extra.length ||
        (delimiter === "@" ? push || !digestPattern.test(revision) : !tag.test(revision))) {
      throw new Error("Expected a repository with an explicit tag or pull digest");
    }
    return prefix + name;
  }

  private async describe(reference: string, signal?: AbortSignal): Promise<RegistryDescriptor> {
    const descriptor = JSON.parse(checked(await this.execute(this.docker,
      ["buildx", "imagetools", "inspect", "--format", "{{json .Manifest}}", reference], { signal })));
    if (!digestPattern.test(descriptor.digest)) {
      throw new RegistryError("integrity", "Registry returned an invalid manifest digest");
    }
    return descriptor;
  }

  private async configDigest(reference: string, signal?: AbortSignal): Promise<string | undefined> {
    const manifest = JSON.parse(checked(await this.execute(this.docker,
      ["buildx", "imagetools", "inspect", "--raw", reference], { signal })));
    return manifest.config?.digest;
  }

  async push(source: string, target: string, signal?: AbortSignal): Promise<PushResult> {
    const repository = this.repository(target, true);
    try {
      const image = await localImage(this.execute, this.docker, source, undefined, signal);
      const finish = (digest: string) => ({ tag: target, digest, reference: `${repository}@${digest}` });
      try {
        const current = finish((await this.describe(target, signal)).digest);
        if (await this.configDigest(current.reference, signal) === image.id) return current;
      } catch (error) {
        try { registryError(error); } catch (classified) {
          if (!(classified instanceof RegistryError && classified.kind === "missing")) throw classified;
        }
      }
      checked(await this.execute(this.docker, ["image", "tag", image.id, target], { signal }));
      const output = checked(await this.execute(this.docker,
        ["image", "push", "--platform", image.platform, target], { signal, logs: true }));
      const digest = /^.+: digest: (sha256:[a-f0-9]{64}) size: \d+\s*$/m.exec(output)?.[1];
      if (!digest) throw new RegistryError("integrity", "Docker push did not report a digest");
      const result = finish(digest);
      if ((await this.describe(result.reference, signal)).digest !== digest ||
          await this.configDigest(result.reference, signal) !== image.id) {
        throw new RegistryError("integrity", "Registry manifest does not match the source image");
      }
      return result;
    } catch (error) {
      registryError(error);
    }
  }

  private async findPlatformManifest(
    repository: string, manifests: NonNullable<RegistryDescriptor["manifests"]>,
    image: LocalImage, signal?: AbortSignal,
  ): Promise<string | undefined> {
    const [os, arch, variant] = image.platform.split("/");
    const candidates = manifests.filter(({ platform, digest }) =>
      platform?.os === os && platform.architecture === arch &&
      (!variant || !platform.variant || platform.variant === variant) && digestPattern.test(digest));
    for (const candidate of candidates) {
      if (await this.configDigest(`${repository}@${candidate.digest}`, signal) === image.id) {
        return candidate.digest;
      }
    }
    return undefined;
  }

  async pull(request: string, platform?: string, signal?: AbortSignal): Promise<PullResult> {
    const repository = this.repository(request, false);
    if (platform) validatePlatform(platform);
    try {
      const { digest, manifests } = await this.describe(request, signal);
      if (request.includes("@") && !request.endsWith(`@${digest}`)) {
        throw new RegistryError("integrity", "Registry digest differs from the requested digest");
      }
      const reference = `${repository}@${digest}`;
      const args = ["image", "pull"];
      if (platform) args.push("--platform", platform);
      checked(await this.execute(this.docker, [...args, reference], { signal, logs: true }));
      const image = await localImage(this.execute, this.docker, reference, platform, signal);
      const platformManifestDigest = manifests
        ? await this.findPlatformManifest(repository, manifests, image, signal)
        : digest;
      return { digest, reference, image, platformManifestDigest };
    } catch (error) {
      registryError(error);
    }
  }
}
