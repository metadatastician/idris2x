#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# chaos.sh — Phase 0 chaos drills for the prototype launcher.
# usage: chaos.sh CHEZ_PREFIX [IDRIS2_PREFIX] [CHEZ_SRC] [IDRIS2_SRC]
# Asserts: loud typed failures with stable exit codes, and store consistency (atomic-or-absent) under
# 404 primary, flipped byte, truncation+resume, concurrent installs, disk-full, tampered manifest,
# wrong key, rollback, expiry, offline, air-gap bundle, lock contention, unsafe tar, paths with spaces.
set -uo pipefail
P=$(cd "$(dirname "$0")" && pwd); X="$P/idris2x.sh"
CHEZ_PREFIX=$1; IDRIS2_PREFIX=${2:-}; CHEZ_SRC=${3:-}; IDRIS2_SRC=${4:-}
W=${CHAOS_WORK:-$(mktemp -d)}; OUT="$W/release"; mkdir -p "$OUT"; PORT=${PORT:-8099}
export no_proxy="127.0.0.1,localhost" NO_PROXY="127.0.0.1,localhost" IDRIS2X_QUIET=1
echo "== workdir $W"
signify-openbsd -G -n -p "$W/key.pub" -s "$W/key.sec" -c "idris2x prototype channel key" >/dev/null
signify-openbsd -G -n -p "$W/other.pub" -s "$W/other.sec" -c "attacker key" >/dev/null
"$P/make-capsule.sh" --chez "$CHEZ_PREFIX" ${IDRIS2_PREFIX:+--idris2 "$IDRIS2_PREFIX"} ${CHEZ_SRC:+--chez-src "$CHEZ_SRC"} ${IDRIS2_SRC:+--idris2-src "$IDRIS2_SRC"} \
  --chez-version 10.4.1 --idris2-version 0.8.0 --target "$(uname -m | sed 's/aarch64/aarch64/;s/amd64/x86_64/')-unknown-linux-gnu" --machine ta6le \
  --out "$OUT" --key "$W/key.sec" --pub "$W/key.pub" --base-url "http://127.0.0.1:$PORT" || { echo "factory failed"; exit 1; }
TGZ=$(ls "$OUT"/idris2-*.tar.gz | head -1); NAME=$(basename "$TGZ"); SIZE=$(stat -c%s "$TGZ")
cp "$TGZ" "$OUT/corrupt.tar.gz"; printf '\xff' | dd of="$OUT/corrupt.tar.gz" bs=1 seek=$((SIZE/2)) conv=notrunc 2>/dev/null
head -c $((SIZE/2)) "$TGZ" > "$OUT/trunc.tar.gz"
# unsafe tarball: same gzip but with a '../evil' member
mkdir -p "$W/evil/sub"; echo x > "$W/evil/evil.txt"; (cd "$W/evil/sub" && tar -P -czf "$OUT/unsafe.tar.gz" ../evil.txt 2>/dev/null); UNSAFE_SHA=$(sha256sum "$OUT/unsafe.tar.gz" | cut -d' ' -f1)
"${FIXTURE_SERVER:?set FIXTURE_SERVER to the built examples/fixture_server binary}" "$OUT" "$PORT" >"$W/http.log" 2>&1 & SRV=$!; trap 'kill $SRV 2>/dev/null' EXIT; sleep 1
export IDRIS2X_CHANNEL_URL="http://127.0.0.1:$PORT/v1.json" IDRIS2X_PUBKEY_FILE="$W/key.pub"
pass=0; fail=0
t() { local name=$1 expect=$2; shift 2; local rc t0; t0=$(date +%s%N); "$@" >"$W/out.txt" 2>&1; rc=$?; local ms=$(( ($(date +%s%N)-t0)/1000000 ))
  if [ "$rc" = "$expect" ]; then pass=$((pass+1)); printf '[PASS] %-36s exit=%s %5dms %s\n' "$name" "$rc" "$ms" "$(grep -o 'E-[A-Z-]*' "$W/out.txt" | head -1)"
  else fail=$((fail+1)); printf '[FAIL] %-36s exit=%s expected=%s\n' "$name" "$rc" "$expect"; sed 's/^/        /' "$W/out.txt" | head -4; fi; }
assert() { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); printf '[PASS] %s\n' "$name"; else fail=$((fail+1)); printf '[FAIL] %s\n' "$name"; fi; }
fresh() { export IDRIS2X_CACHE="$W/cache-$1"; rm -rf "$IDRIS2X_CACHE"; mkdir -p "$W/proj-$1"; cd "$W/proj-$1" || exit 1; }
pin() { "$X" pin 0.8.0 >/dev/null 2>&1 || echo "  (pin failed)"; }
with_urls() { jq --argjson u "$1" '.capsules[] .urls = $u' idris2x.lock > lock.tmp && mv lock.tmp idris2x.lock; }
U="http://127.0.0.1:$PORT"

echo "== T1 happy path"; fresh t1
t "pin 0.8.0"                        0 "$X" pin 0.8.0
t "install --locked (cold)"          0 "$X" install --locked
DIG=$(jq -r '.capsules[].sha256' idris2x.lock); STORE="$IDRIS2X_CACHE/store/sha256-$DIG"
assert "store/.complete present"     test -f "$STORE/.complete"
assert "no staging leftovers in tmp" test -z "$(ls -A "$IDRIS2X_CACHE/tmp" | grep -v fetch.log)"
t "install --locked (warm, no-op)"   0 "$X" install --locked
assert "run -- chez evaluates 42"    test "$(echo '(display (+ 40 2))' | "$X" run -- -q)" = 42
t "verify (sha256sums + probes)"     0 "$X" verify
t "doctor"                           0 "$X" doctor
t "env --json"                       0 "$X" env --json
echo "== T2 404 on primary, mirror good"; fresh t2; pin; with_urls "[\"$U/missing.tar.gz\",\"$U/$NAME\"]"
t "404 primary -> mirror succeeds"   0 "$X" install --locked
echo "== T3 flipped byte"; fresh t3; pin; with_urls "[\"$U/corrupt.tar.gz\"]"
t "flipped byte -> E-HASH-MISMATCH"  11 "$X" install --locked
assert "store absent after mismatch" test ! -e "$IDRIS2X_CACHE/store/sha256-$DIG"
assert "no .part left behind"        test ! -e "$IDRIS2X_CACHE/tmp/sha256-$DIG.part"
echo "== T4 truncated, then resume"; fresh t4; pin; with_urls "[\"$U/trunc.tar.gz\"]"
t "truncated -> E-HASH-MISMATCH"     11 "$X" install --locked
mkdir -p "$IDRIS2X_CACHE/tmp"; cp "$OUT/trunc.tar.gz" "$IDRIS2X_CACHE/tmp/sha256-$DIG.part"; with_urls "[\"$U/$NAME\"]"
t "resume from partial .part"        0 "$X" install --locked
assert "server answered the resume with 206 (Range)" grep -q "^206 " "$W/http.log"
echo "== T5 four concurrent installs"; fresh t5; pin; pids=()
for i in 1 2 3 4; do "$X" install --locked >"$W/c$i.out" 2>&1 & pids+=($!); done
okc=0; for p in "${pids[@]}"; do wait "$p" && okc=$((okc+1)); done
assert "all 4 concurrent installs exit 0 ($okc/4)" test "$okc" = 4
assert "exactly one store dir"       test "$(ls -1 "$IDRIS2X_CACHE/store" | wc -l)" = 1
assert "no stage leftovers"          test -z "$(ls -A "$IDRIS2X_CACHE/tmp" | grep -v fetch.log)"
echo "== T6 disk-full analogue (ulimit -f)"; fresh t6; pin
t "write limit -> typed E- error"    14 bash -c 'ulimit -f 200; exec "$0" install --locked' "$X"
assert "store has no half-capsule"   test ! -e "$IDRIS2X_CACHE/store/sha256-$DIG"
echo "== T7 trust: tamper, wrong key, rollback, expiry"; fresh t7
cp "$OUT/v1.json" "$W/v1.good"; jq '.channel_version=999' "$W/v1.good" > "$OUT/v1.json"
t "tampered manifest -> E-SIG-INVALID" 12 "$X" pin 0.8.0
cp "$W/v1.good" "$OUT/v1.json"
IDRIS2X_PUBKEY_FILE="$W/other.pub" t "wrong pinned key -> E-SIG-INVALID" 12 "$X" pin 0.8.0
pin; jq '.channel.version=5' idris2x.lock > l.tmp && mv l.tmp idris2x.lock
t "channel rollback -> E-CHANNEL-ROLLBACK" 22 "$X" pin 0.8.0
rm idris2x.lock; jq '.expires="2020-01-01T00:00:00Z"' "$W/v1.good" > "$OUT/v1.json"; signify-openbsd -S -s "$W/key.sec" -m "$OUT/v1.json" -x "$OUT/v1.json.sig"
t "expired manifest -> E-CHANNEL-EXPIRED" 23 "$X" pin 0.8.0
IDRIS2X_ALLOW_EXPIRED=1 t "expired + explicit override -> ok" 0 "$X" pin 0.8.0
cp "$W/v1.good" "$OUT/v1.json"; signify-openbsd -S -s "$W/key.sec" -m "$OUT/v1.json" -x "$OUT/v1.json.sig"
echo "== T8 offline"; fresh t8; pin
IDRIS2X_OFFLINE=1 t "offline cache miss -> E-OFFLINE" 20 "$X" install --locked
echo "== T9 air-gap: fetch then install --from offline"; fresh t9; pin
t "fetch -o bundle"                  0 "$X" fetch -o "$W/bundle.tar.gz"
cp idris2x.lock "$W/lock.copy"; fresh t9b; cp "$W/lock.copy" idris2x.lock
IDRIS2X_OFFLINE=1 t "install --from bundle (offline)" 0 "$X" install --from "$W/bundle.tar.gz"
assert "bundle kept after --from"    test -f "$W/bundle.tar.gz"
echo "== T10 lock contention"; fresh t10; pin; mkdir -p "$IDRIS2X_CACHE/locks"
( exec 9>"$IDRIS2X_CACHE/locks/sha256-$DIG.lock"; flock 9; sleep 4 ) & HOLD=$!; sleep 0.3
IDRIS2X_LOCK_TIMEOUT=1 t "lock held -> E-LOCK-TIMEOUT" 15 "$X" install --locked; wait "$HOLD"   # bare wait would also wait for the http server
echo "== T11 unsafe tar member"; fresh t11; pin
jq --arg s "$UNSAFE_SHA" --arg u "$U/unsafe.tar.gz" '.capsules[] |= (.sha256=$s | .urls=[$u] | .size=100)' idris2x.lock > l.tmp && mv l.tmp idris2x.lock
t "'../' member -> E-CAPSULE-INVALID" 21 "$X" install --locked
assert "nothing escaped the staging dir" test ! -e "$IDRIS2X_CACHE/tmp/evil.txt" -a ! -e "$IDRIS2X_CACHE/evil.txt"
echo "== T12 cache path with spaces + unsupported-target lock"; fresh "t12 with spaces"; pin
t "install into path with spaces"    0 "$X" install --locked
assert "chez runs from spaced path"  test "$(echo '(display (+ 40 2))' | "$X" run -- -q)" = 42
jq '.capsules |= with_entries(.key="riscv64-unknown-linux-gnu")' idris2x.lock > l.tmp && mv l.tmp idris2x.lock
t "lock lacks host target -> E-PIN-NOT-FOUND" 10 "$X" install --locked
echo "== T13 gc"; fresh t13; pin; "$X" install --locked >/dev/null 2>&1; mkdir -p "$IDRIS2X_CACHE/store/sha256-deadbeef"
t "gc removes incomplete dirs"       0 "$X" gc --keep-last 3
assert "incomplete dir gone, complete kept" test ! -e "$IDRIS2X_CACHE/store/sha256-deadbeef" -a -f "$IDRIS2X_CACHE/store/sha256-$DIG/.complete"
if [ -n "$IDRIS2_PREFIX" ]; then echo "== T14 idris2 canaries (space-free cache)"; fresh t14; pin; "$X" install --locked >/dev/null 2>&1
  t "exec -- idris2 --version"       0 "$X" exec -- --version
  t "selftest (chez_codegen, relocatable_artifact, refc)" 0 "$X" selftest
  sed 's/^/        /' "$W/out.txt"
  echo "== T15 documented limitation: compiled programs vs spaces in the store path"; fresh "t15 with spaces"; pin; "$X" install --locked >/dev/null 2>&1
  t "exec works from spaced store"   0 "$X" exec -- --version
  t "selftest: compiled program breaks (shebang) -> E-PROBE-CODEGEN with fix hint" 17 "$X" selftest
  grep -q 'splits shebang lines at spaces' "$W/out.txt" && { pass=$((pass+1)); echo "[PASS] diagnosis names the shebang/space cause"; } || { fail=$((fail+1)); echo "[FAIL] diagnosis missing"; }
fi
echo; echo "== RESULT: $pass passed, $fail failed  (work: $W)"; [ "$fail" = 0 ]
