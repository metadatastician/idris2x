#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# configure-repo.sh [owner/repo] [--dry-run] — the owner's one-time Configure stage:
# description, homepage, wiki/issues/discussions on, and the topics in .github/repo-settings-idris2x.toml.
# Needs the owner's gh login (repository administration). Idempotent.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); repo=metadatastician/idris2x; dry=0
for a in "$@"; do case "$a" in --dry-run) dry=1;; */*) repo=$a;; esac; done
J=$("$R/scripts/lib/toml2json.sh" "$R/.github/repo-settings-idris2x.toml")
desc=$(jq -r '.repo[0].description' <<<"$J"); home=$(jq -r '.repo[0].homepage' <<<"$J")
mapfile -t topics < <(jq -r '.topic[].name' <<<"$J")
[ "${#topics[@]}" -le 20 ] || { echo "GitHub allows at most 20 topics; file has ${#topics[@]}" >&2; exit 1; }
echo "repo: $repo"; echo "description (${#desc} chars): $desc"; echo "homepage: $home"; echo "topics (${#topics[@]}): ${topics[*]}"
[ $dry = 1 ] && { echo "(dry run: nothing changed)"; exit 0; }
gh repo edit "$repo" --description "$desc" --homepage "$home" --enable-wiki --enable-issues --enable-discussions
args=(); for t in "${topics[@]}"; do args+=(-f "names[]=$t"); done
gh api -X PUT "repos/$repo/topics" "${args[@]}" --jq '"topics set: \(.names | length)"'
