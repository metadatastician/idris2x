#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
# run-canaries.sh — run tests/canaries/run.sh against a capsule root, with one named exception.
# usage: run-canaries.sh CAPSULE_ROOT
# Fails (exit 1) on any failed canary, on a canary that was skipped, and on a result that does not have all 12 canaries.
# The one exception is `unicode_paths`: docs/status/PHASE0-REPORT.adoc and docs/status/UPSTREAM-NOTES.adoc record it as an
# upstream Idris 2 0.8.0 bug (the Chez backend mis-quotes non-ASCII paths), kept as an expected failure. When it fails, this
# script says so by name; when it passes, this script says that too, so the exception can be removed. It is never skipped quietly.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
die() { echo "run-canaries: FAIL: $*" >&2; exit 1; }
[ "$#" = 1 ] || die "usage: run-canaries.sh CAPSULE_ROOT"
[ -d "$1" ] || die "not a directory: $1"
KNOWN_UPSTREAM_BUGS="unicode_paths"
log=$(mktemp -t canaries.XXXXXX); trap 'rm -f "$log"' EXIT
"$root/tests/canaries/run.sh" "$1" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
passed=$(grep -c '^\[PASS\]' "$log"); failed=$(grep -c '^\[FAIL\]' "$log"); skipped=$(grep -c '^\[skip\]' "$log")
[ "$skipped" = 0 ] || die "$skipped canary skipped (a skip is not a pass): $(grep '^\[skip\]' "$log" | tr '\n' ';')"
[ $((passed + failed)) = 12 ] || die "expected 12 canary results, got $passed passed and $failed failed"
unexpected=''
while read -r n; do
  case " $KNOWN_UPSTREAM_BUGS " in
    *" $n "*) echo "run-canaries: KNOWN UPSTREAM BUG: canary $n failed, as recorded in docs/status/UPSTREAM-NOTES.adoc (Idris 2 0.8.0, Chez backend, non-ASCII paths); not counted as a failure";;
    *) unexpected="$unexpected $n";;
  esac
done < <(grep '^\[FAIL\]' "$log" | awk '{print $2}')
[ -z "$unexpected" ] || die "canaries failed:$unexpected"
for n in $KNOWN_UPSTREAM_BUGS; do
  grep -q "^\[PASS\] $n " "$log" && echo "run-canaries: NOTE: canary $n now passes; the known-bug exception for it can be removed"
done
if [ "$rc" != 0 ] && [ "$failed" = 0 ]; then die "tests/canaries/run.sh exited $rc with no failed canary"; fi
echo "run-canaries: OK ($passed passed, $failed known upstream failure)"
