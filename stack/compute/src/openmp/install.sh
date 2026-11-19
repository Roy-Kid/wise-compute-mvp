#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends libgomp1
rm -rf /var/lib/apt/lists/*
