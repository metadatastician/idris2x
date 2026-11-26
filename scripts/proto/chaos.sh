#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# chaos.sh — Phase 0 chaos drills for the prototype launcher.
# usage: chaos.sh CHEZ_PREFIX [IDRIS2_PREFIX] [CHEZ_SRC] [IDRIS2_SRC]
# Asserts: loud typed failures with stable exit codes, and store consistency (atomic-or-absent) under
# 404 primary, flipped byte, truncation+resume, concurrent installs, disk-full, tampered manifest,
# wrong key, rollback, expiry, offline, air-gap bundle, lock contention, unsafe tar, paths with spaces.
# Wording is a contract too: `says` compares the whole message with the text rendered from src/errors/errors.toml for the
# expected case and the drill's real values, and dx-golden.sh pins that text. Run once per style: IDRIS2X_STYLE=a|b (default b).
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
says() { local name=$1; shift    # says NAME ID CASE key=value... : the last command printed exactly this message and nothing else
  if "$X" __render plain "$@" > "$W/want.txt" 2>&1 && diff <(sed -E "${MASK:-s/^//}" "$W/want.txt") <(sed -E "${MASK:-s/^//}" "$W/out.txt") > "$W/diff.txt"; then pass=$((pass+1)); printf '[PASS] %s\n' "$name"
  else fail=$((fail+1)); printf '[FAIL] %s\n' "$name"; sed 's/^/        /' "$W/diff.txt" | head -12; fi; }
keyid() { sed -n 2p "$1" | base64 -d | tail -c +3 | head -c 8 | od -An -tx1 | tr -d ' \n'; }
HOST=$(uname -m | sed 's/amd64/x86_64/;s/arm64/aarch64/')-unknown-linux-gnu; unset NO_COLOR IDRIS2X_COLOR IDRIS2X_JSON IDRIS2X_ERROR_FILE
fresh() { export IDRIS2X_CACHE="$W/cache-$1"; rm -rf "$IDRIS2X_CACHE"; mkdir -p "$W/proj-$1"; cd "$W/proj-$1" || exit 1; }
pin() { "$X" pin 0.8.0 >/dev/null 2>&1 || echo "  (pin failed)"; }
with_urls() { jq --argjson u "$1" '.capsules[] .urls = $u' idris2x.lock > lock.tmp && mv lock.tmp idris2x.lock; }
U="http://127.0.0.1:$PORT"

echo "== T0 wording contract (style ${IDRIS2X_STYLE:-b})"
assert "dx-golden: every rendered message matches docs/dx/ERROR-CATALOGUE-RENDERED.adoc" "$P/dx-golden.sh" --check
fresh t0
t "no lock file -> E-PIN-NOT-FOUND"  10 "$X" install --locked
says "  exact text: no-lock"         E-PIN-NOT-FOUND no-lock lock=idris2x.lock dir="$(pwd)"
t "unknown version -> E-PIN-NOT-FOUND" 10 "$X" pin 9.9.9
says "  exact text: no-version"      E-PIN-NOT-FOUND no-version lock=idris2x.lock version=9.9.9 available=0.8.0
assert "  a failed pin wrote no lock" test ! -e idris2x.lock
fresh t0b
IDRIS2X_OFFLINE=1 t "offline pin, nothing cached -> E-OFFLINE" 20 "$X" pin 0.8.0
says "  exact text: no-manifest"     E-OFFLINE no-manifest cache="$IDRIS2X_CACHE/manifests/v1.json" mode=IDRIS2X_OFFLINE=1 version=0.8.0

echo "== T1 happy path"; fresh t1
t "pin 0.8.0"                        0 "$X" pin 0.8.0
t "install --locked (cold)"          0 "$X" install --locked
DIG=$(jq -r '.capsules[].sha256' idris2x.lock); STORE="$IDRIS2X_CACHE/store/sha256-$DIG"
assert "  a successful install prints the store path and nothing else" test "$(cat "$W/out.txt")" = "$STORE"
assert "store/.complete present"     test -f "$STORE/.complete"
assert "no staging leftovers in tmp" test -z "$(find "$IDRIS2X_CACHE/staging" -mindepth 1 -maxdepth 1 ! -name fetch.log -print -quit)"
t "install --locked (warm, no-op)"   0 "$X" install --locked
assert "run -- chez evaluates 42"    test "$(echo '(display (+ 40 2))' | "$X" run -- -q)" = 42
t "verify (sha256sums + probes)"     0 "$X" verify
t "doctor"                           0 "$X" doctor
t "env --json"                       0 "$X" env --json
echo "== T2 404 on primary, mirror good"; fresh t2; pin; with_urls "[\"$U/missing.tar.gz\",\"$U/$NAME\"]"
t "404 primary -> mirror succeeds"   0 "$X" install --locked
echo "== T3 flipped byte"; fresh t3; pin; with_urls "[\"$U/corrupt.tar.gz\"]"
t "flipped byte -> E-HASH-MISMATCH"  11 "$X" install --locked
BADSHA=$(sha256sum "$OUT/corrupt.tar.gz" | cut -d' ' -f1)
says "  exact text: download"        E-HASH-MISMATCH download lock=idris2x.lock want="sha256:$DIG" got="sha256:$BADSHA" bytes="$SIZE bytes (the lock says $SIZE)" source="$U/corrupt.tar.gz"
IDRIS2X_JSON=1 IDRIS2X_ERROR_FILE="$W/err.json" t "same failure with --json and an error file" 11 "$X" install --locked
assert "  stderr is one JSON object naming id, case and exit" test "$(jq -r '[.id,.case,(.exit|tostring),.fix.command,.fix.auto]|join(" ")' "$W/out.txt")" = "E-HASH-MISMATCH download 11 idris2x install --locked safe"
assert "  IDRIS2X_ERROR_FILE holds the same object" test "$(jq -c . "$W/err.json")" = "$(jq -c . "$W/out.txt")"
IDRIS2X_COLOR=always t "same failure, colour forced" 11 "$X" install --locked
assert "  colour form carries escape sequences" grep -q $'\x1b\\[' "$W/out.txt"
NO_COLOR=1 t "same failure, NO_COLOR=1" 11 "$X" install --locked
assert "  NO_COLOR output has no escape byte" test -z "$(grep $'\x1b' "$W/out.txt")"
assert "store absent after mismatch" test ! -e "$IDRIS2X_CACHE/store/sha256-$DIG"
assert "no .part left behind"        test ! -e "$IDRIS2X_CACHE/staging/sha256-$DIG.part"
echo "== T4 truncated, then resume"; fresh t4; pin; with_urls "[\"$U/trunc.tar.gz\"]"
t "truncated -> E-HASH-MISMATCH"     11 "$X" install --locked
says "  exact text: download (size shows the truncation)" E-HASH-MISMATCH download lock=idris2x.lock want="sha256:$DIG" got="sha256:$(sha256sum "$OUT/trunc.tar.gz" | cut -d' ' -f1)" bytes="$((SIZE/2)) bytes (the lock says $SIZE)" source="$U/trunc.tar.gz"
mkdir -p "$IDRIS2X_CACHE/staging"; cp "$OUT/trunc.tar.gz" "$IDRIS2X_CACHE/staging/sha256-$DIG.part"; with_urls "[\"$U/$NAME\"]"
t "resume from partial .part"        0 "$X" install --locked
assert "server answered the resume with 206 (Range)" grep -q "^206 " "$W/http.log"
echo "== T5 four concurrent installs"; fresh t5; pin; pids=()
for i in 1 2 3 4; do "$X" install --locked >"$W/c$i.out" 2>&1 & pids+=($!); done
okc=0; for p in "${pids[@]}"; do wait "$p" && okc=$((okc+1)); done
assert "all 4 concurrent installs exit 0 ($okc/4)" test "$okc" = 4
assert "exactly one store dir"       test "$(ls -1 "$IDRIS2X_CACHE/store" | wc -l)" = 1
assert "no stage leftovers"          test -z "$(find "$IDRIS2X_CACHE/staging" -mindepth 1 -maxdepth 1 ! -name fetch.log -print -quit)"
echo "== T6 disk-full analogue (ulimit -f)"; fresh t6; pin
t "write limit -> E-STORE-IO (the disk, not the network)" 24 bash -c 'ulimit -f 200; exec "$0" install --locked' "$X"
says "  exact text: write-failed"    E-STORE-IO write-failed detail="downloading the capsule (the file size limit was reached)" path="$IDRIS2X_CACHE"
with_urls "[\"$U/missing.tar.gz\",\"http://127.0.0.1:1/none.tar.gz\"]"
t "every mirror fails -> E-NETWORK"  14 "$X" install --locked
says "  exact text: all-mirrors-failed (each address with its own reason)" E-NETWORK all-mirrors-failed digest="sha256:$DIG" tried="$U/missing.tar.gz: (22) The requested URL returned error: 404; http://127.0.0.1:1/none.tar.gz: (7) Failed to connect to 127.0.0.1 port 1 after 0 ms: Couldn't connect to server" log="$IDRIS2X_CACHE/staging/fetch.log"
assert "store has no half-capsule"   test ! -e "$IDRIS2X_CACHE/store/sha256-$DIG"
echo "== T7 trust: tamper, wrong key, rollback, expiry"; fresh t7
cp "$OUT/v1.json" "$W/v1.good"; jq '.channel_version=999' "$W/v1.good" > "$OUT/v1.json"
t "tampered manifest -> E-SIG-INVALID" 12 "$X" pin 0.8.0
says "  exact text: bad-signature"   E-SIG-INVALID bad-signature url="$IDRIS2X_CHANNEL_URL" key="key id $(keyid "$W/key.pub")" version=0.8.0
assert "  a refused manifest wrote no lock and was not cached" test ! -e idris2x.lock -a ! -e "$IDRIS2X_CACHE/manifests/v1.json"
cp "$W/v1.good" "$OUT/v1.json"
IDRIS2X_PUBKEY_FILE="$W/other.pub" t "wrong pinned key -> E-SIG-INVALID" 12 "$X" pin 0.8.0
says "  exact text: wrong-key"       E-SIG-INVALID wrong-key url="$IDRIS2X_CHANNEL_URL" signer="key id $(keyid "$W/key.pub")" key="key id $(keyid "$W/other.pub")"
cp "$OUT/v1.json.sig" "$W/sig.good"; printf 'untrusted comment: proxy page\n<html>not base64</html>\n' > "$OUT/v1.json.sig"
t "garbage signature file -> E-SIG-INVALID" 12 "$X" pin 0.8.0
says "  exact text: malformed"       E-SIG-INVALID malformed what="the signature is not base64" file="$IDRIS2X_CACHE/manifests/v1.json.sig.tmp"
cp "$W/sig.good" "$OUT/v1.json.sig"
pin; jq '.channel.version=5' idris2x.lock > l.tmp && mv l.tmp idris2x.lock
t "channel rollback -> E-CHANNEL-ROLLBACK" 22 "$X" pin 0.8.0
says "  exact text: version-went-back" E-CHANNEL-ROLLBACK version-went-back url="$IDRIS2X_CHANNEL_URL" seen=5 offered="$(jq -r .channel_version "$W/v1.good")" version=0.8.0
rm idris2x.lock; jq '.expires="2020-01-01T00:00:00Z"' "$W/v1.good" > "$OUT/v1.json"; signify-openbsd -S -s "$W/key.sec" -m "$OUT/v1.json" -x "$OUT/v1.json.sig"
t "expired manifest -> E-CHANNEL-EXPIRED" 23 "$X" pin 0.8.0
MASK='s/(this-clock-says:? +).*/\1<now>/' says "  exact text: expired (clock value masked)" E-CHANNEL-EXPIRED expired url="$IDRIS2X_CHANNEL_URL" expires=2020-01-01T00:00:00Z now=x version=0.8.0
IDRIS2X_ALLOW_EXPIRED=1 t "expired + explicit override -> ok" 0 "$X" pin 0.8.0
cp "$W/v1.good" "$OUT/v1.json"; signify-openbsd -S -s "$W/key.sec" -m "$OUT/v1.json" -x "$OUT/v1.json.sig"
echo "== T8 offline"; fresh t8; pin
IDRIS2X_OFFLINE=1 t "offline cache miss -> E-OFFLINE" 20 "$X" install --locked
says "  exact text: capsule-missing" E-OFFLINE capsule-missing digest="sha256:$DIG" store="$IDRIS2X_CACHE/store" mode=IDRIS2X_OFFLINE=1 lock=idris2x.lock
echo "== T9 air-gap: fetch then install --from offline"; fresh t9; pin
t "fetch -o bundle"                  0 "$X" fetch -o "$W/bundle.tar.gz"
cp idris2x.lock "$W/lock.copy"; fresh t9b; cp "$W/lock.copy" idris2x.lock
IDRIS2X_OFFLINE=1 t "install --from bundle (offline)" 0 "$X" install --from "$W/bundle.tar.gz"
assert "bundle kept after --from"    test -f "$W/bundle.tar.gz"
fresh t9c; cp "$W/lock.copy" idris2x.lock
IDRIS2X_OFFLINE=1 t "install --from a damaged bundle -> E-HASH-MISMATCH" 11 "$X" install --from "$OUT/corrupt.tar.gz"
says "  exact text: bundle"          E-HASH-MISMATCH bundle lock=idris2x.lock want="sha256:$DIG" got="sha256:$BADSHA" bytes="$SIZE bytes (the lock says $SIZE)" source="$OUT/corrupt.tar.gz"
assert "  the user's bundle was left untouched, store absent" test -f "$OUT/corrupt.tar.gz" -a ! -e "$IDRIS2X_CACHE/store/sha256-$DIG"
echo "== T10 lock contention"; fresh t10; pin; mkdir -p "$IDRIS2X_CACHE/locks"
( exec 9>"$IDRIS2X_CACHE/locks/sha256-$DIG.lock"; flock 9; sleep 4 ) & HOLD=$!; sleep 0.3
IDRIS2X_LOCK_TIMEOUT=1 t "lock held -> E-LOCK-TIMEOUT" 15 "$X" install --locked
says "  exact text: held (no holder record: claims nothing it cannot see)" E-LOCK-TIMEOUT held digest="sha256:$DIG" seconds=1 lockfile="$IDRIS2X_CACHE/locks/sha256-$DIG.lock" holder="unknown (the holder left no record)"
echo $HOLD > "$IDRIS2X_CACHE/locks/sha256-$DIG.holder"
IDRIS2X_LOCK_TIMEOUT=1 t "lock held, holder recorded -> E-LOCK-TIMEOUT" 15 "$X" install --locked
says "  exact text: held (names the running holder)" E-LOCK-TIMEOUT held digest="sha256:$DIG" seconds=1 lockfile="$IDRIS2X_CACHE/locks/sha256-$DIG.lock" holder="process $HOLD (still running)"
wait "$HOLD"   # bare wait would also wait for the http server
echo "== T11 unsafe tar member"; fresh t11; pin
jq --arg s "$UNSAFE_SHA" --arg u "$U/unsafe.tar.gz" '.capsules[] |= (.sha256=$s | .urls=[$u] | .size=100)' idris2x.lock > l.tmp && mv l.tmp idris2x.lock
t "'../' member -> E-CAPSULE-INVALID" 21 "$X" install --locked
says "  exact text: unsafe-path"     E-CAPSULE-INVALID unsafe-path digest="sha256:$UNSAFE_SHA"
assert "nothing escaped the staging dir" test ! -e "$IDRIS2X_CACHE/staging/evil.txt" -a ! -e "$IDRIS2X_CACHE/evil.txt"
mkdir -p "$W/esc"; ln -sfn /etc "$W/esc/out"; echo x > "$W/esc/file"; tar -czf "$OUT/escape.tar.gz" -C "$W/esc" out file; ESC_SHA=$(sha256sum "$OUT/escape.tar.gz" | cut -d' ' -f1)
jq --arg s "$ESC_SHA" --arg u "$U/escape.tar.gz" '.capsules[] |= (.sha256=$s | .urls=[$u] | .size=100)' idris2x.lock > l.tmp && mv l.tmp idris2x.lock
t "symlink pointing outside the tree -> E-CAPSULE-INVALID" 21 "$X" install --locked
says "  exact text: unsafe-path (link escape)" E-CAPSULE-INVALID unsafe-path digest="sha256:$ESC_SHA"

echo "== T12 cache path with spaces + unsupported-target lock"; fresh "t12 with spaces"; pin
t "install into path with spaces"    0 "$X" install --locked
assert "chez runs from spaced path"  test "$(echo '(display (+ 40 2))' | "$X" run -- -q)" = 42
jq '.capsules |= with_entries(.key="riscv64-unknown-linux-gnu")' idris2x.lock > l.tmp && mv l.tmp idris2x.lock
t "lock lacks host target -> E-PIN-NOT-FOUND" 10 "$X" install --locked
says "  exact text: no-target"       E-PIN-NOT-FOUND no-target lock=idris2x.lock target="$HOST" covered=riscv64-unknown-linux-gnu version=0.8.0
jq --arg t "$HOST" '.capsules = {($t): {sha256: "../../../evil", size: 1, urls: ["http://127.0.0.1:1/x"]}}' idris2x.lock > l.tmp && mv l.tmp idris2x.lock
t "malformed digest in the lock -> refused before any download" 10 "$X" install --locked
says "  exact text: malformed-lock (digest)" E-PIN-NOT-FOUND malformed-lock lock=idris2x.lock target="$HOST" field=digest
assert "  nothing named by the bad digest was created" test ! -e "$IDRIS2X_CACHE/store/sha256-../../../evil" -a ! -e "$IDRIS2X_CACHE/evil"
jq '.toolchain.idris2 = "0.8.0; touch pwned"' idris2x.lock > l.tmp && mv l.tmp idris2x.lock
t "malformed version in the lock -> refused" 10 "$X" install --locked
says "  exact text: malformed-lock (version)" E-PIN-NOT-FOUND malformed-lock lock=idris2x.lock target="$HOST" field=version
echo "== T13 gc"; fresh t13; pin; "$X" install --locked >/dev/null 2>&1; mkdir -p "$IDRIS2X_CACHE/store/sha256-deadbeef"
t "gc removes incomplete dirs"       0 "$X" gc --keep-last 3
assert "incomplete dir gone, complete kept" test ! -e "$IDRIS2X_CACHE/store/sha256-deadbeef" -a -f "$IDRIS2X_CACHE/store/sha256-$DIG/.complete"
echo "== T13b store tampering, then the printed fix"; echo tampered >> "$IDRIS2X_CACHE/store/sha256-$DIG/capsule.json"
t "modified store entry -> E-HASH-MISMATCH" 11 "$X" verify
says "  exact text: store-modified"  E-HASH-MISMATCH store-modified digest="sha256:$DIG" dir="$IDRIS2X_CACHE/store/sha256-$DIG"
t "the printed fix command repairs it" 0 bash -c "$(IDRIS2X_JSON=1 "$X" verify 2>&1 | jq -r .fix.command | sed "s|idris2x |'$X' |")"
t "verify passes after the fix"      0 "$X" verify
HOSTILE="$W/h'; touch '$W/pwned'; echo '"; mkdir -p "$HOSTILE"
FIXCMD=$("$X" __render json E-HASH-MISMATCH store-modified digest="sha256:$DIG" dir="$HOSTILE" | jq -r .fix.command)
t "a fix command built from a hostile path runs as one rm, nothing more" 0 bash -c "${FIXCMD% && *}"
assert "  the path's embedded command did not run, and the directory is gone" test ! -e "$W/pwned" -a ! -e "$HOSTILE"
assert "  a path with a space is quoted in the fix command" test "$("$X" __render json E-HASH-MISMATCH store-modified digest=d dir="/a b/c" | jq -r .fix.command)" = "rm -rf '/a b/c' && idris2x install --locked"


if [ -n "$IDRIS2_PREFIX" ]; then echo "== T14 idris2 canaries (space-free cache)"; fresh t14; pin; "$X" install --locked >/dev/null 2>&1
  t "exec -- idris2 --version"       0 "$X" exec -- --version
  t "selftest (chez_codegen, relocatable_artifact, refc)" 0 "$X" selftest
  sed 's/^/        /' "$W/out.txt"
  echo "== T15 documented limitation: compiled programs vs spaces in the store path"; fresh "t15 with spaces"; pin; "$X" install --locked >/dev/null 2>&1
  t "exec works from spaced store"   0 "$X" exec -- --version
  t "selftest: compiled program breaks (shebang) -> E-PROBE-CODEGEN with fix hint" 17 "$X" selftest
  says "  exact text: path-has-spaces (names the cause and a fix)" E-PROBE-CODEGEN path-has-spaces probe="chez_codegen (run the compiled program)" store="$IDRIS2X_CACHE/store/sha256-$DIG"
fi
echo "== T16 usage, platform floor, schema"; fresh t16; pin
t "unknown command -> E-USAGE"       2 "$X" instal
says "  exact text: unknown-command" E-USAGE unknown-command word=instal commands="pin, install, exec, run, env, verify, gc, fetch, doctor, selftest, explain, help"
t "unknown flag -> E-USAGE"          2 "$X" install --lock
says "  exact text: unknown-flag"    E-USAGE unknown-flag command=install word=--lock usage="idris2x install [--locked] [--from <bundle>]"
t "missing bundle file -> E-USAGE"   2 "$X" install --from nope.tar.gz
says "  exact text: no-such-file"    E-USAGE no-such-file path=nope.tar.gz dir="$(pwd)"
t "explain an unknown id -> E-USAGE" 2 "$X" explain E-NOPE
says "  exact text: no-such-id"      E-USAGE no-such-id word=E-NOPE
t "help exits 0"                     0 "$X" help
t "verify before install -> E-PIN-NOT-FOUND" 10 "$X" verify
says "  exact text: not-installed"   E-PIN-NOT-FOUND not-installed digest="sha256:$DIG"
cp idris2x.lock lock.keep; jq '.capsules[].min_glibc = "9.99"' lock.keep > idris2x.lock
t "host glibc below the capsule's floor -> E-GLIBC-FLOOR" 16 "$X" install --locked
says "  exact text: too-old"         E-GLIBC-FLOOR too-old host="$(getconf GNU_LIBC_VERSION | cut -d' ' -f2)" needs=9.99 digest="sha256:$DIG"
assert "  refused before any download" test ! -e "$IDRIS2X_CACHE/store/sha256-$DIG" -a ! -e "$IDRIS2X_CACHE/staging/sha256-$DIG.part"
jq '.schema = 2' lock.keep > idris2x.lock
t "lock from a newer idris2x -> E-CHANNEL-SCHEMA" 18 "$X" install --locked
says "  exact text: lock-newer"      E-CHANNEL-SCHEMA lock-newer file=idris2x.lock found=2 supports=1 version=0.0.0-proto
cp lock.keep idris2x.lock
echo "== T17 advice: notes that are not errors, each with a way to silence it and a review date"
assert "advice review dates are all in the future" "$P/../check-advice-review.sh"
assert "the review gate fails once a date has passed" bash -c '! "$0" --today 2099-01-01' "$P/../check-advice-review.sh"
IDRIS2_PATH=/somewhere t "doctor with IDRIS2_PATH set"  0 "$X" doctor
assert "  doctor notes that the variable will be ignored" grep -qx "note: IDRIS2_PATH is set in your shell and idris2x will ignore it. Pass --inherit-env to keep it." "$W/out.txt"
assert "  the note says how to silence it" grep -qx "note: silence this note with IDRIS2X_ADVICE_ENV=0" "$W/out.txt"
IDRIS2_PATH=/somewhere IDRIS2X_ADVICE_ENV=0 t "doctor with that note silenced" 0 "$X" doctor
assert "  silenced note is absent"   test -z "$(grep '^note:' "$W/out.txt")"
mkdir -p "$W/fakebin"; printf '#!/bin/sh\necho "Idris2 LSP stand-in for Idris 2 0.7.0"\n' > "$W/fakebin/idris2-lsp"; chmod +x "$W/fakebin/idris2-lsp"
PATH="$W/fakebin:$PATH" t "doctor with a stand-in idris2-lsp for another version" 0 "$X" doctor
assert "  doctor notes the mismatch, the pin on its fact line (stand-in program, not a real idris2-lsp)" \
  sh -c 'grep -A1 "^note: idris2-lsp on PATH does not report the Idris 2 version this project pins" "$1" | tail -n 1 | grep -qx "    project-pins: 0.8.0"' _ "$W/out.txt"
PATH="$W/fakebin:$PATH" IDRIS2X_ADVICE=0 t "doctor with all advice off" 0 "$X" doctor
assert "  no notes at all"           test -z "$(grep '^note:' "$W/out.txt")"
echo; echo "== RESULT: $pass passed, $fail failed  (work: $W)"; [ "$fail" = 0 ]

