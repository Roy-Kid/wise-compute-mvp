import { Docker, RegistryError } from "./docker.ts";
import type { Descriptor, LocalImage } from "./docker.ts";
import { digestPattern, parsePlatform, parseRemoteReference } from "./reference.ts";

export interface PushResult {
  tag: string;
  digest: string;
  /** repository@digest: the immutable reference callers should record. */
  reference: string;
}

export interface PullResult {
  digest: string;
  reference: string;
  image: LocalImage;
  /** For an index, the platform manifest whose config matches the pulled image. */
  platformManifestDigest?: string;
}

/** Push and pull through any OCI registry Docker is configured to reach. */
export class OciRegistry {
  private readonly docker: Docker;

  constructor(docker = new Docker()) {
    this.docker = docker;
  }

  /**
   * Publishes one platform of `source` as `target` (REGISTRY/REPOSITORY:TAG) and confirms the
   * registry stores that exact image. Idempotent: if the tag already holds the source image,
   * nothing is pushed. With immutable enabled, an existing tag for another image is a conflict.
   */
  async push(source: string, target: string, { immutable = false } = {}): Promise<PushResult> {
    const { repository, tag } = parseRemoteReference(target);
    if (!tag) throw new Error(`Push needs an explicit tag, got ${target}`);
    const image = await this.docker.inspectImage(source);
    const result = (digest: string): PushResult => ({ tag: target, digest, reference: `${repository}@${digest}` });

    const current = await this.docker.describe(target);
    if (current) {
      if (await this.docker.configDigest(`${repository}@${current.digest}`) === image.id) return result(current.digest);
      if (immutable) throw new RegistryError("conflict", `${target} already points to a different image`);
    }

    await this.docker.tag(image.id, target);
    const pushed = result(await this.docker.push(target, image.platform));
    const stored = await this.docker.describe(pushed.reference);
    if (stored?.digest !== pushed.digest || await this.docker.configDigest(pushed.reference) !== image.id) {
      throw new RegistryError("integrity", "Registry manifest does not match the source image");
    }
    return pushed;
  }

  /** Resolves `reference` once, then pulls by digest so a moving tag cannot change what is fetched. */
  async pull(reference: string, platform?: string): Promise<PullResult> {
    const { repository, digest: requested } = parseRemoteReference(reference);
    if (platform) parsePlatform(platform);
    const descriptor = await this.docker.describe(reference);
    if (!descriptor) throw new RegistryError("missing", `${reference} does not exist`);
    if (requested && descriptor.digest !== requested) {
      throw new RegistryError("integrity", "Registry digest differs from the requested digest");
    }
    const pinned = `${repository}@${descriptor.digest}`;
    await this.docker.pull(pinned, platform);
    const image = await this.docker.inspectImage(pinned, platform);
    const platformManifestDigest = descriptor.manifests
      ? await this.findPlatformManifest(repository, descriptor.manifests, image)
      : descriptor.digest;
    return { digest: descriptor.digest, reference: pinned, image, platformManifestDigest };
  }

  private async findPlatformManifest(
    repository: string, manifests: NonNullable<Descriptor["manifests"]>, image: LocalImage,
  ): Promise<string | undefined> {
    const [os, architecture, variant] = image.platform.split("/");
    const candidates = manifests.filter(({ platform, digest }) =>
      platform?.os === os && platform.architecture === architecture &&
      (!variant || !platform.variant || platform.variant === variant) && digestPattern.test(digest));
    for (const { digest } of candidates) {
      if (await this.docker.configDigest(`${repository}@${digest}`) === image.id) return digest;
    }
    return undefined;
  }
}
