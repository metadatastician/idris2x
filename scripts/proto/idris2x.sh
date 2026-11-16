#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# idris2x.sh — Phase 0 prototype launcher: resolve → fetch → verify → atomic install → direct exec.
# Throwaway: proves the state machine, env composition and error taxonomy before the Go launcher.
# Deps: bash, curl, jq, sha256sum, tar, gzip, flock, openssl(3, Ed25519), coreutils.
set -euo pipefail
PROTO_VERSION="0.0.0-proto"
CACHE="${IDRIS2X_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/idris2x}"
LOCK="${IDRIS2X_LOCK:-idris2x.lock}"                 # prototype lock is JSON (Go launcher: TOML or JSON, see ADR)
CHANNEL_URL="${IDRIS2X_CHANNEL_URL:-}"
PUBKEY_FILE="${IDRIS2X_PUBKEY_FILE:-}"                # signify-format .pub (Go launcher: embedded)
OFFLINE="${IDRIS2X_OFFLINE:-0}"
LOCK_TIMEOUT="${IDRIS2X_LOCK_TIMEOUT:-600}"
RUNBOOK="${IDRIS2X_RUNBOOK:-https://github.com/metadatastician/idris2x/blob/main/runbooks}"
JSON_OUT="${IDRIS2X_JSON:-0}"

# ---------- error taxonomy: stable IDs, stable exit codes ----------
declare -A EXIT=( [E-USAGE]=2 [E-PIN-NOT-FOUND]=10 [E-HASH-MISMATCH]=11 [E-SIG-INVALID]=12
  [E-PLATFORM-UNSUPPORTED]=13 [E-NETWORK]=14 [E-LOCK-TIMEOUT]=15 [E-GLIBC-FLOOR]=16 [E-PROBE-CODEGEN]=17
  [E-CHANNEL-SCHEMA]=18 [E-PIN-DRIFT]=19 [E-OFFLINE]=20 [E-CAPSULE-INVALID]=21 [E-CHANNEL-ROLLBACK]=22
  [E-CHANNEL-EXPIRED]=23 [E-STORE-IO]=24 [E-INTERNAL]=70 )
die() { # die ID message [fix]
  local id=$1 msg=$2 fix=${3:-}
  if [ "$JSON_OUT" = 1 ]; then jq -cn --arg id "$id" --arg m "$msg" --arg f "$fix" --arg r "$RUNBOOK/$id.adoc" \
       '{error:$id,message:$m,fix:$f,runbook:$r}' >&2
  else { echo "idris2x: $id: $msg"; [ -n "$fix" ] && echo "  fix: $fix"; echo "  see: $RUNBOOK/$id.adoc"; } >&2; fi
  exit "${EXIT[$id]:-70}"
}
note() { [ "${IDRIS2X_QUIET:-0}" = 1 ] || echo "idris2x: $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die E-INTERNAL "missing tool: $1"; }
for t in curl jq sha256sum tar flock openssl; do need $t; done

# ---------- pure, local resolution ----------
target() {
  local os arch; os=$(uname -s); arch=$(uname -m)
  case "$arch" in x86_64|amd64) arch=x86_64;; aarch64|arm64) arch=aarch64;;
    *) die E-PLATFORM-UNSUPPORTED "unsupported CPU architecture: $arch";; esac
  case "$os" in Linux) echo "$arch-unknown-linux-gnu";; Darwin) echo "$arch-apple-darwin";;
    *) die E-PLATFORM-UNSUPPORTED "unsupported OS: $os";; esac
}
lock_get() { jq -r "$1" "$LOCK"; }
resolve() { # prints: digest size urls... for this host, from the lock only (no network)
  [ -f "$LOCK" ] || die E-PIN-NOT-FOUND "no $LOCK in $(pwd)" "idris2x pin <version>"
  [ "$(lock_get .schema)" = 1 ] || die E-CHANNEL-SCHEMA "lockfile schema $(lock_get .schema) not understood by this launcher" "update idris2x"
  local t; t=$(target)
  local d; d=$(lock_get ".capsules[\"$t\"].sha256 // empty")
  [ -n "$d" ] || die E-PIN-NOT-FOUND "lock pins no capsule for host target $t (lock covers: $(lock_get '.capsules|keys|join(", ")'))" "idris2x pin <version> on a supported target, or request the target"
  echo "$d $(lock_get ".capsules[\"$t\"].size")"; lock_get ".capsules[\"$t\"].urls[]"
}

# ---------- verification primitives ----------
verify_sig() { # verify_sig MESSAGE SIGFILE PUBFILE   (signify / minisign-legacy format, pure Ed25519 over bytes)
  local msg=$1 sig=$2 pub=$3 tmp; tmp=$(mktemp -d -t idris2x-sig.XXXXXX)   # failures below exit the process
  sed -n 2p "$pub" | base64 -d > "$tmp/pub.bin" 2>/dev/null || die E-SIG-INVALID "pinned public key is not base64"
  sed -n 2p "$sig" | base64 -d > "$tmp/sig.bin" 2>/dev/null || die E-SIG-INVALID "signature file is not base64"
  [ "$(head -c2 "$tmp/pub.bin")" = Ed ] && [ "$(head -c2 "$tmp/sig.bin")" = Ed ] \
    || die E-SIG-INVALID "unsupported signature algorithm (need Ed25519 'Ed'; minisign pre-hashed 'ED' is not accepted)"
  cmp -s <(tail -c +3 "$tmp/pub.bin" | head -c 8) <(tail -c +3 "$tmp/sig.bin" | head -c 8) \
    || die E-SIG-INVALID "signature was made by a different key than the pinned channel key" "investigate the mirror; do not override"
  { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; tail -c 32 "$tmp/pub.bin"; } > "$tmp/pub.der"
  tail -c 64 "$tmp/sig.bin" > "$tmp/sig.raw"
  openssl pkeyutl -verify -pubin -keyform DER -inkey "$tmp/pub.der" -rawin -in "$msg" -sigfile "$tmp/sig.raw" >/dev/null 2>&1 \
    || die E-SIG-INVALID "channel manifest signature does not verify" "investigate the mirror; do not override"
  rm -rf "$tmp"
}
fetch_to() { # fetch_to OUT URL...  -> 0 on success; resumes partial downloads
  local out=$1; shift; local u
  for u in "$@"; do
    if curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 -C - -o "$out" "$u" 2>>"$CACHE/staging/fetch.log" \
       || { rm -f "$out"; curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 -o "$out" "$u" 2>>"$CACHE/staging/fetch.log"; }; then return 0
    else note "fetch failed from $u (trying next mirror)"; fi
  done; return 1
}
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
inside_tree() { # inside_tree PATH -> 0 if normalising PATH never climbs above the archive root
  local part depth=0; local IFS=/
  for part in $1; do case "$part" in ''|.) ;; ..) depth=$((depth-1)); [ $depth -lt 0 ] && return 1;; *) depth=$((depth+1));; esac; done; return 0
}
safe_tar_list() { # reject absolute member paths, '..' components, and symlink/hardlink targets that escape the tree
  if tar -tzf "$1" | grep -E -q '(^/|(^|/)\.\.(/|$))'; then return 1; fi
  local type member target dir
  while IFS=$'\t' read -r type member target; do
    case "$target" in /*) return 1;; esac
    if [ "$type" = l ]; then dir=${member%/*}; [ "$dir" = "$member" ] && dir=.; inside_tree "$dir/$target" || return 1
    else inside_tree "$target" || return 1; fi      # hardlink targets are archive-root relative
  done < <(tar -tvzf "$1" | sed -n 's/^\([lh]\)[^ ]* .* [0-9][0-9]:[0-9][0-9] \(.*\) -> \(.*\)$/\1\t\2\t\3/p; s/^\(h\)[^ ]* .* [0-9][0-9]:[0-9][0-9] \(.*\) link to \(.*\)$/\1\t\2\t\3/p')
  return 0
}

# ---------- store state machine: download → verify → unpack to tmp → probe → rename → .complete ----------
store_dir() { echo "$CACHE/store/sha256-$1"; }
install_capsule() { # install_capsule DIGEST SIZE URL... ; prints store dir
  local digest=$1 size=$2; shift 2; local dir; dir=$(store_dir "$digest")
  [ -f "$dir/.complete" ] && { echo "$dir"; return 0; }
  mkdir -p "$CACHE/locks" "$CACHE/staging" "$CACHE/store" 2>/dev/null || die E-STORE-IO "cannot create store at $CACHE" "check permissions/disk; set IDRIS2X_CACHE"
  exec 9>"$CACHE/locks/sha256-$digest.lock"
  flock -w "$LOCK_TIMEOUT" 9 || die E-LOCK-TIMEOUT "another idris2x has held the lock for sha256:$digest for over ${LOCK_TIMEOUT}s" "wait; if no idris2x is running: rm $CACHE/locks/sha256-$digest.lock"
  [ -f "$dir/.complete" ] && { echo "$dir"; return 0; }      # finished by someone else while we waited
  local tarball="${IDRIS2X_FROM:-}"
  if [ -z "$tarball" ]; then
    [ "$OFFLINE" = 1 ] && die E-OFFLINE "capsule sha256:$digest is not in the store and IDRIS2X_OFFLINE=1" "idris2x fetch -o bundle.tar.gz (on a connected machine), then idris2x install --from bundle.tar.gz"
    [ $# -gt 0 ] || die E-PIN-NOT-FOUND "lock has no URLs for sha256:$digest" "idris2x pin <version>"
    tarball="$CACHE/staging/sha256-$digest.part"
    [ -f "$tarball" ] && [ "$(stat -c%s "$tarball")" -ge "$size" ] && rm -f "$tarball"
    fetch_to "$tarball" "$@" || { rm -f "$tarball"; die E-NETWORK "all $# mirror(s) failed for sha256:$digest" "retry; check proxy/network; details: $CACHE/staging/fetch.log"; }
  fi
  local got; got=$(sha_of "$tarball")
  [ "$got" = "$digest" ] || { [ -z "${IDRIS2X_FROM:-}" ] && rm -f "$tarball"; die E-HASH-MISMATCH "capsule bytes do not match the lock: got sha256:$got ($(stat -c%s "$tarball") bytes), expected sha256:$digest" "idris2x gc && idris2x install --locked ; if it repeats, a mirror is serving a bad file: see runbook"; }
  safe_tar_list "$tarball" || { rm -f "$tarball"; die E-CAPSULE-INVALID "capsule contains unsafe paths (absolute, '..', or escaping links); refusing to unpack" "report this capsule digest upstream"; }
  local stage; stage=$(mktemp -d "$CACHE/staging/stage.XXXXXX") || die E-STORE-IO "cannot create staging dir" "check disk space in $CACHE"
  tar -xzf "$tarball" -C "$stage" --no-same-owner 2>>"$CACHE/staging/fetch.log" || { rm -rf "$stage"; die E-STORE-IO "unpacking failed (disk full or corrupt gzip)" "check disk space in $CACHE; idris2x gc"; }
  [ -f "$stage/capsule.json" ] || { rm -rf "$stage"; die E-CAPSULE-INVALID "capsule has no capsule.json" "report this capsule digest upstream"; }
  (cd "$stage" && sha256sum --quiet -c sha256sums.txt >/dev/null 2>&1) || { rm -rf "$stage"; die E-CAPSULE-INVALID "unpacked tree does not match sha256sums.txt" "idris2x gc && idris2x install --locked"; }
  probe_capsule "$stage" || { rm -rf "$stage"; exit "${EXIT[E-PROBE-CODEGEN]}"; }
  rm -rf "$dir"                                     # a dir without .complete is garbage by definition
  mv -T "$stage" "$dir" || { rm -rf "$stage"; die E-STORE-IO "atomic rename into store failed" "check $CACHE"; }
  echo "sha256:$digest $(date -u +%FT%TZ)" > "$dir/.complete"
  sync -f "$dir" 2>/dev/null || true
  [ -z "${IDRIS2X_FROM:-}" ] && rm -f "$tarball"
  echo "$dir"
}
cap() { jq -r "$1" "$2/capsule.json"; }
compose_env() { # compose_env STOREDIR — the environment contract (ADR 0005): a RESET of every Idris2/Chez search path
  local root=$1 cv; cv=$(cap .chez "$root")
  if [ "${IDRIS2X_INHERIT_ENV:-0}" != 1 ]; then   # inherited values are code-search paths => code execution; drop them
    unset IDRIS2_PATH IDRIS2_PACKAGE_PATH IDRIS2_DATA IDRIS2_LIBS IDRIS2_CG IDRIS2_INC_CGS LD_LIBRARY_PATH DYLD_LIBRARY_PATH
  fi
  export IDRIS2X_CAPSULE="$root" IDRIS2_PREFIX="$root" CHEZ="$root/bin/scheme" SCHEMEHEAPDIRS="$root/lib/csv$cv/%m"
  export IDRIS2_INC_SRC="$root/bin/idris2_app"
  export LD_LIBRARY_PATH="$root/bin/idris2_app${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export DYLD_LIBRARY_PATH="$root/bin/idris2_app${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  export PATH="$root/bin:$PATH"
}
probe_capsule() { # embedded canaries 1 (pure_eval) and 12 (version_match); loud on failure
  local root=$1 out
  ( compose_env "$root"
    out=$(echo '(display (+ 40 2))' | "$root/bin/scheme" -q 2>&1) && [ "$out" = 42 ] \
      || { echo "idris2x: E-PROBE-CODEGEN: chez pure_eval failed on this host: ${out:-no output}" >&2; echo "  see: $RUNBOOK/E-PROBE-CODEGEN.adoc" >&2; exit 1; }
    iv=$(cap '.idris2 // empty' "$root")
    if [ -n "$iv" ]; then
      out=$("$root/bin/scheme" --program "$root/bin/idris2_app/idris2.so" --version 2>&1) \
        || { echo "idris2x: E-PROBE-CODEGEN: idris2 failed to start: $out" >&2; exit 1; }
      case "$out" in *"version $iv"*) ;; *) echo "idris2x: E-PROBE-CODEGEN: version_match failed: got '$out', capsule says $iv" >&2; exit 1;; esac
    fi )
}

# ---------- commands ----------
cmd_pin() { # pin VERSION: fetch + verify channel, write lock for all targets of that version
  local ver=${1:-}; [ -n "$ver" ] || die E-USAGE "usage: idris2x pin <idris2-version>"
  [ -n "$CHANNEL_URL" ] || die E-USAGE "set IDRIS2X_CHANNEL_URL (prototype)"; [ -f "$PUBKEY_FILE" ] || die E-USAGE "set IDRIS2X_PUBKEY_FILE (prototype)"
  mkdir -p "$CACHE/manifests" "$CACHE/staging"
  local m="$CACHE/manifests/v1.json"
  if [ "$OFFLINE" != 1 ]; then
    rm -f "$m.tmp" "$m.sig.tmp"    # never resume a MUTABLE document: a Range resume splices new bytes onto a stale partial (found by the chaos drills)
    fetch_to "$m.tmp" "$CHANNEL_URL" && fetch_to "$m.sig.tmp" "$CHANNEL_URL.sig" || die E-NETWORK "cannot fetch channel manifest $CHANNEL_URL" "retry; or IDRIS2X_OFFLINE=1 to use the cached manifest"
    verify_sig "$m.tmp" "$m.sig.tmp" "$PUBKEY_FILE"; mv -f "$m.tmp" "$m"; mv -f "$m.sig.tmp" "$m.sig"
  else [ -f "$m" ] || die E-OFFLINE "no cached channel manifest" "run once online"; verify_sig "$m" "$m.sig" "$PUBKEY_FILE"; fi
  [ "$(jq -r .schema "$m")" = 1 ] || die E-CHANNEL-SCHEMA "channel schema $(jq -r .schema "$m") is newer than this launcher" "update idris2x"
  local cv; cv=$(jq -r .channel_version "$m")
  if [ -f "$LOCK" ]; then local lv; lv=$(lock_get '.channel.version // 0'); [ "$cv" -ge "$lv" ] || die E-CHANNEL-ROLLBACK "channel_version went backwards: lock saw $lv, manifest says $cv" "refusing (rollback attack or stale mirror); investigate"; fi
  local exp; exp=$(jq -r '.expires // empty' "$m")
  if [ -n "$exp" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$exp" +%s)" ] && [ "${IDRIS2X_ALLOW_EXPIRED:-0}" != 1 ]; then
    die E-CHANNEL-EXPIRED "channel manifest expired at $exp (freeze protection)" "check for a newer manifest; IDRIS2X_ALLOW_EXPIRED=1 to proceed knowingly"; fi
  jq -e --arg k "idris2@$ver" '.bundles[$k]' "$m" >/dev/null || die E-PIN-NOT-FOUND "channel has no idris2@$ver (available: $(jq -r '.bundles|keys|join(", ")' "$m"))" "idris2x pin <one of the available versions>"
  jq --arg k "idris2@$ver" --arg v "$ver" --arg url "$CHANNEL_URL" --argjson cv "$cv" '
    {schema:1, toolchain:{idris2:$v, chez:(.compat[$k].chez)}, channel:{version:$cv, url:$url},
     capsules: (.bundles[$k] | with_entries(.value |= {sha256, size, urls, min_glibc}))}' "$m" > "$LOCK.tmp" && mv -f "$LOCK.tmp" "$LOCK"
  note "pinned idris2 $ver (channel v$cv) into $LOCK for: $(lock_get '.capsules|keys|join(", ")')"
}
cmd_install() { local from=; while [ $# -gt 0 ]; do case "$1" in --locked) ;; --from) from=$2; shift;; *) die E-USAGE "unknown flag $1";; esac; shift; done
  local res; res=$(resolve) || exit $?            # never die inside a subshell: the exit code would be lost
  read -r digest size <<< "${res%%$'\n'*}"; mapfile -t urls < <(tail -n +2 <<< "$res")
  [ -n "$from" ] && { [ -f "$from" ] || die E-USAGE "no such bundle: $from"; export IDRIS2X_FROM=$from; }
  install_capsule "$digest" "$size" "${urls[@]}"; }
cmd_exec() { [ "${1:-}" = -- ] && shift; local root; root=$(cmd_install --locked); compose_env "$root"
  [ -n "$(cap '.idris2 // empty' "$root")" ] || die E-PIN-NOT-FOUND "capsule has no idris2 (chez-only capsule)" "pin an idris2 capsule"
  exec "$root/bin/scheme" --program "$root/bin/idris2_app/idris2.so" "$@"; }
cmd_run()  { [ "${1:-}" = -- ] && shift; local root; root=$(cmd_install --locked); compose_env "$root"; exec "$root/bin/scheme" "$@"; }
cmd_env()  { local root; root=$(cmd_install --locked); compose_env "$root"
  if [ "${1:-}" = --json ]; then jq -n --arg c "$IDRIS2X_CAPSULE" --arg p "$IDRIS2_PREFIX" --arg z "$CHEZ" --arg h "$SCHEMEHEAPDIRS" --arg i "$IDRIS2_INC_SRC" --arg l "$LD_LIBRARY_PATH" --arg pa "$PATH" '{IDRIS2X_CAPSULE:$c,IDRIS2_PREFIX:$p,CHEZ:$z,SCHEMEHEAPDIRS:$h,IDRIS2_INC_SRC:$i,LD_LIBRARY_PATH:$l,PATH:$pa}'
  else for v in IDRIS2X_CAPSULE IDRIS2_PREFIX CHEZ SCHEMEHEAPDIRS IDRIS2_INC_SRC LD_LIBRARY_PATH PATH; do echo "export $v=\"${!v}\""; done; fi; }
cmd_verify() { local res; res=$(resolve) || exit $?; read -r digest _ <<< "${res%%$'\n'*}"; local dir; dir=$(store_dir "$digest")
  [ -f "$dir/.complete" ] || die E-PIN-NOT-FOUND "capsule sha256:$digest not installed" "idris2x install --locked"
  (cd "$dir" && sha256sum --quiet -c sha256sums.txt) || die E-HASH-MISMATCH "store tree for sha256:$digest has been modified" "idris2x gc --purge sha256:$digest && idris2x install --locked"
  probe_capsule "$dir" || exit "${EXIT[E-PROBE-CODEGEN]}"; note "OK sha256:$digest verified ($(cap .name "$dir"))"; }
cmd_gc() { local keep=3; [ "${1:-}" = --keep-last ] && keep=$2
  mkdir -p "$CACHE/store" "$CACHE/staging"; local d n=0
  for d in "$CACHE"/store/*/; do [ -d "$d" ] || continue; [ -f "$d/.complete" ] || { note "gc: removing incomplete $d"; rm -rf "$d"; }; done
  find "$CACHE/staging" -mindepth 1 -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
  mapfile -t dirs < <(ls -1dt "$CACHE"/store/*/ 2>/dev/null)
  for d in "${dirs[@]}"; do n=$((n+1)); if [ $n -gt "$keep" ]; then note "gc: removing old $d"; rm -rf "$d"; fi; done
  return 0; }   # a trailing false '&&' would otherwise become the function's status and trip set -e
cmd_fetch() { local out=; [ "${1:-}" = -o ] && out=$2; [ -n "$out" ] || die E-USAGE "usage: idris2x fetch -o bundle.tar.gz"
  local res; res=$(resolve) || exit $?; read -r digest size <<< "${res%%$'\n'*}"; mapfile -t urls < <(tail -n +2 <<< "$res"); mkdir -p "$CACHE/staging"
  fetch_to "$out.part" "${urls[@]}" || die E-NETWORK "all mirrors failed" "retry"
  [ "$(sha_of "$out.part")" = "$digest" ] || { rm -f "$out.part"; die E-HASH-MISMATCH "fetched bytes do not match lock" "retry"; }
  mv -f "$out.part" "$out"; note "fetched sha256:$digest -> $out ($size bytes); copy it with $LOCK to the air-gapped host"; }
cmd_doctor() { local t; t=$(target); echo "[info] idris2x $PROTO_VERSION  target=$t  glibc=$(ldd --version 2>/dev/null | head -1 | grep -o '[0-9.]*$' || echo n/a)  cache=$CACHE"
  mkdir -p "$CACHE/locks" 2>/dev/null && ( exec 9>"$CACHE/locks/.doctor"; flock -n 9 ) && echo "[OK] store writable, flock works" || echo "[FAIL] store not writable or flock broken -> E-STORE-IO"
  if [ -f "$LOCK" ]; then local res; res=$(resolve) || exit $?; read -r digest _ <<< "${res%%$'\n'*}"; local dir; dir=$(store_dir "$digest")
    [ -f "$dir/.complete" ] && echo "[OK] capsule sha256:${digest:0:12} installed ($(cap .name "$dir"))" || echo "[..] capsule sha256:${digest:0:12} not installed (idris2x install --locked)"
    for u in $(tail -n +2 <<< "$res"); do [ "$OFFLINE" = 1 ] && break; local ms; ms=$(curl -sS -o /dev/null -I --connect-timeout 5 -w '%{http_code} %{time_total}' "$u" 2>/dev/null || echo "000 -")
      case "$ms" in 2*|3*) echo "[OK] mirror reachable ${ms#* }s $u";; *) echo "[FAIL] mirror unreachable ($ms) $u -> E-NETWORK";; esac; done
    [ -f "$dir/.complete" ] && { probe_capsule "$dir" 2>/dev/null && echo "[OK] probes: pure_eval, version_match" || echo "[FAIL] probes failed -> E-PROBE-CODEGEN"; }
  else echo "[..] no $LOCK here (idris2x pin <version>)"; fi; }
cmd_selftest() { local root; root=$(cmd_install --locked); compose_env "$root"
  [ -n "$(cap '.idris2 // empty' "$root")" ] || die E-PIN-NOT-FOUND "selftest needs an idris2 capsule" ""
  local w; w=$(mktemp -d)
  # Expand $w now, not at exit: locals are gone when the EXIT trap fires.
  # shellcheck disable=SC2064
  trap "rm -rf '$w'" EXIT
  cd "$w"
  local hint="" fix=""
  case "$root" in *[[:space:]]*) hint=" (programs compiled with --cg chez embed '#!$root/bin/scheme --program' and the kernel splits shebang lines at spaces; the store path contains whitespace)"; fix="set IDRIS2X_CACHE to a path without spaces (the launcher itself works, compiled programs do not)";; esac
  printf 'module Main\nmain : IO ()\nmain = putStrLn "chez_codegen ok"\n' > Main.idr
  "$root/bin/scheme" --program "$root/bin/idris2_app/idris2.so" -o hello Main.idr >/dev/null 2>&1 || die E-PROBE-CODEGEN "chez_codegen: compile failed$hint" "$fix"
  [ "$(./build/exec/hello 2>/dev/null)" = "chez_codegen ok" ] || die E-PROBE-CODEGEN "chez_codegen: compiled program did not run$hint" "$fix"
  mkdir -p "$w/moved dir" && mv build/exec "$w/moved dir/exec" && [ "$(env -i PATH=/usr/bin:/bin "$w/moved dir/exec/hello" 2>/dev/null)" = "chez_codegen ok" ] \
    || die E-PROBE-CODEGEN "relocatable_artifact: compiled program failed after move/clean env$hint" "$fix"
  if command -v cc >/dev/null; then "$root/bin/scheme" --program "$root/bin/idris2_app/idris2.so" --cg refc -o hello_refc Main.idr >/dev/null 2>&1 && [ "$(./build/exec/hello_refc)" = "chez_codegen ok" ] && echo "[OK] refc_codegen" || echo "[FAIL] refc_codegen (cc present but RefC path broken)"; else echo "[skip] refc_codegen (no cc)"; fi
  echo "[OK] pure_eval version_match chez_codegen relocatable_artifact"; }

cmd=${1:-}; shift || true
case "$cmd" in
  pin) cmd_pin "$@";; install) cmd_install "$@";; exec) cmd_exec "$@";; run) cmd_run "$@";; env) cmd_env "$@";;
  verify) cmd_verify;; gc) cmd_gc "$@";; fetch) cmd_fetch "$@";; doctor) cmd_doctor;; selftest) cmd_selftest;;
  version|--version) echo "idris2x $PROTO_VERSION (prototype)";;
  *) die E-USAGE "usage: idris2x {pin V|install [--locked] [--from F]|exec -- ...|run -- ...|env [--json]|verify|gc [--keep-last N]|fetch -o F|doctor|selftest}";;
esac
