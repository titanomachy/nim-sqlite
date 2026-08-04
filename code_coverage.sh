#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

nim="${NIM:-nim}"
coverage_cache="$repo_root/build/nimcache/coverage"
coverage_report="$repo_root/coverage.info"

echo "Cleaning previous coverage output..."
rm -rf "$coverage_cache" "$repo_root/coverage_html"
rm -f "$coverage_report" "$repo_root/docs/coverage.svg"
mkdir -p "$coverage_cache"

echo "Compiling and running tests with coverage instrumentation..."
"$nim" c \
  --debugger:native \
  --passC:--coverage \
  --passL:--coverage \
  --path:src \
  --nimcache:"$coverage_cache" \
  --out:"$repo_root/build/tests_coverage" \
  -r tests/tests.nim

echo "Capturing and filtering project coverage..."
lcov \
  --ignore-errors inconsistent,unused,mismatch,missing,source,empty,gcov,range \
  --filter range \
  --capture \
  --directory "$coverage_cache" \
  --output-file "$coverage_report"
lcov \
  --ignore-errors inconsistent,unused,mismatch,missing,source,empty,gcov \
  --extract "$coverage_report" "$repo_root/src/*" \
  --output-file "$coverage_report"

echo "Generating HTML report and coverage badge..."
genhtml \
  --ignore-errors inconsistent,corrupt,range \
  "$coverage_report" \
  --output-directory "$repo_root/coverage_html"
scripts/coverage_badge.sh "$coverage_report" "$repo_root/docs/coverage.svg"

echo "Coverage report written to coverage_html/index.html"
