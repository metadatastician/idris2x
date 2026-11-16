#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# make-capsule.sh — Phase 0 prototype of the capsule factory.
# Merges installed Chez (+ Idris 2) prefixes into one relocatable tree, stamps capsule.json and
# sha256sums.txt, packs it reproducibly, and publishes a signed channel manifest (signify Ed25519).
# usage: make-capsule.sh --chez PREFIX [--idris2 PREFIX] --chez-version V --idris2-version V
#        --target TRIPLE --machine ta6le --out DIR --key key.sec --pub key.pub --base-url URL
#        [--chez-src DIR] [--idris2-src DIR] [--channel-version N]
set -euo pipefail
CHEZ= IDRIS2= CV= IV= TARGET= MACHINE= OUT= KEY= PUB= BASE= CHEZ_SRC= IDRIS2_SRC= CHV=
while [ $# -gt 0 ]; do case "$1" in
  --chez) CHEZ=$2;; --idris2) IDRIS2=$2;; --chez-version) CV=$2;; --idris2-version) IV=$2;;
  --target) TARGET=$2;; --machine) MACHINE=$2;; --out) OUT=$2;; --key) KEY=$2;; --pub) PUB=$2;;
  --base-url) BASE=$2;; --chez-src) CHEZ_SRC=$2;; --idris2-src) IDRIS2_SRC=$2;; --channel-version) CHV=$2;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; shift 2; done
for v in CHEZ CV IV TARGET MACHINE OUT KEY PUB BASE; do [ -n "${!v}" ] || { echo "missing --$(echo $v | tr A-Z a-z)" >&2; exit 2; }; done
mkdir -p "$OUT"
NAME="idris2-$IV-$TARGET-chez$CV"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/capsule.XXXXXX"); trap 'rm -rf "$STAGE"' EXIT

cp -a "$CHEZ"/. "$STAGE"/
rm -rf "$STAGE"/lib/csv*/examples
[ -n "$IDRIS2" ] && cp -a "$IDRIS2"/. "$STAGE"/
mkdir -p "$STAGE/licenses"
[ -n "$CHEZ_SRC" ] && { cp "$CHEZ_SRC/LICENSE" "$STAGE/licenses/ChezScheme-LICENSE"; cp "$CHEZ_SRC/NOTICE" "$STAGE/licenses/ChezScheme-NOTICE" 2>/dev/null || true; }
[ -n "$IDRIS2_SRC" ] && cp "$IDRIS2_SRC/LICENSE" "$STAGE/licenses/Idris2-LICENSE"

MIN_GLIBC=$(objdump -T "$STAGE/bin/scheme" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1 || true)
jq -n --arg name "$NAME" --arg iv "$IV" --arg cv "$CV" --arg t "$TARGET" --arg m "$MACHINE" --arg g "${MIN_GLIBC:-}" \
  --arg has_idris2 "$([ -n "$IDRIS2" ] && echo yes || echo no)" '{
  schema: 1, name: $name, idris2: (if $has_idris2=="yes" then $iv else null end), chez: $cv, target: $t, machine: $m,
  min_glibc: (if $g=="" then null else $g end),
  env: { IDRIS2_PREFIX: "${CAPSULE}", CHEZ: "${CAPSULE}/bin/scheme", SCHEMEHEAPDIRS: ("${CAPSULE}/lib/csv"+$cv+"/%m"),
         IDRIS2_INC_SRC: "${CAPSULE}/bin/idris2_app", LD_LIBRARY_PATH: "${CAPSULE}/bin/idris2_app", PATH: "${CAPSULE}/bin" },
  exec: { chez: ["bin/scheme"], idris2: ["bin/scheme","--program","bin/idris2_app/idris2.so"] },
  probes: ["pure_eval","version_match"],
  licenses: ["licenses/ChezScheme-LICENSE","licenses/Idris2-LICENSE"] }' > "$STAGE/capsule.json"
(cd "$STAGE" && find . -type f ! -name sha256sums.txt -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$STAGE/sha256sums.txt"

TARFLAGS=(--sort=name --mtime='2001-01-01 00:00Z' --owner=0 --group=0 --numeric-owner --format=gnu -C "$STAGE")
tar "${TARFLAGS[@]}" -cf "$OUT/$NAME.tar" .
gzip -9nkf "$OUT/$NAME.tar"
command -v zstd >/dev/null && zstd -19 -T0 -qf "$OUT/$NAME.tar" -o "$OUT/$NAME.tar.zst"
command -v xz   >/dev/null && xz -9 -T0 -kf "$OUT/$NAME.tar"
SHA=$(sha256sum "$OUT/$NAME.tar.gz" | cut -d' ' -f1); SIZE=$(stat -c%s "$OUT/$NAME.tar.gz")
echo "capsule: $NAME.tar.gz sha256=$SHA size=$SIZE min_glibc=${MIN_GLIBC:-?} uncompressed=$(stat -c%s "$OUT/$NAME.tar")"
ls -l "$OUT"/$NAME.tar* | awk '{print "  " $5 "\t" $9}'

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
