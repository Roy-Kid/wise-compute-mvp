#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git bzip2 xz-utils file perl python3 \
    build-essential gfortran libgomp1 cmake pkg-config zlib1g-dev
rm -rf /var/lib/apt/lists/*

mkdir -p /opt/wise/bin /opt/wise/lib /opt/wise/include
echo /opt/wise/lib > /etc/ld.so.conf.d/wise.conf
ldconfig
