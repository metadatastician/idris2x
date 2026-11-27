#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# make-capsule.sh — Phase 0 prototype of the capsule factory.
# Merges installed Chez (+ Idris 2) prefixes into one relocatable tree, stamps capsule.json and
# sha256sums.txt and packs it reproducibly. With --key it also publishes a signed channel manifest (signify Ed25519);
# without --key it makes no manifest and signs nothing (the capsule factory CI signs nothing; the owner signs offline).
# Runs on Linux and on macOS (GNU tar is needed: gtar on macOS, found by name; it fails loudly without one).
# usage: make-capsule.sh --chez PREFIX [--idris2 PREFIX] --chez-version V --idris2-version V
#        --target TRIPLE --machine ta6le --out DIR [--key key.sec --pub key.pub --base-url URL]
#        [--chez-src DIR] [--idris2-src DIR] [--channel-version N] [--gzip-only] [--bundle-json FILE]
# --gzip-only skips the .tar.zst and .tar.xz comparison files. --bundle-json FILE writes the bundle record the factory
set -euo pipefail
CHEZ='' IDRIS2='' CV='' IV='' TARGET='' MACHINE='' OUT='' KEY='' PUB='' BASE='' CHEZ_SRC='' IDRIS2_SRC='' CHV='' GZONLY=no BUNDLE=''
while [ $# -gt 0 ]; do case "$1" in
  --gzip-only) GZONLY=yes; shift; continue;;
  --chez) CHEZ=$2;; --idris2) IDRIS2=$2;; --chez-version) CV=$2;; --idris2-version) IV=$2;;
  --target) TARGET=$2;; --machine) MACHINE=$2;; --out) OUT=$2;; --key) KEY=$2;; --pub) PUB=$2;;
  --base-url) BASE=$2;; --chez-src) CHEZ_SRC=$2;; --idris2-src) IDRIS2_SRC=$2;; --channel-version) CHV=$2;;
  --bundle-json) BUNDLE=$2;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; shift 2; done
for v in CHEZ CV IV TARGET MACHINE OUT; do [ -n "${!v}" ] || { echo "missing --$(echo $v | tr '[:upper:]' '[:lower:]')" >&2; exit 2; }; done
# Signing is all or nothing: a half-given set is a mistake, not a request to skip.
if [ -n "$KEY$PUB$BASE" ]; then
  for v in KEY PUB BASE; do [ -n "${!v}" ] || { echo "missing --$(echo $v | tr '[:upper:]' '[:lower:]') (--key, --pub and --base-url go together)" >&2; exit 2; }; done
fi
# GNU tar is required for the reproducible flags. macOS ships bsdtar; Homebrew and the GitHub macOS images provide gtar.
TAR=''; for c in gtar tar; do command -v "$c" >/dev/null 2>&1 && "$c" --version 2>/dev/null | grep -q 'GNU tar' && { TAR=$c; break; }; done
[ -n "$TAR" ] || { echo "make-capsule: GNU tar not found (tried gtar, tar); on macOS: brew install gnu-tar" >&2; exit 2; }
if command -v sha256sum >/dev/null 2>&1; then SHA256=(sha256sum); else SHA256=(shasum -a 256); fi
mkdir -p "$OUT"
NAME="idris2-$IV-$TARGET-chez$CV"
STAGE=$(mktemp -d -t capsule.XXXXXX); trap 'rm -rf "$STAGE"' EXIT

cp -a "$CHEZ"/. "$STAGE"/
rm -rf "$STAGE"/lib/csv*/examples
[ -n "$IDRIS2" ] && cp -a "$IDRIS2"/. "$STAGE"/
mkdir -p "$STAGE/licenses"
[ -n "$CHEZ_SRC" ] && { cp "$CHEZ_SRC/LICENSE" "$STAGE/licenses/ChezScheme-LICENSE"; cp "$CHEZ_SRC/NOTICE" "$STAGE/licenses/ChezScheme-NOTICE" 2>/dev/null || true; }
[ -n "$IDRIS2_SRC" ] && cp "$IDRIS2_SRC/LICENSE" "$STAGE/licenses/Idris2-LICENSE"

# The glibc floor is a Linux notion; a macOS capsule has none (null), and is not probed with objdump.
MIN_GLIBC=''
case "$TARGET" in
  *-linux-gnu) MIN_GLIBC=$(objdump -T "$STAGE/bin/scheme" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1 || true);;
esac
jq -n --arg name "$NAME" --arg iv "$IV" --arg cv "$CV" --arg t "$TARGET" --arg m "$MACHINE" --arg g "${MIN_GLIBC:-}" \
  --arg has_idris2 "$([ -n "$IDRIS2" ] && echo yes || echo no)" '{
  schema: 1, name: $name, idris2: (if $has_idris2=="yes" then $iv else null end), chez: $cv, target: $t, machine: $m,
  min_glibc: (if $g=="" then null else $g end),
  env: { IDRIS2_PREFIX: "${CAPSULE}", CHEZ: "${CAPSULE}/bin/scheme", SCHEMEHEAPDIRS: ("${CAPSULE}/lib/csv"+$cv+"/%m"),
         IDRIS2_INC_SRC: "${CAPSULE}/bin/idris2_app", LD_LIBRARY_PATH: "${CAPSULE}/bin/idris2_app", PATH: "${CAPSULE}/bin" },
  exec: ({ chez: ["bin/scheme"] } + if $has_idris2=="yes" then { idris2: ["bin/scheme","--program","bin/idris2_app/idris2.so"] } else {} end),
  probes: ["pure_eval","version_match"],
  licenses: ["licenses/ChezScheme-LICENSE","licenses/Idris2-LICENSE"] }' > "$STAGE/capsule.json"
(cd "$STAGE" && find . -type f ! -name sha256sums.txt -print0 | LC_ALL=C sort -z | xargs -0 "${SHA256[@]}") > "$STAGE/sha256sums.txt"

TARFLAGS=(--sort=name --mtime='2001-01-01 00:00Z' --owner=0 --group=0 --numeric-owner --format=gnu -C "$STAGE")
"$TAR" "${TARFLAGS[@]}" -cf "$OUT/$NAME.tar" .
# gzip from stdin: the same bytes as `gzip -9nkf` (no name, no time), and it works with the gzip on macOS as well.
gzip -9n < "$OUT/$NAME.tar" > "$OUT/$NAME.tar.gz"
if [ "$GZONLY" = no ]; then
  command -v zstd >/dev/null && zstd -19 -T0 -qf "$OUT/$NAME.tar" -o "$OUT/$NAME.tar.zst"
  command -v xz   >/dev/null && xz -9 -T0 -kf "$OUT/$NAME.tar"
fi
SHA=$("${SHA256[@]}" "$OUT/$NAME.tar.gz" | cut -d' ' -f1); SIZE=$(wc -c < "$OUT/$NAME.tar.gz" | tr -d ' ')
echo "capsule: $NAME.tar.gz sha256=$SHA size=$SIZE min_glibc=${MIN_GLIBC:-?} uncompressed=$(wc -c < "$OUT/$NAME.tar" | tr -d ' ')"
# shellcheck disable=SC2012  # a listing for people; the glob names this capsule only
ls -l "$OUT"/"$NAME".tar* | awk '{print "  " $5 "\t" $9}'
if [ -n "$BUNDLE" ]; then
  jq -n --arg t "$TARGET" --arg f "$NAME.tar.gz" --arg sha "$SHA" --argjson size "$SIZE" --arg g "${MIN_GLIBC:-}" --arg cv "$CV" \
    '{target: $t, file: $f, sha256: $sha, size: $size, min_glibc: (if $g=="" then null else $g end), chez: $cv}' > "$BUNDLE"
  echo "bundle: $BUNDLE"
fi

[ -n "$KEY" ] || { echo "no --key: no channel manifest made and nothing signed"; exit 0; }
# channel manifest: merge this bundle in, bump channel_version (monotonic)
M="$OUT/v1.json"; [ -f "$M" ] || echo '{"schema":1,"channel_version":0,"bundles":{},"compat":{},"deprecated":[]}' > "$M"
PREV=$(jq -r .channel_version "$M"); NEXT=${CHV:-$((PREV+1))}
jq --arg k "idris2@$IV" --arg t "$TARGET" --arg u1 "$BASE/$NAME.tar.gz" --arg sha "$SHA" --argjson size "$SIZE" \
   --arg g "${MIN_GLIBC:-}" --arg cv "$CV" --argjson next "$NEXT" --arg exp "$(date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ)" '
   .channel_version=$next | .expires=$exp |
   .bundles[$k][$t] = {urls: [$u1], sha256: $sha, size: $size, min_glibc: (if $g=="" then null else $g end), chez: $cv} |
   .compat[$k] = {chez: $cv, platforms: (.bundles[$k] | keys)}' "$M" > "$M.tmp" && mv "$M.tmp" "$M"
signify-openbsd -S -s "$KEY" -m "$M" -x "$M.sig"
echo "channel: $M channel_version=$NEXT signed with $(sed -n 1p "$PUB")"
