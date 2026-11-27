"""Writes the platform's sshd_config with its one SetEnv line carrying this image's environment.

    python3 session-env.py SOURCE TARGET

sshd runs with UsePAM no and gives a session none of the image's ENV, and it reads only the first
SetEnv line. The line therefore takes every variable of the image as this build step sees it, on top
of the platform's own defaults, so that a command over SSH finds what a command in the container finds.
"""
import os
import re
import sys

source, target = sys.argv[1:]
# What the build step, this interpreter (LC_CTYPE) or one container adds, and requests to the NVIDIA
# container runtime.
skipped = re.compile(r"HOSTNAME|PWD|OLDPWD|SHLVL|_|TERM|LC_CTYPE|DEBIAN_FRONTEND|SOURCE_DATE_EPOCH|BUILDKIT_.*|"
                     r"(?i:.*_proxy)|NVIDIA_.*|MELLANOX_VISIBLE_DEVICES")
lines = open(source).read().splitlines()
[index] = [i for i, line in enumerate(lines) if line.startswith("SetEnv ")]
session = dict(pair.split("=", 1) for pair in lines[index].split()[1:])
session.update((name, value) for name, value in os.environ.items() if not skipped.fullmatch(name))
# The platform mounts /work; its entrance creates the temporary directory there.
session.update(HOME="/work", TMPDIR="/work/.tmp")


def word(name, value):
    if re.search(r"""["'\\\n]""", value) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        raise SystemExit(f"sshd_config cannot carry {name}={value!r}")
    pair = f"{name}={value}"
    return f'"{pair}"' if re.search(r"[\s#]", pair) else pair


lines[index] = "SetEnv " + " ".join(word(name, value) for name, value in sorted(session.items()))
os.makedirs(os.path.dirname(target), exist_ok=True)
with open(target, "w") as file:
    file.write("\n".join(lines) + "\n")
