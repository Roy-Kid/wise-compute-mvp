import { checked } from "./process.js";
import type { Run } from "./process.js";

export const digestPattern = /^sha256:[a-f0-9]{64}$/;

export interface LocalImage {
  reference: string;
  id: string;
  platform: string;
}

export function validatePlatform(platform: string): void {
  if (!/^[a-z0-9]+\/[a-z0-9]+(?:\/[a-z0-9]+)?$/.test(platform)) {
    throw new Error("Expected platform OS/ARCH[/VARIANT]");
  }
}

export async function localImage(
  execute: Run, docker: string, reference: string, platform?: string, signal?: AbortSignal,
): Promise<LocalImage> {
  const args = ["image", "inspect", "--format", "{{json .}}"];
  if (platform) args.push("--platform", platform);
  const image = JSON.parse(checked(await execute(docker, [...args, "--", reference], { signal })));
  const actual = [image.Os, image.Architecture, image.Variant].filter(Boolean).join("/");
  if (!digestPattern.test(image.Id) || !image.Os || !image.Architecture) {
    throw new Error("Docker returned incomplete image metadata");
  }
  if (platform && actual !== platform &&
      !(platform.split("/").length === 2 && actual.startsWith(platform + "/"))) {
    throw new Error(`Expected image platform ${platform}, got ${actual}`);
  }
  return { reference, id: image.Id, platform: actual };
}
