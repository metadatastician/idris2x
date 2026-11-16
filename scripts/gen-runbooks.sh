#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# gen-runbooks.sh — generate docs/runbooks/<ID>.adoc stubs from src/errors/errors.toml (generate, don't hand-write).
# The block above the marker is regenerated; hand-written triage notes below it survive. `--check` exits 1 on drift.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); check=0; [ "${1:-}" = --check ] && check=1
MARK='// END GENERATED — hand-written triage notes below survive regeneration'
default_tail=$'\n== Triage\n\n. Reproduce with `idris2x doctor --json` and attach the output.\n. Classify: data fix (channel patch), engine fix (launcher), or upstream outage.\n. If a channel patch resolves it, open a Class A/B PR; the rehearsal pipeline must be green on 3 targets.\n'
changed=()
while IFS=$'\t' read -r id exit meaning fix; do
  p="$R/docs/runbooks/$id.adoc"
  head="// SPDX-License-Identifier: CC-BY-SA-4.0
// GENERATED from src/errors/errors.toml by scripts/gen-runbooks.sh — edit the TOML, not this block
= $id
:toc: macro

[cols=\"1,4\"]
|===
| Exit code | \`$exit\`
| Meaning | $meaning
| Fix | \`$fix\`
| Invariant | I3 loud by default
|===

$MARK
"
  tail=$default_tail
  if [ -f "$p" ] && grep -qF "$MARK" "$p"; then tail=$(sed "1,/^${MARK//\//\\/}\$/d" "$p"; printf x); tail=${tail%x}; fi
  new="$head$tail"
  if [ ! -f "$p" ] || [ "$(cat "$p"; printf x)" != "${new}x" ]; then changed+=("$id.adoc"); [ $check = 1 ] || printf '%s' "$new" > "$p"; fi
done < <("$R/scripts/lib/toml2json.sh" "$R/src/errors/errors.toml" | jq -r '.error[] | [.id, (.exit|tostring), .meaning, .fix] | @tsv')
if [ $check = 1 ]; then echo "would change: ${changed[*]:-nothing}"; [ ${#changed[@]} = 0 ]; else echo "wrote: ${changed[*]:-nothing}"; fi
