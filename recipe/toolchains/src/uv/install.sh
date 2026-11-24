#!/bin/sh
set -eu
wise_id=uv
. /opt/wise/lib/wise/feature.sh

wise_apt ca-certificates curl

case "$(uname -m)" in
    x86_64) arch=x86_64; checksum=30ccbf0a66dc8727a02b0e245c583ee970bdafecf3a443c1686e1b30ec4939e8 ;;
    aarch64) arch=aarch64; checksum=f71040c59798f79c44c08a7a1c1af7de95a8d334ea924b47b67ad6b9632be270 ;;
    *) wise_fail "unsupported architecture for uv" ;;
esac
version=0.9.26
archive="uv-$arch-unknown-linux-gnu.tar.gz"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
wise_download "https://github.com/astral-sh/uv/releases/download/$version/$archive" "$checksum" "$work/$archive"
tar -xzf "$work/$archive" --strip-components=1 -C "$work"
install -m 0755 "$work/uv" "$work/uvx" /usr/local/bin/
wise_done
