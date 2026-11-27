// What follows a build on the way to a machine that runs the image: a layer on top of the finished
// image, the list of Features it holds, and archives with checksums for hand-over.
import { createHash } from "node:crypto";
import { createReadStream, readFileSync, writeFileSync } from "node:fs";
import { chmod, mkdir, rename, rm, stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { Docker } from "./docker.ts";
import type { LocalImage } from "./docker.ts";
import { checked, run } from "./process.ts";
import type { Run } from "./process.ts";

export interface ExtendOptions {
  /** The finished image the layer builds on; the Dockerfile receives it as BASE_IMAGE. */
  source: string;
  /** Build context holding the Dockerfile. */
  context: string;
  image: string;
  platform?: string;
  buildArgs?: Record<string, string>;
}

export interface ExtendResult extends LocalImage {
  base: LocalImage;
}

/** Builds a Dockerfile on top of a local image, as the platform entrance of recipe/delivery/compute is. */
export async function extendImage(options: ExtendOptions, docker = new Docker(), execute: Run = run): Promise<ExtendResult> {
  if ("BASE_IMAGE" in (options.buildArgs ?? {})) throw new Error("BASE_IMAGE is the source image; do not pass it as a build argument");
  const base = await docker.inspectImage(options.source, options.platform);
  const args = ["build", "--build-arg", `BASE_IMAGE=${options.source}`];
  if (options.platform) args.push("--platform", options.platform);
  for (const [name, value] of Object.entries(options.buildArgs ?? {})) args.push("--build-arg", `${name}=${value}`);
  await checked(docker.binary, execute(docker.binary, [...args, "--tag", options.image, resolve(options.context)], { stdio: "tee" }));
  return { ...await docker.inspectImage(options.image, options.platform), base };
}

/** `id version` lines of wise-features; a Feature registered by an SDK before 4 has no version. */
export function parseFeatures(listing: string): Record<string, string | null> {
  const features: Record<string, string | null> = {};
  for (const line of listing.split("\n").filter(Boolean)) {
    const [id, version, ...extra] = line.split(" ");
    if (!id || !version || extra.length) throw new Error(`wise-features printed an unexpected line: ${line}`);
    features[id] = version === "-" ? null : version;
  }
  return features;
}

const listingScript = `if command -v wise-features > /dev/null; then exec wise-features; fi
for record in /usr/local/share/devcontainer-features/*; do
    if [ -f "$record" ]; then echo "$(basename "$record") -"; fi
done`;

export interface FeatureList {
  image: LocalImage;
  features: Record<string, string | null>;
}

/** The Features an image holds, from the registry its core Feature keeps. */
export async function listFeatures(image: string, docker = new Docker(), execute: Run = run): Promise<FeatureList> {
  const local = await docker.inspectImage(image);
  // The image's own entry point may be a service, so a shell is the entry point here. An image built with
  // an SDK before 4 has no wise-features; its registry still names the Features, without versions.
  const listing = await checked(docker.binary, execute(docker.binary,
    ["run", "--rm", "--network", "none", "--entrypoint", "sh", local.id, "-c", listingScript]));
  return { image: local, features: parseFeatures(listing) };
}

/** Writes the Feature table into a release record, a JSON object in a file; other fields stay. */
export function recordFeatures(file: string, features: Record<string, string | null>): void {
  const unversioned = Object.keys(features).filter(id => features[id] === null);
  if (unversioned.length) {
    throw new Error(`No version is recorded for ${unversioned.join(", ")}: the image was built with a Feature SDK before 4`);
  }
  if (!Object.keys(features).length) throw new Error("The image lists no Feature");
  const record = JSON.parse(readFileSync(file, "utf8"));
  writeFileSync(file, JSON.stringify({ ...record, features }, null, 2) + "\n");
}

export interface ExportedImage extends LocalImage {
  file: string;
  bytes: number;
  sha256: string;
}

export interface ExportResult {
  directory: string;
  exported: string;
  images: ExportedImage[];
}

function sha256(file: string): Promise<string> {
  return new Promise((done, fail) => {
    const hash = createHash("sha256");
    createReadStream(file).on("data", chunk => hash.update(chunk)).on("error", fail).on("end", () => done(hash.digest("hex")));
  });
}

/**
 * Saves tagged local images as `<tag>.tar.zst` with a `sha256sum` file each and one `manifest.json`.
 * `docker load` restores an archive under the reference it was saved with.
 */
export async function exportImages(references: readonly string[], directory: string, docker = new Docker(),
  execute: Run = run, now = () => new Date()): Promise<ExportResult> {
  const names = references.map(reference => {
    const tag = /:([A-Za-z0-9_][A-Za-z0-9_.-]*)$/.exec(reference)?.[1];
    if (!tag || reference.includes("@")) throw new Error(`${reference} needs a tag, which names its archive`);
    return tag;
  });
  const repeated = names.find((name, index) => names.indexOf(name) !== index);
  if (repeated) throw new Error(`Two images share the tag ${repeated} and would share an archive`);
  const out = resolve(directory);
  await mkdir(out, { recursive: true });
  const images: ExportedImage[] = [];
  for (const [index, reference] of references.entries()) {
    const local = await docker.inspectImage(reference);
    const file = `${names[index]}.tar.zst`;
    const tar = join(out, `${names[index]}.tar.partial`);
    const partial = join(out, `${file}.partial`);
    try {
      await checked(docker.binary, execute(docker.binary, ["image", "save", "--output", tar, reference]));
      await checked("zstd", execute("zstd", ["-T0", "-3", "--quiet", "--force", "--rm", tar, "-o", partial]));
      const digest = await sha256(partial);
      const { size } = await stat(partial);
      // Only a complete archive carries the final name.
      // docker saves for its own user only; the folder is handed to others.
      await chmod(partial, 0o644);
      await rename(partial, join(out, file));
      writeFileSync(join(out, `${file}.sha256`), `${digest}  ${file}\n`);
      images.push({ ...local, file, bytes: size, sha256: digest });
    } finally {
      await rm(tar, { force: true });
      await rm(partial, { force: true });
    }
  }
  const result = { directory: out, exported: now().toISOString(), images };
  writeFileSync(join(out, "manifest.json"), JSON.stringify({ exported: result.exported, images }, null, 2) + "\n");
  return result;
}
