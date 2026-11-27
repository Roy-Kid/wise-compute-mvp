#!/bin/sh
set -eu
wise_id=nodejs
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

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
wise_download "https://nodejs.org/dist/v$version/$archive" "$checksum" "$work/$archive"
# The archive records its builder as owner (1000); the files and the directories they share belong to root.
tar -xJf "$work/$archive" --strip-components=1 --no-same-owner -C /usr/local
wise_done
