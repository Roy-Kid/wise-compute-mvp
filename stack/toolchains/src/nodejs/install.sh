#!/bin/sh
set -eu
. /opt/wise/lib/wise/feature.sh nodejs

wise_apt ca-certificates curl xz-utils

case "$(uname -m)" in
    x86_64) arch=x64; checksum=4f2b175a6d53a5c617a80dba2676238a0688cef28c6da4eba35c7d844e66fcfb ;;
    aarch64) arch=arm64; checksum=6e51a2ada00f0011cc266f65d98922b403d7ad88f809ca2aa615a5fe1ce6e86c ;;
    *) wise_fail "unsupported architecture for Node.js" ;;
esac
version=24.22.3
archive="node-v$version-linux-$arch.tar.xz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' \
    "https://nodejs.org/dist/v$version/$archive" -o "$work/$archive"
printf '%s  %s\n' "$checksum" "$work/$archive" | sha256sum --check
tar -xJf "$work/$archive" --strip-components=1 -C /usr/local
wise_done
