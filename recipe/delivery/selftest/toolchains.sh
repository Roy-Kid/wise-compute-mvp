#!/bin/sh
set -eu
python3 -c 'import ssl, sqlite3; assert sqlite3.connect(":memory:").execute("select 6 * 7").fetchone() == (42,)'
conda --version
uv --version
node -e 'const assert = require("node:assert/strict"); assert.equal(Buffer.from("2a", "hex")[0], 42)'
npm --version
cargo --version
printf '%s\n' 'fn main() { assert_eq!(6 * 7, 42); }' > src.rs
rustc src.rs -o sample-rust
./sample-rust
