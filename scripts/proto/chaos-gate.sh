#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
# chaos-gate.sh — the launcher's CI gate: run the chaos suite against both launchers in both message styles.
# usage: chaos-gate.sh CHEZ_PREFIX IDRIS2_PREFIX CHEZ_SRC IDRIS2_SRC
# Runs scripts/proto/chaos.sh four times (prototype a, prototype b, Rust a, Rust b), each with its own fresh work
# directory and port, from the binaries under target/release. Fails loudly (no silent shrink) when:
#   - any of the four arguments is missing, or a prefix or source directory does not exist (without the Idris 2 prefix
#     the suite quietly drops about 10 checks);
#   - a binary is missing;
#   - a run does not end with a `== RESULT: N passed, M failed` line, or M is not 0, or its exit status is not 0;
#   - the four N are not all equal.
# Env: CHAOS_GATE_WORK (parent of the work directories; default a fresh mktemp -d), PORT_BASE (default 8099).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
die() { echo "chaos-gate: FAIL: $*" >&2; exit 1; }
[ "$#" = 4 ] || die "usage: chaos-gate.sh CHEZ_PREFIX IDRIS2_PREFIX CHEZ_SRC IDRIS2_SRC (all four are required)"
for i in 1 2 3 4; do [ -n "${!i}" ] || die "argument $i is empty; refusing to run a smaller suite"; done
chez_prefix=$1; idris2_prefix=$2; chez_src=$3; idris2_src=$4
[ -d "$chez_prefix" ] || die "CHEZ_PREFIX is not a directory: $chez_prefix"
[ -d "$idris2_prefix" ] || die "IDRIS2_PREFIX is not a directory: $idris2_prefix (the suite would drop about 10 checks)"
[ -d "$chez_src" ] || die "CHEZ_SRC is not a directory: $chez_src"
[ -d "$idris2_src" ] || die "IDRIS2_SRC is not a directory: $idris2_src"
rust_bin=$root/target/release/idris2x; fixture=$root/target/release/examples/fixture_server
[ -x "$rust_bin" ] || die "missing $rust_bin (cargo build --locked --release --bin idris2x)"
[ -x "$fixture" ] || die "missing $fixture (cargo build --locked --release --example fixture_server)"
work=${CHAOS_GATE_WORK:-$(mktemp -d)}; mkdir -p "$work" || die "cannot create $work"
port=${PORT_BASE:-8099}
results=(); counts=(); bad=0; n=0
for launcher in prototype rust; do
  for style in a b; do
    label="$launcher/$style"; dir="$work/$launcher-$style"; mkdir -p "$dir"
    if [ "$launcher" = rust ]; then bin=$rust_bin; else bin=$here/idris2x.sh; fi
    echo "== chaos: $label (port $((port+n)))"
    IDRIS2X_STYLE=$style IDRIS2X_BIN=$bin FIXTURE_SERVER=$fixture CHAOS_WORK=$dir PORT=$((port+n)) \
      "$here/chaos.sh" "$chez_prefix" "$idris2_prefix" "$chez_src" "$idris2_src" 2>&1 | tee "$dir/log.txt"
    rc=${PIPESTATUS[0]}
    line=$(grep -E '^== RESULT: [0-9]+ passed, [0-9]+ failed' "$dir/log.txt" | tail -n 1)
    if [ -z "$line" ]; then
      echo "chaos-gate: $label: no RESULT line" >&2; bad=1; results+=("$label: no RESULT line (exit $rc)"); counts+=("?"); n=$((n+1)); continue
    fi
    p=$(printf '%s\n' "$line" | sed -E 's/^== RESULT: ([0-9]+) passed, ([0-9]+) failed.*/\1/')
    f=$(printf '%s\n' "$line" | sed -E 's/^== RESULT: ([0-9]+) passed, ([0-9]+) failed.*/\2/')
    results+=("$label: $p passed, $f failed (exit $rc)"); counts+=("$p")
    [ "$f" = 0 ] && [ "$rc" = 0 ] || { echo "chaos-gate: $label: failures or non-zero exit" >&2; bad=1; }
    n=$((n+1))
  done
done
echo; echo "== chaos-gate results"; printf '   %s\n' "${results[@]}"
for c in "${counts[@]}"; do
  [ "$c" = "${counts[0]}" ] || { echo "chaos-gate: pass counts differ across runs: ${counts[*]}" >&2; bad=1; break; }
done
[ "$bad" = 0 ] || die "the chaos gate failed"
echo "chaos-gate: OK, four runs of ${counts[0]} passed, 0 failed"
