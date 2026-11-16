#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# gen-matrix.sh — emit the CI build matrix (json) or the support table (adoc) from src/definitions/targets.toml.
# usage: scripts/gen-matrix.sh json|adoc [--tier N]
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); mode=${1:?json|adoc}; tier=99; [ "${2:-}" = --tier ] && tier=$3
J=$("$R/scripts/lib/toml2json.sh" "$R/src/definitions/targets.toml" | jq --argjson t "$tier" '[.target[] | select(.tier <= $t)]')
case "$mode" in
  json) jq -c '{include: map({triple, runner, chez_machine, os})}' <<< "$J";;
  adoc) echo '[cols="3,1,2,2,3",options="header"]'; echo '|==='; echo '| Target triple | Tier | Chez machine | Floor | Runner'
        jq -r '.[] | "| `\(.triple)` | \(.tier) | `\(.chez_machine)` | \(if .min_glibc then "glibc \(.min_glibc)" elif .min_macos then "macOS \(.min_macos)" else "-" end) | `\(.runner)`"' <<< "$J"; echo '|===';;
  *) echo "usage: gen-matrix.sh json|adoc [--tier N]" >&2; exit 2;;
esac
