#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
# vendor-tier1.sh — vendor the crates the Tier 1 targets need, and stub the rest (ADR 0013).
#
# Usage: scripts/vendor-tier1.sh OUT_DIR [TARGETS_TOML]
#   OUT_DIR      must not exist or must be empty. Nothing is written anywhere else, and nothing under the
#                repository (ADR 0013: the vendor set lives in CI only; no vendor/ and no .cargo/config.toml).
#   TARGETS_TOML defaults to src/definitions/targets.toml. The rows with `tier = 1` give the triples.
#
# Steps: (1) read the Tier 1 triples; (2) `cargo vendor --locked --versioned-dirs` into OUT_DIR, so every
# directory is NAME-VERSION; (3) ask `cargo metadata --locked --filter-platform TRIPLE` for each triple which
# registry packages it resolves (normal, build and dev edges; build scripts run on the host, which is Tier 1 in CI)
# and take the union; (4) replace every other vendored crate by a stub: its original Cargo.toml (so its declared
# dependencies still match Cargo.lock), an empty file at each source path the manifest names, and a
# .cargo-checksum.json with no files and the same package checksum. Cargo.lock is not changed.
#
# Fails loudly (non-zero, one `vendor-tier1: ERROR` line) when there is no Tier 1 triple, when any step fails, when a
# needed crate is missing from the vendor dir, when nothing would be stubbed, or when the kept set is not exactly the
# set cargo metadata names. Prints a receipt on success.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "vendor-tier1: ERROR $*" >&2; exit 1; }
[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: vendor-tier1.sh OUT_DIR [TARGETS_TOML]"
out=$1; targets=${2:-$R/src/definitions/targets.toml}
for t in cargo jq awk yq du; do command -v "$t" >/dev/null || die "$t is required"; done
[ -f "$targets" ] || die "no such targets file: $targets"
if [ -e "$out" ]; then
  [ -d "$out" ] || die "$out exists and is not a directory"
  [ -z "$(ls -A "$out")" ] || die "$out is not empty; refusing to mix vendor sets"
fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# 1. Tier 1 triples: one per [[target]] block with tier = 1.
awk '
  function flush() { if (triple != "" && tier == 1) print triple; triple = ""; tier = 0 }
  /^\[\[target\]\]/ { flush(); next }
  /^[ \t]*triple[ \t]*=/ { s = $0; sub(/^[^"]*"/, "", s); sub(/".*$/, "", s); triple = s; next }
  /^[ \t]*tier[ \t]*=/ { s = $0; sub(/^[^=]*=[ \t]*/, "", s); sub(/[^0-9].*$/, "", s); tier = s + 0; next }
  END { flush() }
' "$targets" > "$work/triples"
[ -s "$work/triples" ] || die "$targets has no target row with tier = 1"
grep -Eqx '[a-z0-9_]+-[a-z0-9_]+-[a-z0-9_.-]+' "$work/triples" || die "a triple in $targets does not look like a triple"
sort -u "$work/triples" -o "$work/triples"

# 2. Vendor everything, one NAME-VERSION directory per crate.
mkdir -p "$out"
cargo vendor --locked --versioned-dirs --manifest-path "$R/Cargo.toml" "$out" > "$work/vendor-config.txt" 2> "$work/vendor-err.txt" \
  || { cat "$work/vendor-err.txt" >&2; die "cargo vendor failed"; }
find "$out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort > "$work/vendored"
[ -s "$work/vendored" ] || die "cargo vendor produced no crates"

# 3. The union of what the Tier 1 triples need. Only crates.io packages count; any other source is an error.
ids='.packages as $p | ($p | map({(.id): .}) | add) as $m | .resolve.nodes[].id | $m[.]
     | select(.source != null)
     | if (.source | startswith("registry+https://github.com/rust-lang/crates.io-index")) then "\(.name)-\(.version)"
       else error("package \(.name) \(.version) has source \(.source), not crates.io") end'
: > "$work/need-raw"
while IFS= read -r triple; do
  cargo metadata --locked --format-version 1 --manifest-path "$R/Cargo.toml" --filter-platform "$triple" > "$work/meta.json" \
    || die "cargo metadata failed for $triple"
  jq -r "$ids" "$work/meta.json" >> "$work/need-raw" || die "cannot read cargo metadata output for $triple"
done < "$work/triples"
sort -u "$work/need-raw" > "$work/need"
[ -s "$work/need" ] || die "the Tier 1 triples need no crates, which cannot be right"
# Every needed crate must be in the vendor dir; the vendor dir must hold exactly the crates in Cargo.lock.
missing=$(comm -13 "$work/vendored" "$work/need")
[ -z "$missing" ] || die "needed but not vendored: $(echo "$missing" | tr '\n' ' ')"
cargo metadata --locked --format-version 1 --manifest-path "$R/Cargo.toml" \
  | jq -r ".packages[] | select(.source != null) | \"\\(.name)-\\(.version)\"" | sort -u > "$work/all"
[ "$(cat "$work/all")" = "$(cat "$work/vendored")" ] || die "the vendor dir does not match the packages in Cargo.lock"
comm -23 "$work/vendored" "$work/need" > "$work/stub"
[ -s "$work/stub" ] || die "nothing to stub: every vendored crate is needed, so the filter did nothing"

# 4. Stub the rest. The original Cargo.toml stays; the checksum file keeps the package checksum.
while IFS= read -r d; do
  dir=$out/$d
  [ -f "$dir/Cargo.toml" ] && [ -f "$dir/.cargo-checksum.json" ] || die "$d has no Cargo.toml or .cargo-checksum.json"
  sum=$(jq -r '.package // empty' "$dir/.cargo-checksum.json")
  [ -n "$sum" ] || die "$d has no package checksum"
  # Source paths the manifest names (lib, build script, bins, examples, tests, benches), else the defaults.
  paths=$(yq -p toml -o json '.' "$dir/Cargo.toml" \
    | jq -r '[(.lib.path // "src/lib.rs"), (.build | strings), (.bin[]?.path | strings), (.example[]?.path | strings),
              (.test[]?.path | strings), (.bench[]?.path | strings)] | unique[]') || die "cannot read the manifest of $d"
  find "$dir" -mindepth 1 -maxdepth 1 ! -name Cargo.toml ! -name .cargo-checksum.json -exec rm -rf {} +
  while IFS= read -r p; do
    case $p in /*|*..*) die "$d names an unsafe source path: $p" ;; esac
    mkdir -p "$dir/$(dirname "$p")"; : > "$dir/$p"
  done <<< "$paths"
  jq -cn --arg sum "$sum" '{files: {}, package: $sum}' > "$dir/.cargo-checksum.json"
done < "$work/stub"

# 5. Check the result: kept directories are exactly the needed set, stubs are exactly the rest.
: > "$work/kept"
while IFS= read -r d; do
  if jq -e '.files == {}' "$out/$d/.cargo-checksum.json" >/dev/null; then echo "$d" >> "$work/stubbed-now"; else echo "$d" >> "$work/kept"; fi
done < "$work/vendored"
sort "$work/kept" > "$work/kept.s"
[ "$(cat "$work/kept.s")" = "$(cat "$work/need")" ] || die "the kept set is not the set cargo metadata names"
[ "$(sort "$work/stubbed-now")" = "$(cat "$work/stub")" ] || die "the stubbed set is not the expected set"

kept_n=$(wc -l < "$work/kept.s"); stub_n=$(wc -l < "$work/stub")
kept_kb=0; while IFS= read -r d; do kb=$(du -sk "$out/$d" | cut -f1); kept_kb=$((kept_kb + kb)); done < "$work/kept.s"
total_kb=$(du -sk "$out" | cut -f1)
echo "vendor-tier1: receipt"
echo "  triples:  $(tr '\n' ' ' < "$work/triples")"
echo "  kept:     $kept_n crates, $((kept_kb / 1024)) MB ($kept_kb KB)"
echo "  stubbed:  $stub_n crates"
echo "  vendor dir total after stubbing: $((total_kb / 1024)) MB ($total_kb KB), at $out"
echo "  use with: cargo build --locked --offline --frozen --config 'source.crates-io.replace-with=\"vendored-sources\"' --config 'source.vendored-sources.directory=\"$out\"'"
