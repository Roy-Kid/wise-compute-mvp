#!/bin/sh
set -eu

test "$(node --version)" = "v24.22.3"
npm --version
