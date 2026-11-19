#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends openmpi-bin libopenmpi-dev
mkdir -p /opt/wise && echo "openmpi $(dpkg-query -W -f='${Version}' openmpi-bin)" >> /opt/wise/install.log
rm -rf /var/lib/apt/lists/*
