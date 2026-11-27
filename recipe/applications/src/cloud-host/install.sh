#!/bin/sh
set -eu
wise_id=cloud-host
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

src=$(dirname "$0")
wise_apt \
    ca-certificates git curl wget jq ripgrep rsync openssh-client patch diffutils file \
    tar gzip bzip2 xz-utils zip unzip zstd \
    cmake ninja-build \
    fontconfig fonts-noto-cjk fonts-dejavu-core fonts-liberation fonts-droid-fallback poppler-utils
test -r "${WISE_REPORT_FONT:?}"

pip=${WISE_VENV:?}/bin/pip
"$pip" install --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r "$src/requirements.txt"
"$pip" check

# Matplotlib 3.10 only loads the first face of a font collection, which is the Japanese face in Ubuntu's TTC.
"$WISE_VENV/bin/python" - <<'PYTHON'
from pathlib import Path

from fontTools.ttLib import TTCollection

source = Path("/usr/share/fonts/opentype/noto")
destination = Path("/usr/local/share/fonts/wise-cloud")
destination.mkdir(parents=True, exist_ok=True)
for weight in ("Regular", "Bold"):
    collection = TTCollection(source / f"NotoSansCJK-{weight}.ttc", lazy=True)
    try:
        font = next(font for font in collection.fonts if font["name"].getBestFamilyName() == "Noto Sans CJK SC")
        font.save(destination / f"NotoSansCJKsc-{weight}.otf")
    finally:
        collection.close()
PYTHON
fc-cache -f
install -D -m 0644 "$src/matplotlibrc" "${MATPLOTLIBRC:?}"
wise_done
