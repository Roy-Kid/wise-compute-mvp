#!/bin/sh
set -eu

test "$(uv --version)" = "uv 0.9.26"
uvx --version
