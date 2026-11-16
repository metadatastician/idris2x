#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# bench-decompress.sh RELEASE_DIR — wall time to unpack each capsule variant to a tmpfs-less tmp dir (3 runs, best)
set -euo pipefail
D=$1; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
best() { local b=999999 r; for i in 1 2 3; do rm -rf "$T/x"; mkdir "$T/x"; local t0=$(date +%s%N); eval "$1" >/dev/null 2>&1; r=$(( ($(date +%s%N)-t0)/1000000 )); [ $r -lt $b ] && b=$r; done; echo $b; }
for f in "$D"/idris2-*.tar.gz "$D"/idris2-*.tar.zst "$D"/idris2-*.tar.xz; do
  case "$f" in *.gz) c="tar -xzf '$f' -C '$T/x'";; *.zst) c="zstd -dc '$f' | tar -xf - -C '$T/x'";; *.xz) c="tar -xJf '$f' -C '$T/x'";; esac
  printf '%-8s %10s bytes  unpack best-of-3: %6s ms\n' "${f##*.}" "$(stat -c%s "$f")" "$(best "$c")"
done
printf 'gzip -1 (fast re-pack reference): '; t0=$(date +%s%N); gzip -1 -c "$D"/idris2-*.tar | wc -c | tr -d '\n'; echo " bytes in $(( ($(date +%s%N)-t0)/1000000 )) ms"
