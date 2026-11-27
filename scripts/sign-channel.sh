#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose)
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# sign-channel.sh — the owner's offline step of a release (docs/RELEASING.adoc).
#
# CI leaves a DRAFT release holding the capsules, the launcher tarballs, an
# UNSIGNED v1.json and SHA256SUMS. This script downloads that draft, re-checks it
# end to end, and only then signs v1.json with the root signify key. It never
# uploads, edits or publishes: it prints the two commands for the owner to run.
#
# usage: scripts/sign-channel.sh --key SECKEY [--pub PUBKEY] [--out DIR] TAG
#   --key PATH   the root signify secret key. Required. There is no default, it is
#                never read from the environment and never copied anywhere.
#   --pub PATH   optional public key; when given, the new signature is verified with it.
#   --out DIR    keep the downloads here (must be absent or empty). Default: a new temp dir.
#
# Needs: gh, jq, signify-openbsd or signify, sha256sum or shasum. Runs on Linux and on
# macOS (bash 3.2, BSD tools): no GNU date -d, no mapfile, no associative arrays.
# Exit: 0 signed; 1 a check refused; 2 usage or missing tool.
set -euo pipefail
export LC_ALL=C

REPO='metadatastician/idris2x'
HERE=$(cd "$(dirname "$0")" && pwd)
TARGETS_TOML="$HERE/../src/definitions/targets.toml"

die() { printf 'sign-channel: REFUSED: %s\n' "$*" >&2; exit 1; }
usage() { printf 'sign-channel: %s\nusage: scripts/sign-channel.sh --key SECKEY [--pub PUBKEY] [--out DIR] TAG\n' "$*" >&2; exit 2; }

KEY='' PUB='' OUT='' TAG=''
while [ $# -gt 0 ]; do
  case "$1" in
    --key) [ $# -ge 2 ] || usage '--key needs a path'; KEY=$2; shift 2 ;;
    --pub) [ $# -ge 2 ] || usage '--pub needs a path'; PUB=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || usage '--out needs a path'; OUT=$2; shift 2 ;;
    -h|--help) usage 'help' ;;
    -*) usage "unknown option $1" ;;
    *) [ -z "$TAG" ] || usage 'one tag only'; TAG=$1; shift ;;
  esac
done
[ -n "$TAG" ] || usage 'a release tag is required'
[ -n "$KEY" ] || usage '--key PATH is required (there is no default key)'
case "$TAG" in v[0-9]*) : ;; *) usage "tag '$TAG' does not look like vN.N.N" ;; esac
case "$TAG" in */*|*..*) usage "tag '$TAG' holds a path character" ;; esac

for t in gh jq; do command -v "$t" >/dev/null 2>&1 || usage "$t is not on PATH"; done
SIGNIFY=''
for c in signify-openbsd signify; do
  if command -v "$c" >/dev/null 2>&1; then SIGNIFY=$c; break; fi
done
[ -n "$SIGNIFY" ] || usage 'neither signify-openbsd nor signify is on PATH'
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  usage 'neither sha256sum nor shasum is on PATH'
fi
size_of() { wc -c < "$1" | tr -d ' '; }

if [ ! -f "$KEY" ] || [ ! -r "$KEY" ]; then usage "key file '$KEY' is not a readable file"; fi
[ -z "$PUB" ] || { [ -f "$PUB" ] && [ -r "$PUB" ]; } || usage "public key '$PUB' is not a readable file"
[ -f "$TARGETS_TOML" ] || usage "cannot find $TARGETS_TOML (run this script from a checkout)"

# Tier 1 triples come from the one source of truth, the support matrix.
TIER1=$(awk '
  /^\[\[target\]\]/ { if (t != "" && tier == 1) print t; t=""; tier=0 }
  /^triple[ \t]*=/  { s=$0; sub(/^[^"]*"/, "", s); sub(/".*$/, "", s); t=s }
  /^tier[ \t]*=[ \t]*1[ \t]*($|#)/ { tier=1 }
  END { if (t != "" && tier == 1) print t }' "$TARGETS_TOML")
[ -n "$TIER1" ] || die "no tier 1 target found in $TARGETS_TOML"

if [ -z "$OUT" ]; then
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/idris2x-release.XXXXXX")
else
  if [ -e "$OUT" ]; then
    if [ ! -d "$OUT" ] || [ -n "$(ls -A "$OUT")" ]; then usage "--out '$OUT' exists and is not an empty directory"; fi
  else
    mkdir -p "$OUT"
  fi
fi
OUT=$(cd "$OUT" && pwd)

printf 'sign-channel: release %s of %s, downloads in %s\n' "$TAG" "$REPO" "$OUT"

# 1. It must still be a draft: a published immutable release cannot take the signature.
is_draft=$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq .isDraft) \
  || die "cannot read release $TAG of $REPO"
[ "$is_draft" = true ] || die "release $TAG is not a draft (isDraft=$is_draft); an immutable published release cannot take a new asset"

# 2. Download every asset.
gh release download "$TAG" --repo "$REPO" --dir "$OUT" --pattern '*' \
  || die "download of the assets of $TAG failed"
[ -f "$OUT/v1.json" ] || die 'the draft has no v1.json'
[ -f "$OUT/SHA256SUMS" ] || die 'the draft has no SHA256SUMS'
[ ! -e "$OUT/v1.json.sig" ] || die 'the draft already holds v1.json.sig; refusing to sign twice'


SCR=$(mktemp -d "${TMPDIR:-/tmp}/idris2x-sign.XXXXXX")
trap 'rm -rf "$SCR"' EXIT

# 3. SHA256SUMS covers every asset, and every line matches.
n=0
: > "$SCR/listed"
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  want=${line%%[ ]*}
  name=${line#*[ ]}; name=${name#[ *]}
  case "$want" in *[!0-9a-f]*|'') die "SHA256SUMS line is not '<sha256>  <name>': $line" ;; esac
  [ "${#want}" -eq 64 ] || die "SHA256SUMS line has a hash of the wrong length: $line"
  case "$name" in */*|''|SHA256SUMS) die "SHA256SUMS names an unexpected file: '$name'" ;; esac
  [ -f "$OUT/$name" ] || die "SHA256SUMS lists $name but the draft has no such asset"
  have=$(sha256_of "$OUT/$name")
  [ "$have" = "$want" ] || die "SHA256SUMS mismatch for $name: the file is $have, SHA256SUMS says $want"
  printf '%s\n' "$name" >> "$SCR/listed"
  n=$((n + 1))
done < "$OUT/SHA256SUMS"
[ "$n" -gt 0 ] || die 'SHA256SUMS is empty'
for f in "$OUT"/*; do
  b=$(basename "$f")
  [ "$b" = SHA256SUMS ] && continue
  grep -qxF -- "$b" "$SCR/listed" || die "asset $b is not listed in SHA256SUMS"
done
printf 'sign-channel: SHA256SUMS matches all %s other assets\n' "$n"

# 4. v1.json: shape, expiry, tier 1 coverage, and every capsule digest and size.
jq -e . "$OUT/v1.json" >/dev/null 2>&1 || die 'v1.json is not valid JSON'
jq -e '.schema == 1 and (.channel_version | type == "number" and . >= 1 and floor == .)
       and (.bundles | type == "object" and length > 0)' "$OUT/v1.json" >/dev/null \
  || die 'v1.json lacks schema 1, an integer channel_version >= 1, or bundles'
CHV=$(jq -r .channel_version "$OUT/v1.json")

EXPIRES=$(jq -r '.expires // empty' "$OUT/v1.json")
printf '%s' "$EXPIRES" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$' \
  || die "v1.json expires '$EXPIRES' is not a UTC RFC 3339 time ending in Z"
exp_cmp=${EXPIRES%%.*}; exp_cmp=${exp_cmp%Z}
now_cmp=$(date -u +%Y-%m-%dT%H:%M:%S)
# Same fixed-width format on both sides, so string order is time order. No GNU date -d.
[[ "$exp_cmp" > "$now_cmp" ]] || die "v1.json expired at $EXPIRES (it is now ${now_cmp}Z); a channel that is already expired is useless"

PREFIX="https://github.com/$REPO/releases/download/$TAG/"
jq -r '.bundles | to_entries[] | .key as $v | .value | to_entries[]
       | [$v, .key, (.value.sha256 // ""), ((.value.size // 0) | tostring), ((.value.urls // []) | join(" "))]
       | join("|")' "$OUT/v1.json" > "$SCR/entries"
[ -s "$SCR/entries" ] || die 'v1.json has no bundle entries'

: > "$SCR/triples"
: > "$SCR/attest"
: > "$SCR/expected"
printf '%s\n%s\n' v1.json SHA256SUMS >> "$SCR/expected"
while IFS='|' read -r ver triple sha size urls; do
  file=''
  for u in $urls; do
    case "$u" in "$PREFIX"*) file=${u#"$PREFIX"}; break ;; esac
  done
  [ -n "$file" ] || die "$ver $triple lists no URL under $PREFIX (the draft's own assets)"
  case "$file" in */*|'') die "$ver $triple names a nested file '$file'" ;; esac
  [ -f "$OUT/$file" ] || die "$ver $triple names $file but the draft has no such asset"
  have=$(sha256_of "$OUT/$file")
  [ "$have" = "$sha" ] || die "capsule digest mismatch for $ver $triple ($file): v1.json says $sha, the file is $have"
  hsize=$(size_of "$OUT/$file")
  [ "$hsize" = "$size" ] || die "capsule size mismatch for $ver $triple ($file): v1.json says $size, the file is $hsize"
  printf '%s\n' "$triple" >> "$SCR/triples"
  printf '%s\n' "$file" >> "$SCR/attest"
  printf '%s\n' "$file" >> "$SCR/expected"
  printf '  %-28s %-22s sha256 %.16s... %s bytes\n' "$triple" "$ver" "$have" "$hsize" >> "$SCR/summary"
done < "$SCR/entries"

for t in $TIER1; do
  grep -qxF -- "$t" "$SCR/triples" || die "v1.json lists no capsule for tier 1 target $t (support matrix: src/definitions/targets.toml)"
done

# 5. Launcher tarballs: one per tier 1 target, and nothing unexpected in the draft.
for t in $TIER1; do
  l="idris2x-$TAG-$t.tar.gz"
  [ -f "$OUT/$l" ] || die "the draft has no launcher tarball $l"
  printf '%s\n' "$l" >> "$SCR/attest"
  printf '%s\n' "$l" >> "$SCR/expected"
done
printf '%s\n' v1.json >> "$SCR/attest"
for f in "$OUT"/*; do
  b=$(basename "$f")
  grep -qxF -- "$b" "$SCR/expected" || die "unexpected asset $b in the draft: not a capsule listed in v1.json, a tier 1 launcher, v1.json or SHA256SUMS"
done

# 6. Build attestations (ADR 0010: verified before the channel is signed).
na=0
sort -u "$SCR/attest" > "$SCR/attest.u"
while IFS= read -r f; do
  gh attestation verify "$OUT/$f" --repo "$REPO" --deny-self-hosted-runners >/dev/null 2>"$SCR/att.err" \
    || { cat "$SCR/att.err" >&2; die "attestation verification FAILED for $f"; }
  na=$((na + 1))
done < "$SCR/attest.u"
printf 'sign-channel: %s attestations verified (--deny-self-hosted-runners)\n' "$na"

# 7. Summary, then the owner's confirmation.
printf '\n== %s ==\n' "$TAG"
printf 'channel_version %s, expires %s\n' "$CHV" "$EXPIRES"
printf 'capsules:\n'; sort "$SCR/summary"
printf 'launchers: %s tier 1 tarballs\n' "$(printf '%s\n' "$TIER1" | wc -l | tr -d ' ')"
printf '\nThis will sign %s/v1.json with the key %s\n' "$OUT" "$KEY"
printf 'Type "sign" to continue, anything else to stop: '
ans=''
IFS= read -r ans || { printf '\n'; die 'no confirmation on standard input; nothing was signed'; }
[ "$ans" = sign ] || die "confirmation was '$ans', not 'sign'; nothing was signed"

# 8. Sign. The secret key is passed by path to signify and goes nowhere else.
"$SIGNIFY" -S -s "$KEY" -m "$OUT/v1.json" -x "$OUT/v1.json.sig" \
  || { rm -f "$OUT/v1.json.sig"; die 'signify -S failed; nothing was signed'; }
[ -s "$OUT/v1.json.sig" ] || die 'signify wrote no signature'
if [ -n "$PUB" ]; then
  "$SIGNIFY" -V -p "$PUB" -m "$OUT/v1.json" -x "$OUT/v1.json.sig" >/dev/null \
    || { rm -f "$OUT/v1.json.sig"; die "the new signature does not verify with $PUB (wrong key?); it was removed"; }
  printf 'sign-channel: signature verifies with %s\n' "$PUB"
else
  printf 'sign-channel: no --pub given, so the signature was not verified against a public key\n'
fi

printf '\nSigned: %s/v1.json.sig\nNothing has been uploaded or published. To finish, run:\n\n' "$OUT"
printf '  gh release upload %s %s/v1.json.sig --repo %s\n' "$TAG" "$OUT" "$REPO"
printf '  gh release edit %s --draft=false --repo %s\n' "$TAG" "$REPO"
