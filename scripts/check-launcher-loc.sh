#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# This script is MPL-2.0; it holds no prose.
# check-launcher-loc.sh — the launcher stays under 1,000 lines of our own code (CLAUDE.md, ROADMAP Phase 1).
# Counts lines in src/**/*.rs that are neither blank nor comments (doc comments and doctests included in "comments").
# src/errors_gen.rs is excluded: scripts/gen-errors-rs.sh writes it from src/errors/errors.toml.
# Tests count: anything under src/ is launcher code. Prints the count per file and fails over the cap.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); cap=1000; total=0
while IFS= read -r f; do
  n=$(awk '{ sub(/^[ \t]+/, "") } $0 != "" && $0 !~ /^\/\// { n++ } END { print n + 0 }' "$f")
  printf '%5d  %s\n' "$n" "${f#"$R"/}"; total=$((total + n))
done < <(find "$R/src" -name '*.rs' ! -name errors_gen.rs | sort)
printf '%5d  total (cap %d)\n' "$total" "$cap"
[ "$total" -lt "$cap" ] || { echo "check-launcher-loc: the launcher has $total lines of its own code; the cap is $cap" >&2; exit 1; }
