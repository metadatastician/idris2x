#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
# Tests for scripts/vendor-tier1.sh (ADR 0013). Needs cargo, jq, awk, yq and the crates.io index (cargo vendor
# downloads the crates once). Uses CARGO_TARGET_DIR if set, else a temporary one, and never writes to the repository.
#
# Positive: the filtered vendor set builds the release launcher and passes `cargo test`, offline and frozen, and
#   Cargo.lock is unchanged. Negative: stubbing a crate that Tier 1 needs (ring) makes the build FAIL; a targets file
#   with no tier 1 row, or only tier 2, is refused and vendors nothing; a non-empty OUT_DIR is refused.
# Usage: bash tests/vendor_tier1_test.sh
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$work/target}
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
for t in cargo jq awk yq; do command -v "$t" >/dev/null || fail "$t is required"; done
cfg() { printf '%s\n' --config 'source.crates-io.replace-with="vendored-sources"' --config "source.vendored-sources.directory=\"$1\""; }
lock_before=$(sha256sum "$repo/Cargo.lock")

# --- positive: the filtered set builds and tests offline ---
"$repo/scripts/vendor-tier1.sh" "$work/v" > "$work/receipt" 2>&1 || { cat "$work/receipt" >&2; fail "vendor-tier1.sh failed on the real targets.toml"; }
grep -q '^  kept: ' "$work/receipt" && grep -q '^  stubbed: ' "$work/receipt" && grep -q 'x86_64-unknown-linux-gnu' "$work/receipt" \
  || { cat "$work/receipt" >&2; fail "the receipt lacks kept, stubbed or the triples"; }
pass "vendor-tier1.sh succeeded and printed a receipt"
mapfile -t c < <(cfg "$work/v")
(cd "$repo" && cargo build --release --locked --offline --frozen "${c[@]}") > "$work/build.log" 2>&1 \
  || { tail -30 "$work/build.log" >&2; fail "release build with the filtered vendor set failed"; }
pass "cargo build --release --locked --offline --frozen with the filtered vendor set"
(cd "$repo" && cargo test --offline --frozen "${c[@]}") > "$work/test.log" 2>&1 \
  || { tail -30 "$work/test.log" >&2; fail "cargo test with the filtered vendor set failed"; }
grep -q '^test result: ok' "$work/test.log" || fail "cargo test printed no passing result"
pass "cargo test --offline --frozen with the filtered vendor set"
[ "$(sha256sum "$repo/Cargo.lock")" = "$lock_before" ] || fail "Cargo.lock changed"
pass "Cargo.lock is unchanged"

# --- negative 1: stub a crate that Tier 1 needs; the build must fail ---
cp -R "$work/v" "$work/v-neg"
ring=$(cd "$work/v-neg" && compgen -G "ring-*" | head -1)
[ -n "$ring" ] || fail "no ring in the vendor set"
jq -e '.files != {}' "$work/v-neg/$ring/.cargo-checksum.json" >/dev/null || fail "$ring is already a stub, so the filter dropped a crate Tier 1 needs"
sum=$(jq -r .package "$work/v-neg/$ring/.cargo-checksum.json")
find "$work/v-neg/$ring" -mindepth 1 -maxdepth 1 ! -name Cargo.toml ! -name .cargo-checksum.json -exec rm -rf {} +
mkdir "$work/v-neg/$ring/src"; : > "$work/v-neg/$ring/src/lib.rs"; : > "$work/v-neg/$ring/build.rs"
jq -cn --arg s "$sum" '{files: {}, package: $s}' > "$work/v-neg/$ring/.cargo-checksum.json"
mapfile -t cn < <(cfg "$work/v-neg")
if (cd "$repo" && cargo build --release --locked --offline --frozen "${cn[@]}") > "$work/neg1.log" 2>&1; then
  fail "the build PASSED with ring stubbed; the stub test proves nothing"
fi
grep -q '^error' "$work/neg1.log" || { tail -20 "$work/neg1.log" >&2; fail "the build with ring stubbed failed without a cargo error"; }
pass "the build FAILS when ring is stubbed ($(grep -m1 '^error' "$work/neg1.log"))"

# --- negative 2: no tier 1 row, or only tier 2, is refused and vendors nothing ---
awk '{ if (/^tier[ \t]*=/) sub(/=.*/, "= 2"); print }' "$repo/src/definitions/targets.toml" > "$work/no-tier1.toml"
grep -q '^tier = 1' "$work/no-tier1.toml" && fail "test setup: tier 1 rows remain"
if "$repo/scripts/vendor-tier1.sh" "$work/v-none" "$work/no-tier1.toml" > "$work/neg2.log" 2>&1; then fail "vendor-tier1.sh accepted a targets file with no tier 1 row"; fi
grep -q 'no target row with tier = 1' "$work/neg2.log" || { cat "$work/neg2.log" >&2; fail "refusal lacks the expected message"; }
[ ! -e "$work/v-none" ] || fail "a refused run still created the output directory"
pass "a targets file with no tier 1 row is refused before vendoring"
printf 'schema = 1\n' > "$work/empty.toml"
if "$repo/scripts/vendor-tier1.sh" "$work/v-none" "$work/empty.toml" > "$work/neg3.log" 2>&1; then fail "vendor-tier1.sh accepted an empty targets file"; fi
pass "an empty targets file is refused"
if "$repo/scripts/vendor-tier1.sh" "$work/v" > "$work/neg4.log" 2>&1; then fail "vendor-tier1.sh wrote into a non-empty OUT_DIR"; fi
grep -q 'not empty' "$work/neg4.log" || fail "refusal of a non-empty OUT_DIR lacks the expected message"
pass "a non-empty OUT_DIR is refused"
echo "vendor_tier1_test: all checks passed"
