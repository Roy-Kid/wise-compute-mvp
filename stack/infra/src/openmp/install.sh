#!/bin/sh
set -eu
. /opt/wise/lib/wise/feature.sh openmp

wise_apt ca-certificates curl git bzip2 xz-utils file perl python3 \
    build-essential gfortran libgomp1 cmake pkg-config zlib1g-dev
wise_done
