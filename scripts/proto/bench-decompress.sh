#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# bench-decompress.sh RELEASE_DIR — wall time to unpack each capsule variant to a tmpfs-less tmp dir (3 runs, best)
set -euo pipefail
D=$1; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unpack() { case "$1" in *.gz) tar -xzf "$1" -C "$2";; *.zst) zstd -dc "$1" | tar -xf - -C "$2";; *.xz) tar -xJf "$1" -C "$2";; esac; }
best() { local b=999999 r t0; for _ in 1 2 3; do rm -rf "$T/x"; mkdir "$T/x"; t0=$(date +%s%N); unpack "$1" "$T/x" >/dev/null 2>&1; r=$(( ($(date +%s%N)-t0)/1000000 )); [ $r -lt $b ] && b=$r; done; echo $b; }
for f in "$D"/idris2-*.tar.gz "$D"/idris2-*.tar.zst "$D"/idris2-*.tar.xz; do
  printf '%-8s %10s bytes  unpack best-of-3: %6s ms\n' "${f##*.}" "$(stat -c%s "$f")" "$(best "$f")"
done
printf 'gzip -1 (fast re-pack reference): '; t0=$(date +%s%N); gzip -1 -c "$D"/idris2-*.tar | wc -c | tr -d '\n'; echo " bytes in $(( ($(date +%s%N)-t0)/1000000 )) ms"
