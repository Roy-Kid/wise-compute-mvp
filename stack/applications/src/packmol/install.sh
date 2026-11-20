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
fetch https://github.com/m3g/packmol.git d70e10b13033dfbd3eb4d00b1b803989f17b1452 "$work/src"
cmake -S "$work/src" -B "$work/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/wise
cmake --build "$work/build" -j"$(nproc)"
cmake --install "$work/build"
test -x /opt/wise/bin/packmol
