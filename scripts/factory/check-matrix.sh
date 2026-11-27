#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
# check-matrix.sh — fail if the build matrix of .github/workflows/factory.yml and the Tier 1 rows of
# src/definitions/targets.toml differ.
# usage: check-matrix.sh [WORKFLOW_FILE]   (default .github/workflows/factory.yml, relative to the repository)
# Compares, as sets, the triples of the `capsule` job matrix and of the `attest` job matrix with the Tier 1 triples, and for
# each `capsule` entry its runner and chez_machine with targets.toml. A missing, extra or changed entry is an error (exit 1).
# Needs yq (mikefarah, the Go version, which GitHub's Ubuntu runners have) and jq.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
wf=${1:-$root/.github/workflows/factory.yml}
die() { echo "check-matrix: FAIL: $*" >&2; exit 1; }
for c in yq jq; do command -v "$c" >/dev/null 2>&1 || die "$c is not installed"; done
[ -f "$wf" ] || die "no such workflow: $wf"
want=$("$root/scripts/gen-matrix.sh" json --tier 1 | jq -c '[.include[] | {triple, runner, chez_machine}] | sort_by(.triple)')
[ "$(jq length <<< "$want")" -gt 0 ] || die "targets.toml has no Tier 1 row"
have=$(yq -o=json '.jobs.capsule.strategy.matrix.include' "$wf" | jq -c '[.[] | {triple, runner, chez_machine}] | sort_by(.triple)')
attest=$(yq -o=json '.jobs.attest.strategy.matrix.triple' "$wf" | jq -c 'sort')
ok=yes
if [ "$have" != "$want" ]; then
  ok=no; echo "check-matrix: the capsule matrix differs from the Tier 1 rows of src/definitions/targets.toml" >&2
  echo "  targets.toml: $want" >&2; echo "  factory.yml:  $have" >&2
fi
wt=$(jq -c '[.[].triple] | sort' <<< "$want")
if [ "$attest" != "$wt" ]; then
  ok=no; echo "check-matrix: the attest matrix differs from the Tier 1 triples" >&2
  echo "  targets.toml: $wt" >&2; echo "  factory.yml:  $attest" >&2
fi
[ "$ok" = yes ] || die "matrix and targets.toml disagree; edit the workflow (or targets.toml) so that they match"
echo "check-matrix: OK, $(jq length <<< "$want") Tier 1 targets: $(jq -r 'map(.triple) | join(", ")' <<< "$want")"
