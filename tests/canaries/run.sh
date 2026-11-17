#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# run.sh — run the 12 atomic canaries against a capsule root (relocated tree with bin/scheme + bin/idris2_app/idris2.so).
# usage: tests/canaries/run.sh CAPSULE_ROOT [--quick]      exit 0 only if every selected canary passes
set -uo pipefail
ROOT=$(cd "$1" && pwd); QUICK=${2:-}; HERE=$(cd "$(dirname "$0")" && pwd)
CV=$(jq -r .chez "$ROOT/capsule.json" 2>/dev/null || echo 10.4.1); IV=$(jq -r .idris2 "$ROOT/capsule.json" 2>/dev/null || echo 0.8.0)
export IDRIS2_PREFIX="$ROOT" CHEZ="$ROOT/bin/scheme" SCHEMEHEAPDIRS="$ROOT/lib/csv$CV/%m" IDRIS2_INC_SRC="$ROOT/bin/idris2_app"
export LD_LIBRARY_PATH="$ROOT/bin/idris2_app${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" DYLD_LIBRARY_PATH="$ROOT/bin/idris2_app" PATH="$ROOT/bin:$PATH"
idris2() { "$ROOT/bin/scheme" --program "$ROOT/bin/idris2_app/idris2.so" "$@"; }
scheme() { "$ROOT/bin/scheme" "$@"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; pass=0; fail=0
check() { local name=$1 expect=$2 got=$3; if [ "$got" = "$expect" ]; then pass=$((pass+1)); printf '[PASS] %-22s %s\n' "$name" "$got"; else fail=$((fail+1)); printf '[FAIL] %-22s got: %s\n' "$name" "$(echo "$got" | head -3 | tr '\n' '|')"; fi; }
ms() { local t0=$1; echo "$(( ($(date +%s%N)-t0)/1000000 ))ms"; }
# 1 pure_eval
check pure_eval "42" "$(scheme --script "$HERE/src/pure_eval.ss" 2>&1)"
# 2 chez_codegen
t0=$(date +%s%N); cp "$HERE/src/ChezCodegen.idr" "$T/ChezCodegen.idr"; out=$(cd "$T" && idris2 -o chez_codegen ChezCodegen.idr 2>&1 >/dev/null && ./build/exec/chez_codegen 2>&1); check chez_codegen "chez_codegen ok" "$out"; echo "       (compile+run $(ms $t0))"
# 3 refc_codegen
if command -v cc >/dev/null; then out=$(cd "$T" && idris2 --cg refc -o refc_codegen ChezCodegen.idr 2>&1 >/dev/null && ./build/exec/refc_codegen 2>&1); check refc_codegen "chez_codegen ok" "$out"; else echo "[skip] refc_codegen (no cc)"; fi
# 4 c_ffi_support
cp "$HERE/src/CFfiSupport.idr" "$T/CFfiSupport.idr"; out=$(cd "$T" && idris2 -o c_ffi CFfiSupport.idr 2>&1 >/dev/null && ./build/exec/c_ffi 2>&1); check c_ffi_support "c_ffi_support ok" "$out"
# 5 ipkg_multi_module
cp -r "$HERE/ipkg_multi_module" "$T/pkg"; out=$(cd "$T/pkg" && idris2 --build canary.ipkg 2>&1 >/dev/null && ./build/exec/ipkg_multi_module 2>&1); check ipkg_multi_module "ipkg_multi_module ok 42" "$out"
# 12 version_match
check version_match "ok" "$(idris2 --version 2>&1 | grep -q -E "^Idris 2, version $IV(-[0-9a-f]+)?\$" && echo ok || idris2 --version 2>&1)"
if [ "$QUICK" != --quick ]; then
# 6 relocatable_artifact: compiled program keeps working after being moved and with a clean environment
mkdir -p "$T/moved dir"; cp -a "$T/build/exec" "$T/moved dir/exec"; out=$(env -i PATH=/usr/bin:/bin "$T/moved dir/exec/chez_codegen" 2>&1); check relocatable_artifact "chez_codegen ok" "$out"
# 7 prelude_base
cp "$HERE/src/PreludeBase.idr" "$T/PreludeBase.idr"; out=$(cd "$T" && idris2 -o prelude_base PreludeBase.idr 2>&1 >/dev/null && ./build/exec/prelude_base 2>&1); check prelude_base "prelude_base ok 55 3 [1, 2, 3]" "$out"
# 8 concurrent_build: two independent compilations at once in separate build dirs
mkdir -p "$T/c1" "$T/c2"; cp "$HERE/src/ChezCodegen.idr" "$T/c1/A.idr"; cp "$HERE/src/PreludeBase.idr" "$T/c2/B.idr"
(cd "$T/c1" && idris2 -o a A.idr >/dev/null 2>&1) & p1=$!; (cd "$T/c2" && idris2 -o b B.idr >/dev/null 2>&1) & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?; check concurrent_build "ok" "$([ $r1 = 0 ] && [ $r2 = 0 ] && [ -x "$T/c1/build/exec/a" ] && [ -x "$T/c2/build/exec/b" ] && echo ok || echo "rc=$r1,$r2")"
# 9 unicode_paths
mkdir -p "$T/cänary ünïcode/src"; cp "$HERE/src/ChezCodegen.idr" "$T/cänary ünïcode/src/Main.idr"; out=$(cd "$T/cänary ünïcode" && idris2 -o uni src/Main.idr 2>&1 >/dev/null && ./build/exec/uni 2>&1); check unicode_paths "chez_codegen ok" "$out"
# 10 large_module: 400 generated definitions typecheck and run
{ echo "module Main"; for i in $(seq 1 400); do echo "f$i : Nat -> Nat"; echo "f$i x = x + $i"; done; echo "main : IO ()"; echo "main = putStrLn (\"large_module ok \" ++ show (f400 (f1 0)))"; } > "$T/Large.idr"
t0=$(date +%s%N); out=$(cd "$T" && idris2 -o large Large.idr 2>&1 >/dev/null && ./build/exec/large 2>&1); check large_module "large_module ok 401" "$out"; echo "       (compile+run $(ms $t0))"
# 11 chez_threads
check chez_threads "chez_threads ok" "$(scheme --script "$HERE/src/chez_threads.ss" 2>&1)"
fi
echo "== canaries: $pass passed, $fail failed"; [ "$fail" = 0 ]
