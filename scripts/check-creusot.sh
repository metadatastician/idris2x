#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
# check-creusot.sh — prove src/civil.rs with Creusot (verification/proofs/creusot/), then check that three broken
# copies fail on the goal each one breaks, so a pass cannot come from contracts that were never read.
# Every run is in a temporary copy laid out as the repository, so the source tree gets no output. A missing
# cargo-creusot fails: nothing is skipped. The output names the tool versions and the commit, as a receipt.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); C=verification/proofs/creusot
command -v cargo-creusot >/dev/null || {
  echo "check-creusot: cargo-creusot is not on PATH; install Creusot as $C/README.adoc says" >&2; exit 1
}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$tmp/target}"

# run NAME FILE FROM TO: copy the proof crate and src/civil.rs to $tmp/NAME, replace the first FROM with TO in FILE
# (no change when FILE is -), and run Creusot there, its output in $tmp/NAME.log. Returns Creusot's exit code.
run() {
  local d="$tmp/$1" s
  mkdir -p "$d/$C/src" "$d/src"
  cp "$R/$C/Cargo.toml" "$R/$C/Cargo.lock" "$R/$C/why3find.json" "$d/$C/"
  cp "$R/$C/src/lib.rs" "$d/$C/src/"
  cp "$R/src/civil.rs" "$d/src/"
  if [ "$2" != - ]; then
    grep -qF -- "$3" "$d/$2" || { echo "check-creusot: $1: the text to break is not in $2" >&2; exit 1; }
    s=$(<"$d/$2"); printf '%s\n' "${s/"$3"/"$4"}" > "$d/$2"
  fi
  (cd "$d/$C" && cargo creusot --no-cache) > "$tmp/$1.log" 2>&1
}

c=$(git -C "$R" rev-parse HEAD 2>/dev/null || echo unknown)
[ -z "$(git -C "$R" status --porcelain -- src/civil.rs "$C" 2>/dev/null)" ] || c="$c, with uncommitted changes to the proved files"
echo "commit $c"
cargo creusot version 2>&1 | sed 's/^/  /'
# One file of goals for each of civil, days and the five lemmas in src/lib.rs. A new proof raises this.
want=7
if ! run proof - '' '' || ! grep -q "^Proved ($want files)" "$tmp/proof.log"; then
  cat "$tmp/proof.log" >&2; echo "check-creusot: FAIL: the proof did not pass, or not in $want files" >&2; exit 1
fi
grep "^Proved" "$tmp/proof.log"

fails=0
# neg NAME FILE FROM TO GOAL: the broken copy must fail, and on GOAL.
neg() {
  if run "$1" "$2" "$3" "$4"; then
    echo "check-creusot: FAIL $1: the broken copy proved" >&2; fails=$((fails + 1))
  elif grep -Eq "vc_$5('[0-9]+)?: ✘" "$tmp/$1.log"; then
    echo "ok   $1 fails on $5, as it must"
  else
    cat "$tmp/$1.log" >&2; echo "check-creusot: FAIL $1: it failed, but not on $5" >&2; fails=$((fails + 1))
  fi
}
# The code of days off by one day: its contract must catch it.
neg days-off-by-one src/civil.rs '+ d - 1;' '+ d;' days
# A contract that is false for 31-day months: civil must fail it, so the contracts are read.
neg civil-day-30 src/civil.rs 'ensures(crate::spec::valid(result.0@, result.1@, result.2@))' \
  'ensures(crate::spec::valid(result.0@, result.1@, result.2@) && result.2@ <= 30)' civil
# 29 February in every year: the round trip must fail, so it rests on the leap rule.
neg feb-29-always "$C/src/lib.rs" 'if m == 2 { if leap { 29 } else { 28 } }' 'if m == 2 { 29 }' date_back
[ "$fails" -eq 0 ] || { echo "check-creusot: FAIL: $fails broken copy check(s) failed" >&2; exit 1; }
echo "check-creusot: proved, and 3 broken copies failed on their goals"
