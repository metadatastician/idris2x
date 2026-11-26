#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# This script is MPL-2.0. It holds no CC-BY-SA-4.0 wording.
# check-msg-negatives.sh — prove each `compile_fail,EXXXX` doctest in src/msg.rs fails for its stated reason.
# Stable rustdoc passes a compile_fail doctest on any error, so a typo would pass too. This builds each
# negative as its own binary in an outside crate and fails unless rustc reports exactly the stated code.
# Needs only bash, awk and cargo. Exits 1 on any mismatch, and when it finds no negatives at all.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); W="$R/target/msg-negatives"
rm -rf "$W"; mkdir -p "$W/src/bin"
printf '[package]\nname = "msg-negatives"\nversion = "0.0.0"\nedition = "2021"\n[dependencies]\nidris2x = { path = "%s" }\n' "$R" > "$W/Cargo.toml"
echo 'fn main() {}' > "$W/src/main.rs"
awk -v d="$W/src/bin" '
/^\/\/! ```compile_fail,E[0-9]+$/ { n++; c=$0; sub(/.*compile_fail,/, "", c); f=d "/n" n "_" c ".rs"; print "fn main() {" > f; inb=1; next }
inb && /^\/\/! ```$/ { print "}" > f; close(f); inb=0; next }
inb { l=$0; sub(/^\/\/! ?/, "", l); print l > f }' "$R/src/msg.rs"
bad=0; n=0
for f in "$W"/src/bin/*.rs; do
  [ -e "$f" ] || break
  b=$(basename "$f" .rs); want=${b#*_}; n=$((n + 1))
  got=$(cd "$W" && cargo build --offline --quiet --bin "$b" 2>&1 | grep -oE '^error\[E[0-9]+\]' | sort -u | tr -d 'error[]' | paste -sd' ' || true)
  if [ "$got" = "$want" ]; then echo "ok   $b: $got"; else echo "FAIL $b: want $want, got ${got:-no error}" >&2; bad=1; fi
done
[ "$n" -gt 0 ] || { echo "check-msg-negatives: no compile_fail doctests found in src/msg.rs" >&2; exit 1; }
[ $bad = 0 ] && echo "check-msg-negatives: $n negatives fail for their stated reason" || exit 1
