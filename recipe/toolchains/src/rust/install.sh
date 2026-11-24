#!/bin/sh
set -eu
wise_id=rust
. /opt/wise/lib/wise/feature.sh

wise_apt rustc cargo gcc
wise_done
