#!/bin/sh
set -eu

# Fetch exactly one pinned commit: no history, no tags.
fetch() { # url commit dir
    git init --quiet "$3"
    git -C "$3" fetch --quiet --depth 1 --no-tags "$1" "$2"
    git -C "$3" checkout --quiet FETCH_HEAD
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fetch https://github.com/wannier-developers/wannier90.git 1d6b187374a2d50b509e5e79e2cab01a79ff7ce1 "$work"
cp "$work/config/make.inc.gfort" "$work/make.inc"
make -C "$work" -j"$(nproc)" wannier
install -m 755 "$work/wannier90.x" /opt/wise/bin/
