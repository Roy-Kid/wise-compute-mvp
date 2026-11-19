export const digestPattern = /^sha256:[a-f0-9]{64}$/;

const platformPattern = /^[a-z0-9]+\/[a-z0-9]+(?:\/[a-z0-9]+)?$/;
const hostPattern = /^[a-z0-9]+(?:[.-][a-z0-9]+)*(?::[0-9]+)?$/;
const repositoryPattern = /^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:\/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*$/;
const tagPattern = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/;

export function parsePlatform(platform: string): string {
  if (!platformPattern.test(platform)) throw new Error(`Expected platform OS/ARCH[/VARIANT], got ${platform}`);
  return platform;
}

/** True when `actual` satisfies `requested`; an OS/ARCH request accepts any variant. */
export function platformMatches(requested: string, actual: string): boolean {
  return actual === requested || (requested.split("/").length === 2 && actual.startsWith(requested + "/"));
}

/** A fully qualified remote image reference. */
export interface RemoteReference {
  /** Registry host and repository path, e.g. harbor.will/wise-compute/research. */
  repository: string;
  tag?: string;
  digest?: string;
}

/**
 * Parses REGISTRY/PATH:TAG or REGISTRY/PATH@DIGEST. The registry host must be explicit
 * (contain a dot or port, or be localhost) so that nothing silently resolves to Docker Hub.
 */
export function parseRemoteReference(reference: string): RemoteReference {
  const invalid = () => new Error(`Expected REGISTRY/REPOSITORY:TAG or REGISTRY/REPOSITORY@DIGEST, got ${reference}`);
  const slash = reference.indexOf("/");
  if (slash === -1) throw invalid();
  const host = reference.slice(0, slash);
  if (!hostPattern.test(host) || !(/[.:]/.test(host) || host === "localhost")) throw invalid();

  const rest = reference.slice(slash + 1);
  const at = rest.indexOf("@");
  if (at !== -1) {
    const [path, digest] = [rest.slice(0, at), rest.slice(at + 1)];
    if (!repositoryPattern.test(path) || !digestPattern.test(digest)) throw invalid();
    return { repository: `${host}/${path}`, digest };
  }
  const colon = rest.lastIndexOf(":");
  const [path, tag] = colon === -1 ? [rest, ""] : [rest.slice(0, colon), rest.slice(colon + 1)];
  if (!repositoryPattern.test(path) || !tagPattern.test(tag)) throw invalid();
  return { repository: `${host}/${path}`, tag };
}
