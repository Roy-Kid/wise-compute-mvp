#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends mpich libmpich-dev
mkdir -p /opt/wise && echo "mpich $(dpkg-query -W -f='${Version}' mpich)" >> /opt/wise/install.log
rm -rf /var/lib/apt/lists/*
