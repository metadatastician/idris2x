#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# sync-local-labels.sh [owner/repo] — create or update the project labels in .github/labels-idris2x.toml.
# Never deletes a label. `--dry-run` prints what it would do.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); repo=${1:-metadatastician/idris2x}; dry=0; [ "${2:-}" = --dry-run ] || [ "${1:-}" = --dry-run ] && dry=1
[ "${1:-}" = --dry-run ] && repo=metadatastician/idris2x
"$R/scripts/lib/toml2json.sh" "$R/.github/labels-idris2x.toml" | jq -c '.label[]' | while read -r l; do
  n=$(jq -r .name <<<"$l"); c=$(jq -r .color <<<"$l"); d=$(jq -r .description <<<"$l")
  if [ $dry = 1 ]; then echo "would upsert: $n"; continue; fi
  if gh api "repos/$repo/labels/$(jq -rn --arg n "$n" '$n|@uri')" >/dev/null 2>&1; then
    gh api -X PATCH "repos/$repo/labels/$(jq -rn --arg n "$n" '$n|@uri')" -f color="$c" -f description="$d" >/dev/null && echo "updated: $n"
  else gh api -X POST "repos/$repo/labels" -f name="$n" -f color="$c" -f description="$d" >/dev/null && echo "created: $n"; fi
done
