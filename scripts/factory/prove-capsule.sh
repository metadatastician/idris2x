#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
# prove-capsule.sh — show that a freshly built capsule works on the machine that built it, through the real launcher.
# usage: prove-capsule.sh --capsule FILE.tar.gz --bundle FILE.bundle.json --launcher IDRIS2X --fixture FIXTURE_SERVER --work DIR [--port N]
# It (1) checks that the bundle record tells the truth about the tarball (sha256, size, file name); (2) makes a THROWAWAY
# signify key and a one-target channel signed with it, valid for one day, served on 127.0.0.1 by examples/fixture_server;
# (3) runs `idris2x pin`, `install --locked`, `exec -- idris2 --version`, `verify`, scripts/factory/run-canaries.sh on the
# installed capsule, and `idris2x selftest`. Any failure ends the run with a non-zero exit. The throwaway key never leaves DIR
# and is not trusted by anything but this run. No real key is read, written or needed.
# Needs jq, curl, and signify (signify-openbsd on Linux, signify-osx's `signify` on macOS).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
die() { echo "prove-capsule: FAIL: $*" >&2; exit 1; }
CAPSULE='' BUNDLE='' X='' FIXTURE='' WORK='' PORT=8199
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "usage: prove-capsule.sh --capsule F --bundle F --launcher BIN --fixture BIN --work DIR [--port N]"
  case "$1" in --capsule) CAPSULE=$2;; --bundle) BUNDLE=$2;; --launcher) X=$2;; --fixture) FIXTURE=$2;; --work) WORK=$2;; --port) PORT=$2;;
    *) die "unknown argument $1";; esac; shift 2
done
for v in CAPSULE BUNDLE X FIXTURE WORK; do [ -n "${!v}" ] || die "missing --$(echo "$v" | tr '[:upper:]' '[:lower:]')"; done
for f in "$CAPSULE" "$BUNDLE" "$X" "$FIXTURE"; do [ -f "$f" ] || die "no such file: $f"; done
if [ ! -x "$X" ] || [ ! -x "$FIXTURE" ]; then die "the launcher and the fixture server must be executable"; fi
SIGNIFY=''; for c in signify-openbsd signify; do command -v "$c" >/dev/null 2>&1 && { SIGNIFY=$c; break; }; done
[ -n "$SIGNIFY" ] || die "no signify found (signify-openbsd on Linux; on macOS brew install signify-osx)"
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }; else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
# The drills start from a known environment (ADR 0005): nothing the launcher resets is inherited from the caller.
while read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(IDRIS2_|DYLD_)|^(LD_LIBRARY_PATH|CHEZ|SCHEMEHEAPDIRS)$')

mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd); rm -rf "$WORK/serve" "$WORK/proj" "$WORK/cache"; mkdir -p "$WORK/serve" "$WORK/proj"
target=$(jq -r .target "$BUNDLE"); file=$(jq -r .file "$BUNDLE"); want=$(jq -r .sha256 "$BUNDLE"); size=$(jq -r .size "$BUNDLE")
chez=$(jq -r .chez "$BUNDLE"); glibc=$(jq -r '.min_glibc // ""' "$BUNDLE")
[ "$(basename "$CAPSULE")" = "$file" ] || die "the bundle names $file but the capsule is $(basename "$CAPSULE")"
got=$(sha "$CAPSULE"); [ "$got" = "$want" ] || die "bundle sha256 $want, tarball sha256 $got"
[ "$(wc -c < "$CAPSULE" | tr -d ' ')" = "$size" ] || die "bundle size $size, tarball size $(wc -c < "$CAPSULE" | tr -d ' ')"
echo "== bundle record matches the tarball: $file sha256=$got size=$size min_glibc=${glibc:-null}"

echo "== throwaway channel (key made now, never saved outside $WORK)"
"$SIGNIFY" -G -n -p "$WORK/throwaway.pub" -s "$WORK/throwaway.sec" -c "idris2x factory throwaway key" >/dev/null
cp "$CAPSULE" "$WORK/serve/$file"
expires=$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+1d +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg t "$target" --arg u "http://127.0.0.1:$PORT/$file" --arg sha "$want" --argjson size "$size" --arg g "$glibc" --arg cv "$chez" --arg exp "$expires" '
  { schema: 1, channel_version: 1, expires: $exp,
    bundles: { "idris2@0.8.0": { ($t): { urls: [$u], sha256: $sha, size: $size, min_glibc: (if $g == "" then null else $g end), chez: $cv } } },
    compat: { "idris2@0.8.0": { chez: $cv, platforms: [$t] } }, deprecated: [] }' > "$WORK/serve/v1.json"
"$SIGNIFY" -S -s "$WORK/throwaway.sec" -m "$WORK/serve/v1.json" -x "$WORK/serve/v1.json.sig"

export no_proxy="127.0.0.1,localhost" NO_PROXY="127.0.0.1,localhost"
"$FIXTURE" "$WORK/serve" "$PORT" > "$WORK/http.log" 2>&1 & srv=$!
trap 'kill "$srv" 2>/dev/null || true' EXIT
up=no; for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/v1.json" && { up=yes; break; }; sleep 1; done
[ "$up" = yes ] || die "the fixture server did not answer on 127.0.0.1:$PORT (see $WORK/http.log)"

cd "$WORK/proj"
export IDRIS2X_CACHE="$WORK/cache"
printf '[toolchain]\nidris2 = "0.8.0"\n\n[channel]\nurl = "http://127.0.0.1:%s/v1.json"\nkey = "%s"\n' "$PORT" "$(sed -n 2p "$WORK/throwaway.pub")" > idris2x.toml
echo "== idris2x pin 0.8.0";               "$X" pin 0.8.0
echo "== idris2x install --locked";        store=$("$X" install --locked)
if [ ! -f "$store/.complete" ] || [ ! -f "$store/capsule.json" ]; then die "install printed '$store', which is not a complete store entry"; fi
[ "$(jq -r .target "$store/capsule.json")" = "$target" ] || die "the installed capsule is for $(jq -r .target "$store/capsule.json"), not $target"
echo "installed: $store"
echo "== idris2x exec -- idris2 --version"; "$X" exec --locked -- idris2 --version
echo "== idris2x verify";                  "$X" verify
echo "== canaries on the installed capsule"; "$here/run-canaries.sh" "$store"
echo "== idris2x selftest";                "$X" selftest
echo "prove-capsule: OK ($target): installed through the launcher from a throwaway-signed channel; canaries and selftest passed"
