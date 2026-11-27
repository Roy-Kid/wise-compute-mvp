#!/bin/sh
set -eu
wise_id=rust
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

wise_apt rustc cargo gcc
wise_done
