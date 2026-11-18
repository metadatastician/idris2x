#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# sync-wiki.sh — publish docs/wikis/*.adoc to the GitHub wiki (<repo>.wiki.git).
#   scripts/sync-wiki.sh --check            regenerate the generated pages and fail if they drift
#   scripts/sync-wiki.sh --publish <url>    clone the wiki, mirror the pages, commit and push
# The wiki is a mirror: pages are reviewed as code in docs/wikis/ and published on merge to main.
# GitHub creates the wiki repository only after its first page is saved in the web UI (one-time owner step).
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); W="$R/docs/wikis"
H='// SPDX-License-Identifier: CC-BY-SA-4.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Source of the GitHub wiki page. Edit here; scripts/sync-wiki.sh publishes on merge to main.'
gen_error_reference() {
  printf '%s\n\n= Error reference\n\nGenerated from `src/errors/errors.toml`. Exit codes are stable and append-only.\n\n[cols="2,1,4,4",options="header"]\n|===\n| ID | Exit | Meaning | Fix\n' "$H"
  "$R/scripts/lib/toml2json.sh" "$R/src/errors/errors.toml" | jq -r '.error[] | "| link:https://github.com/metadatastician/idris2x/blob/main/docs/runbooks/\(.id).adoc[`\(.id)`] | \(.exit) | \(.meaning) | `\(.fix)`"'
  printf '|===\n'
}
regen() { # regen check|write
  local tmp; tmp=$(mktemp); gen_error_reference > "$tmp"
  if [ "$1" = check ]; then cmp -s "$tmp" "$W/Error-Reference.adoc" || { echo "Error-Reference.adoc is stale: run scripts/sync-wiki.sh --regen"; rm -f "$tmp"; exit 1; }
  else mv "$tmp" "$W/Error-Reference.adoc"; fi; rm -f "$tmp"
  local m; m=$(awk '/^\[cols="3,1,2,2,3"/{f=1} f{print} f && /^\|===$/{n++; if(n==2) exit}' "$W/Supported-Platforms.adoc")
  [ "$m" = "$("$R/scripts/gen-matrix.sh" adoc --tier 2)" ] || { echo "Supported-Platforms.adoc table is stale: paste scripts/gen-matrix.sh adoc --tier 2"; exit 1; }
  for l in $(grep -oh 'link:[A-Za-z_-]*\[' "$W"/*.adoc | sed 's/link:\(.*\)\[/\1/' | sort -u); do
    [ -f "$W/$l.adoc" ] || { echo "broken wiki link: $l"; exit 1; }; done
}
case "${1:-}" in
  --check) regen check; echo "wiki sources consistent";;
  --regen) regen write; echo "regenerated Error-Reference.adoc";;
  --publish)
    url=${2:?usage: sync-wiki.sh --publish <wiki-git-url>}; regen check
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    git clone --quiet --depth 1 "$url" "$tmp/wiki" || { echo "cannot clone the wiki: create its first page in the GitHub UI once, then re-run"; exit 1; }
    find "$tmp/wiki" -maxdepth 1 -type f \( -name '*.adoc' -o -name '*.md' -o -name '*.asciidoc' \) -delete
    cp "$W"/*.adoc "$tmp/wiki/"
    cd "$tmp/wiki"; git add -A
    if git diff --cached --quiet; then echo "wiki already up to date"; exit 0; fi
    git -c user.name="idris2x wiki sync" -c user.email="noreply@github.com" commit --quiet -m "Sync wiki from docs/wikis @ ${GITHUB_SHA:-local}"
    git push --quiet origin HEAD && echo "wiki published";;
  *) echo "usage: sync-wiki.sh --check | --regen | --publish <url>" >&2; exit 2;;
esac
