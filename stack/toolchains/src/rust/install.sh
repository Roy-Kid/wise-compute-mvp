#!/bin/sh
set -eu
. /opt/wise/lib/wise/feature.sh rust

wise_apt rustc cargo gcc
wise_done
