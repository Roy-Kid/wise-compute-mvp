#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl
rm -rf /var/lib/apt/lists/*

case "$(uname -m)" in
    x86_64) arch=x86_64; checksum=376b160ed8130820db0ab0f3826ac1fc85923647f75c1b8231166e3d559ab768 ;;
    *) echo "Unsupported architecture for Conda" >&2; exit 1 ;;
esac
version=25.3.1-0
archive="Miniforge3-$version-Linux-$arch.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' \
    "https://github.com/conda-forge/miniforge/releases/download/$version/$archive" -o "$work/$archive"
printf '%s  %s\n' "$checksum" "$work/$archive" | sha256sum --check
bash "$work/$archive" -b -p /opt/conda
/opt/conda/bin/conda clean --all --yes
ln -s /opt/conda/bin/conda /usr/local/bin/conda
