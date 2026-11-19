#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends openmpi-bin libopenmpi-dev
rm -rf /var/lib/apt/lists/*
