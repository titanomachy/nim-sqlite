#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/nimcache/docs docs
"${NIM_BIN:-nim}" doc --path:src --nimcache:build/nimcache/docs \
  -o:docs/index.html src/nim_sqlite.nim

# Nim may emit CRLF in the CSS even on Linux. Keep tracked output stable.
sed -i 's/\r$//; s/[[:blank:]]*$//' docs/index.html docs/nimdoc.out.css
sed -E -i 's/Generated: [0-9-]+ [0-9:]+ UTC/Generated from source/' docs/index.html
