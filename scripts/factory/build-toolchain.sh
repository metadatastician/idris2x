#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
# build-toolchain.sh — build Chez Scheme and Idris 2 from the pinned upstream sources and pack one capsule.
# usage: build-toolchain.sh --target TRIPLE --machine CHEZ_MACHINE --work DIR --out DIR
# Sources are pinned exactly as .github/workflows/chaos.yml pins them: the Chez Scheme 10.4.1 release tarball by sha256,
# Idris 2 v0.8.0 by commit. Both are built with their own upstream Makefiles and nothing is patched (zero-fork policy).
# Then scripts/proto/make-capsule.sh (no key, so nothing is signed) packs the capsule into DIR/out and writes
# OUT/<triple>.bundle.json. On Linux it refuses a capsule whose measured glibc floor is above the floor that
# src/definitions/targets.toml names for the target. Runs on Linux (inside the manylinux_2_28 image in CI) and on macOS.
# Needs: bash, curl, tar, gzip, make, a C compiler, git, jq, and on Linux objdump; GNU tar (gtar) for make-capsule.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
die() { echo "build-toolchain: FAIL: $*" >&2; exit 1; }
CHEZ_VERSION=10.4.1
CHEZ_URL=https://github.com/cisco/ChezScheme/releases/download/v10.4.1/csv10.4.1.tar.gz
CHEZ_SHA256=2e74952db7bc177f0c3602e2217a341ba677d733eec4cd7726418c3a4e1ef308
IDRIS2_VERSION=0.8.0
IDRIS2_URL=https://github.com/idris-lang/Idris2
IDRIS2_COMMIT=15a3e4e70843f7a34100f6470c04b791330788df
TARGET='' MACHINE='' WORK='' OUT=''
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "usage: build-toolchain.sh --target TRIPLE --machine CHEZ_MACHINE --work DIR --out DIR"
  case "$1" in --target) TARGET=$2;; --machine) MACHINE=$2;; --work) WORK=$2;; --out) OUT=$2;;
    *) die "unknown argument $1";; esac; shift 2
done
for v in TARGET MACHINE WORK OUT; do [ -n "${!v}" ] || die "missing --$(echo "$v" | tr '[:upper:]' '[:lower:]')"; done
for c in curl tar gzip make git jq cc; do command -v "$c" >/dev/null 2>&1 || die "$c is not installed"; done
case "$TARGET" in *-linux-gnu) command -v objdump >/dev/null 2>&1 || die "objdump is not installed (it measures the glibc floor)";; esac
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }; else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
jobs=$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2) | head -n 1 )
mkdir -p "$WORK" "$OUT"; WORK=$(cd "$WORK" && pwd); OUT=$(cd "$OUT" && pwd)
CHEZ_PREFIX=$WORK/chez-prefix; IDRIS2_PREFIX=$WORK/idris2-prefix

echo "== Chez Scheme $CHEZ_VERSION ($MACHINE)"
mkdir -p "$WORK/chez-dl"; cd "$WORK/chez-dl"
curl -sSfL --max-time 300 -o "csv$CHEZ_VERSION.tar.gz" "$CHEZ_URL"
got=$(sha "csv$CHEZ_VERSION.tar.gz")
[ "$got" = "$CHEZ_SHA256" ] || die "csv$CHEZ_VERSION.tar.gz sha256 is $got, expected $CHEZ_SHA256"
tar -xzf "csv$CHEZ_VERSION.tar.gz"
cd "csv$CHEZ_VERSION"
./configure --threads --disable-curses --disable-x11 --installprefix="$CHEZ_PREFIX"
make -j"$jobs"
make install
[ -d "$CHEZ_PREFIX/lib/csv$CHEZ_VERSION/$MACHINE" ] \
  || die "Chez built for the wrong machine type: expected lib/csv$CHEZ_VERSION/$MACHINE, found: $(echo "$CHEZ_PREFIX/lib/csv$CHEZ_VERSION"/*)"
CHEZ_SRC=$WORK/chez-dl/csv$CHEZ_VERSION

echo "== Idris 2 v$IDRIS2_VERSION"
src=$WORK/idris2-src
rm -rf "$src"
git clone --depth 1 --branch "v$IDRIS2_VERSION" "$IDRIS2_URL" "$src"
got=$(git -C "$src" rev-parse HEAD)
[ "$got" = "$IDRIS2_COMMIT" ] || die "Idris2 v$IDRIS2_VERSION is $got, expected $IDRIS2_COMMIT"
cd "$src"
export PATH="$CHEZ_PREFIX/bin:$PATH"
make bootstrap SCHEME="$CHEZ_PREFIX/bin/scheme" PREFIX="$IDRIS2_PREFIX"
make install SCHEME="$CHEZ_PREFIX/bin/scheme" PREFIX="$IDRIS2_PREFIX"

echo "== capsule"
cd "$root"
"$here/../proto/make-capsule.sh" --chez "$CHEZ_PREFIX" --idris2 "$IDRIS2_PREFIX" --chez-src "$CHEZ_SRC" --idris2-src "$src" \
  --chez-version "$CHEZ_VERSION" --idris2-version "$IDRIS2_VERSION" --target "$TARGET" --machine "$MACHINE" \
  --out "$OUT" --gzip-only --bundle-json "$OUT/$TARGET.bundle.json"
rm -f "$OUT/idris2-$IDRIS2_VERSION-$TARGET-chez$CHEZ_VERSION.tar"   # the uncompressed tar is an intermediate

floor=$("$root/scripts/lib/toml2json.sh" "$root/src/definitions/targets.toml" | jq -r --arg t "$TARGET" '.target[] | select(.triple == $t) | .min_glibc // empty')
got=$(jq -r '.min_glibc // empty' "$OUT/$TARGET.bundle.json")
if [ -n "$floor" ]; then
  [ -n "$got" ] || die "no glibc floor could be measured for $TARGET, but targets.toml promises $floor"
  top=$(printf '%s\n%s\n' "$got" "$floor" | sort -V | tail -n 1)
  [ "$top" = "$floor" ] || die "the capsule needs glibc $got, above the $floor floor that targets.toml promises for $TARGET"
  echo "glibc floor: measured $got, promised $floor: ok"
elif [ -n "$got" ]; then
  echo "glibc floor: measured $got (targets.toml promises none for $TARGET)"
fi
echo "build-toolchain: OK, $OUT/$TARGET.bundle.json"
