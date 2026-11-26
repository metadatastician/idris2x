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
# The two channel negatives must fail because of the policy table alone. In a copy of the crate whose table also lets
# channel text fill prose and fix slots, both must compile.
M="$W/mutant"; mkdir -p "$M/crate" "$M/src/bin"; cp -r "$R/Cargo.toml" "$R/src" "$R/benches" "$M/crate/"
sed -i 's/^    impl InFix for Checked {}$/&\n    impl InFix for Channel {}\n    impl InProse for Channel {}/' "$M/crate/src/msg.rs"
grep -q 'impl InProse for Channel {}' "$M/crate/src/msg.rs" || { echo "FAIL mutant: the policy table in src/msg.rs moved; update this script" >&2; exit 1; }
printf '[package]\nname = "msg-mutant"\nversion = "0.0.0"\nedition = "2021"\n[dependencies]\nidris2x = { path = "crate" }\n' > "$M/Cargo.toml"
echo 'fn main() {}' > "$M/src/main.rs"
mapfile -t negs < <(grep -l 'idris2x::msg::channel(' "$W"/src/bin/*.rs || true)
[ "${#negs[@]}" = 2 ] || { echo "FAIL mutant: want 2 channel negatives in src/msg.rs, found: ${negs[*]:-none}" >&2; exit 1; }
for f in "${negs[@]}"; do
  b=m_$(basename "$f" .rs); cp "$f" "$M/src/bin/$b.rs"
  if (cd "$M" && CARGO_TARGET_DIR="$W/target" cargo build --offline --quiet --bin "$b" 2>/dev/null); then echo "ok   $b: compiles once Channel is allowed"
  else echo "FAIL $b: still fails with Channel allowed, so it does not test the policy table" >&2; bad=1; fi
done
# Only pin, the resolver, labels text as channel text (ADR 0012). No other file may name msg::channel, import it, or
# import msg by glob or under another name. A use statement is joined into one line before it is checked.
leaks=$(cd "$R/src" && for f in *.rs; do
  case $f in pin.rs | msg.rs) continue ;; esac
  awk -v f="$f" '{ sub(/\/\/.*/, "") }
    /^[[:space:]]*(pub[^ ]* )?use / { u = 1; s = "" }
    u { s = s $0 } u && /;/ { if (s ~ /msg/ && s ~ /([^_[:alnum:]]channel([^_[:alnum:]]|$)|\*| as )/) print f ": " s; u = 0 }
    /msg::channel([^_[:alnum:]]|$)/ { print f ": " $0 }' "$f"
done)
if [ -z "$leaks" ]; then echo "ok   only src/pin.rs labels text as channel text"
else printf 'FAIL only src/pin.rs may label text as channel text (ADR 0012):\n%s\n' "$leaks" >&2; bad=1; fi
[ $bad = 0 ] && echo "check-msg-negatives: $n negatives fail for their stated reason, and the channel label stays in pin" || exit 1
