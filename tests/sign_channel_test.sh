#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose)
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Offline test of scripts/sign-channel.sh. A stub `gh` on PATH serves a fixture
# draft release and fakes `gh attestation verify`; a throwaway signify key from
# `signify-openbsd -G -n` signs. No network, no real key. Run: bash tests/sign_channel_test.sh
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SIGN="$repo/scripts/sign-channel.sh"
TAG=v0.1.0
BASE="https://github.com/metadatastician/idris2x/releases/download/$TAG"

command -v signify-openbsd >/dev/null 2>&1 || { echo 'FAIL: signify-openbsd is required (apt install signify-openbsd)' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'FAIL: jq is required' >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | awk '{print $1}'; }; else sha() { shasum -a 256 "$1" | awk '{print $1}'; }; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
TIER1=$(awk '/^\[\[target\]\]/{if(t!=""&&k==1)print t;t="";k=0} /^triple[ \t]*=/{s=$0;sub(/^[^"]*"/,"",s);sub(/".*$/,"",s);t=s} /^tier[ \t]*=[ \t]*1[ \t]*($|#)/{k=1} END{if(t!=""&&k==1)print t}' "$repo/src/definitions/targets.toml")
[ "$(printf '%s\n' "$TIER1" | wc -l | tr -d ' ')" -eq 4 ] || { echo "FAIL: expected 4 tier 1 targets, got: $TIER1" >&2; exit 1; }

# Throwaway key, no passphrase.
mkdir -p "$work/key"
signify-openbsd -G -n -p "$work/key/t.pub" -s "$work/key/t.sec" -c 'throwaway test key' >/dev/null

# Stub gh. It only serves $FIXTURE; any other call is a loud failure (exit 99).
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE/gh.log"
case "$1 ${2:-}" in
  'release view') cat "$FIXTURE/isDraft" ;;
  'release download')
    while [ $# -gt 0 ]; do case "$1" in --dir) d=$2; shift 2 ;; *) shift ;; esac; done
    cp "$FIXTURE"/assets/* "$d"/ ;;
  'attestation verify')
    f=$(basename "$3")
    case " $* " in *' --deny-self-hosted-runners '*) : ;; *) echo "stub gh: no --deny-self-hosted-runners" >&2; exit 97 ;; esac
    case " $* " in *' --repo metadatastician/idris2x '*) : ;; *) echo "stub gh: wrong --repo" >&2; exit 97 ;; esac
    if grep -qxF -- "$f" "$FIXTURE/attest-fail" 2>/dev/null; then
      echo "stub gh: no attestation found for $f" >&2; exit 1
    fi ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$work/bin/gh"

# Fixture: a draft with four fake capsules, four fake launchers, a v1.json, SHA256SUMS.
make_fixture() {
  FIXTURE="$work/fx.$1"; export FIXTURE
  mkdir -p "$FIXTURE/assets"
  echo true > "$FIXTURE/isDraft"; : > "$FIXTURE/attest-fail"
  local t name entries='' sep=''
  for t in $TIER1; do
    name="idris2-0.8.0-$t-chez10.4.1.tar.gz"
    printf 'capsule bytes for %s\n' "$t" > "$FIXTURE/assets/$name"
    printf 'launcher bytes for %s\n' "$t" > "$FIXTURE/assets/idris2x-$TAG-$t.tar.gz"
    entries="$entries$sep\"$t\":{\"urls\":[\"$BASE/$name\"],\"sha256\":\"$(sha "$FIXTURE/assets/$name")\",\"size\":$(wc -c < "$FIXTURE/assets/$name" | tr -d ' '),\"min_glibc\":null,\"chez\":\"10.4.1\"}"
    sep=,
  done
  printf '{"schema":1,"channel_version":3,"expires":"2099-01-01T00:00:00Z","bundles":{"idris2@0.8.0":{%s}},"compat":{"idris2@0.8.0":{"chez":"10.4.1","platforms":[]}},"deprecated":[]}\n' "$entries" \
    | jq -S . > "$FIXTURE/assets/v1.json"
  resum
}
resum() { local g; (cd "$FIXTURE/assets" && for g in *; do [ "$g" = SHA256SUMS ] || printf "%s  %s\n" "$(sha "$g")" "$g"; done > "$work/sums.tmp") && mv "$work/sums.tmp" "$FIXTURE/assets/SHA256SUMS"; }

pass=0; failn=0
run() { # run <stdin-answer> <args...>; sets rc and out
  local ans=$1; shift
  rc=0; out=$(printf '%s\n' "$ans" | PATH="$work/bin:$PATH" bash "$SIGN" "$@" 2>&1) || rc=$?
}
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { failn=$((failn + 1)); echo "FAIL - $1" >&2; printf '%s\n' "$out" | sed 's/^/       /' >&2; }
expect_refusal() { # name, message-substring
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$2" && [ ! -e "$work/o.$1/v1.json.sig" ]; then ok "$1 refuses: $2"; else bad "$1 should refuse with '$2' (rc=$rc)"; fi
}
go() { run sign --key "$work/key/t.sec" --pub "$work/key/t.pub" --out "$work/o.$1" "$TAG"; }

# 1. happy path
make_fixture happy; go happy
if [ "$rc" -eq 0 ] && [ -s "$work/o.happy/v1.json.sig" ] \
   && signify-openbsd -V -p "$work/key/t.pub" -m "$work/o.happy/v1.json" -x "$work/o.happy/v1.json.sig" >/dev/null 2>&1 \
   && printf '%s' "$out" | grep -qF "gh release upload $TAG" && printf '%s' "$out" | grep -qF "gh release edit $TAG" \
   && printf '%s' "$out" | grep -qF -- '--draft=false'; then ok 'happy path signs, the signature verifies, the publish commands are printed'; else bad "happy path (rc=$rc)"; fi
if ! grep -Eq '^release (upload|edit|create)' "$FIXTURE/gh.log"; then ok 'happy path never uploads, edits or publishes'; else bad 'script called a mutating gh command'; fi
n=$(grep -c "^attestation verify" "$FIXTURE/gh.log")
if [ "$n" -eq 9 ]; then ok "attested 4 capsules, 4 launchers and v1.json"; else out="attestation calls: $n"; bad "expected 9 attestation checks"; fi
if cmp -s "$work/o.happy/v1.json" "$FIXTURE/assets/v1.json"; then ok 'v1.json is signed byte for byte as downloaded'; else bad 'v1.json changed'; fi

# 2. tampered capsule (SHA256SUMS regenerated, so the v1.json digest is what catches it)
make_fixture tamper; first=$(echo "$TIER1" | head -1)
echo evil >> "$FIXTURE/assets/idris2-0.8.0-$first-chez10.4.1.tar.gz"; resum; go tamper
expect_refusal tamper 'capsule digest mismatch'

# 2b. tampered capsule with a stale SHA256SUMS
make_fixture tamper2; echo evil >> "$FIXTURE/assets/idris2-0.8.0-$first-chez10.4.1.tar.gz"; go tamper2
expect_refusal tamper2 'SHA256SUMS mismatch'

# 3. missing tier 1 target
make_fixture missing; last=$(echo "$TIER1" | tail -1)
jq --arg t "$last" 'del(.bundles["idris2@0.8.0"][$t])' "$FIXTURE/assets/v1.json" > "$work/v.tmp" && mv "$work/v.tmp" "$FIXTURE/assets/v1.json"; resum; go missing
expect_refusal missing "lists no capsule for tier 1 target $last"

# 4. expired manifest
make_fixture expired; jq '.expires="2020-01-01T00:00:00Z"' "$FIXTURE/assets/v1.json" > "$work/v.tmp" && mv "$work/v.tmp" "$FIXTURE/assets/v1.json"; resum; go expired
expect_refusal expired 'expired at 2020-01-01T00:00:00Z'

# 5. failed attestation (a capsule, and separately a launcher)
make_fixture attest; echo "idris2-0.8.0-$first-chez10.4.1.tar.gz" > "$FIXTURE/attest-fail"; go attest
expect_refusal attest "attestation verification FAILED for idris2-0.8.0-$first-chez10.4.1.tar.gz"
make_fixture attest2; echo "idris2x-$TAG-$first.tar.gz" > "$FIXTURE/attest-fail"; go attest2
expect_refusal attest2 "attestation verification FAILED for idris2x-$TAG-$first.tar.gz"
make_fixture attest3; echo v1.json > "$FIXTURE/attest-fail"; go attest3
expect_refusal attest3 'attestation verification FAILED for v1.json'

# 6. SHA256SUMS mismatch (a listed hash is wrong, and a file is missing from the list)
make_fixture sums; sed -i.bak "1s/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/" "$FIXTURE/assets/SHA256SUMS"; rm -f "$FIXTURE/assets/SHA256SUMS.bak"; go sums
expect_refusal sums 'SHA256SUMS mismatch'
make_fixture sums2; sed -i.bak '$d' "$FIXTURE/assets/SHA256SUMS"; rm -f "$FIXTURE/assets/SHA256SUMS.bak"; go sums2
expect_refusal sums2 'is not listed in SHA256SUMS'

# 7. other refusals
make_fixture nokey; rc=0; out=$(printf 'sign\n' | PATH="$work/bin:$PATH" bash "$SIGN" --out "$work/o.nokey" "$TAG" 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF -- '--key PATH is required'; then ok 'missing --key refuses (no default key)'; else bad 'missing --key'; fi
make_fixture decline; run no --key "$work/key/t.sec" --out "$work/o.decline" "$TAG"
expect_refusal decline "confirmation was 'no'"
make_fixture published; echo false > "$FIXTURE/isDraft"; go published
expect_refusal published 'is not a draft'
make_fixture presigned; echo old > "$FIXTURE/assets/v1.json.sig"; resum; go presigned
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'already holds v1.json.sig'; then ok 'a draft that is already signed refuses'; else bad 'presigned'; fi
make_fixture extra; echo x > "$FIXTURE/assets/stray.bin"; resum; go extra
expect_refusal extra 'unexpected asset stray.bin'
make_fixture nolauncher; rm "$FIXTURE/assets/idris2x-$TAG-$first.tar.gz"; resum; go nolauncher
expect_refusal nolauncher "no launcher tarball idris2x-$TAG-$first.tar.gz"
make_fixture wrongkey; signify-openbsd -G -n -p "$work/key/o.pub" -s "$work/key/o.sec" >/dev/null
run sign --key "$work/key/t.sec" --pub "$work/key/o.pub" --out "$work/o.wrongkey" "$TAG"
expect_refusal wrongkey 'does not verify with'

echo "sign_channel_test: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
