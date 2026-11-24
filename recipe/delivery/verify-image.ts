import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

/** Runs verify.sh in the image as an unprivileged user without network or GPU. */
export function verifyImage(docker: string, image: string, variant: string): void {
  execFileSync(docker, ["run", "--rm", "-i", "--user", "65534:65534", "--network", "none",
    "--tmpfs", "/tmp:mode=1777", "--shm-size=2g", "-e", "WISE_VERIFY_GPU=0", "--entrypoint", "/bin/sh",
    image, "-s", variant], {
    input: readFileSync(new URL("verify.sh", import.meta.url)),
    stdio: ["pipe", "inherit", "inherit"],
  });
}
