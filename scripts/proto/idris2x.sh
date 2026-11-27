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
NET_TIMEOUT="${IDRIS2X_NET_TIMEOUT:-30}"      # seconds a download may go without data, before its answer or mid-file
RUNBOOK="${IDRIS2X_RUNBOOK:-https://github.com/metadatastician/idris2x/blob/main/docs/runbooks}"
JSON_OUT="${IDRIS2X_JSON:-0}"

# ---------- error taxonomy: stable IDs, stable exit codes ----------
declare -A EXIT=( [E-USAGE]=2 [E-PIN-NOT-FOUND]=10 [E-HASH-MISMATCH]=11 [E-SIG-INVALID]=12
  [E-PLATFORM-UNSUPPORTED]=13 [E-NETWORK]=14 [E-LOCK-TIMEOUT]=15 [E-GLIBC-FLOOR]=16 [E-PROBE-CODEGEN]=17
  [E-CHANNEL-SCHEMA]=18 [E-PIN-DRIFT]=19 [E-OFFLINE]=20 [E-CAPSULE-INVALID]=21 [E-CHANNEL-ROLLBACK]=22
  [E-CHANNEL-EXPIRED]=23 [E-STORE-IO]=24 [E-INTERNAL]=70 )
die() { # die ID message [fix] — legacy wording, for the ids that have no [[case]] data yet
  local id=$1 msg=$2 fix=${3:-} j
  j=$(jq -cn --arg id "$id" --arg m "$msg" --arg f "$fix" --arg r "$RUNBOOK/$id.adoc" '{error:$id,message:$m,fix:$f,runbook:$r}')
  if [ "$JSON_OUT" = 1 ]; then echo "$j" >&2
  else { echo "idris2x: $id: $msg"; [ -n "$fix" ] && echo "  fix: $fix"; echo "  see: $RUNBOOK/$id.adoc"; } >&2; fi
  [ -z "${IDRIS2X_ERROR_FILE:-}" ] || echo "$j" > "$IDRIS2X_ERROR_FILE"
  exit "${EXIT[$id]:-70}"
}
# ---------- schema-2 messages: the call site passes an id, a case and context values; errors.toml holds every word ----------
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ERRORS_TOML="${IDRIS2X_ERRORS_TOML:-$HERE/../../src/errors/errors.toml}"
render() { # render FORM ID CASE key=value... -> the message on stdout (FORM: tty | plain | json)
  local form=$1 id=$2 case=$3 w=${COLUMNS:-80}; shift 3; [ "$w" -gt 80 ] && w=80; [ "$w" -lt 40 ] && w=40
  "$HERE/../lib/toml2json.sh" "$ERRORS_TOML" | jq -er -L "$HERE" -f "$HERE/render.jq" --arg id "$id" --arg case "$case" \
    --arg style "${IDRIS2X_STYLE:-b}" --arg form "$form" --arg width "$w" --arg runbook "$RUNBOOK" \
    --argjson ctx "$(jq -n '[$ARGS.positional[] | capture("^(?<key>[^=]+)=(?<value>.*)$"; "s")] | from_entries' --args "$@")"
}
form() { # --json wins; colour needs a terminal on stderr, and is off when NO_COLOR is non-empty or TERM=dumb (no-color.org, clig.dev)
  if [ "$JSON_OUT" = 1 ]; then echo json
  elif [ "${IDRIS2X_COLOR:-auto}" = always ]; then echo tty
  elif [ "${IDRIS2X_COLOR:-auto}" = never ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = dumb ] || [ ! -t 2 ]; then echo plain
  else echo tty; fi
}
fail() { # fail ID CASE key=value... — print the message, leave the machine-readable marker, exit with the id's stable code
  local id=$1 out; out=$(render "$(form)" "$@") || die E-INTERNAL "no message data for $1/$2 in $ERRORS_TOML" "file an issue: this is a launcher bug"
  printf '%s\n' "$out" >&2
  [ -z "${IDRIS2X_ERROR_FILE:-}" ] || render json "$@" > "$IDRIS2X_ERROR_FILE"   # lets CI tell a launcher failure from the child's own exit code
  exit "${EXIT[$id]:-70}"
}
hexid() { od -An -tx1 | tr -d ' \n'; }     # 8-byte signify key id as hex
note() { [ "${IDRIS2X_QUIET:-0}" = 1 ] || printf "idris2x: %s\n" "$(printf %s "$*" | jq -Rrsj -L "$HERE" 'include "clean"; clean')" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || fail E-INTERNAL missing-tool tool="$1"; }
for t in curl jq sha256sum tar flock openssl; do need $t; done

# ---------- pure, local resolution ----------
target() {
  local os arch; os=$(uname -s); arch=$(uname -m)
  case "$arch" in x86_64|amd64) arch=x86_64;; aarch64|arm64) arch=aarch64;;
    *) fail E-PLATFORM-UNSUPPORTED unknown-arch arch="$arch" supported="x86_64, aarch64";; esac
  case "$os" in Linux) echo "$arch-unknown-linux-gnu";; Darwin) echo "$arch-apple-darwin";;
    *) fail E-PLATFORM-UNSUPPORTED unknown-os os="$os" supported="Linux, macOS";; esac
}
lock_get() { jq -r "$1" "$LOCK"; }
resolve() { # prints: digest size urls... for this host, from the lock only (no network)
  [ -f "$LOCK" ] || fail E-PIN-NOT-FOUND no-lock lock="$LOCK" dir="$(pwd)"
  [ "$(lock_get .schema)" = 1 ] || fail E-CHANNEL-SCHEMA lock-newer file="$LOCK" found="$(lock_get .schema)" supports=1 version="$PROTO_VERSION"
  local t; t=$(target)
  # Lock values reach downloads, store paths and printed fix commands, so they are format-checked here, once (ADR 0012:
  # a checked value carries the Checked provenance; raw lock text never reaches a fix command).
  local v; v=$(lock_get '.toolchain.idris2 // empty')
  [[ "$v" =~ ^[0-9]{1,19}(\.[0-9]{1,19}){1,3}$ ]] || fail E-PIN-NOT-FOUND malformed-lock lock="$LOCK" target="$t" field=version
  local d; d=$(lock_get ".capsules[\"$t\"].sha256 // empty")
  [ -n "$d" ] || fail E-PIN-NOT-FOUND no-target lock="$LOCK" target="$t" covered="$(lock_get '.capsules|keys|join(", ")')" version="$v"
  [[ "$d" =~ ^[0-9a-f]{64}$ ]] || fail E-PIN-NOT-FOUND malformed-lock lock="$LOCK" target="$t" field=digest
  local needs host; needs=$(lock_get ".capsules[\"$t\"].min_glibc | if . == null then \"\" elif type == \"string\" then . else \"!\" end")
  host=$(getconf GNU_LIBC_VERSION 2>/dev/null | cut -d' ' -f2)
  # ADR 0006: refuse before downloading. The floor has the version's form and limits; on Linux it is checked, never skipped.
  if [ -n "$needs" ]; then
    [[ "$needs" =~ ^[0-9]{1,19}(\.[0-9]{1,19}){1,3}$ ]] || fail E-PIN-NOT-FOUND malformed-lock lock="$LOCK" target="$t" field="glibc floor"
    if [ "$(uname -s)" = Linux ] && ! [[ "$host" =~ ^[0-9]{1,19}(\.[0-9]{1,19})*$ ]]; then
      fail E-GLIBC-FLOOR unknown needs="$needs" digest="sha256:$d"; fi
    if [ -n "$host" ] && [ "$(printf '%s\n%s\n' "$needs" "$host" | sort -V | head -1)" != "$needs" ]; then
      fail E-GLIBC-FLOOR too-old host="$host" needs="$needs" digest="sha256:$d"; fi
  fi
  echo "$d $(lock_get ".capsules[\"$t\"].size")"; lock_get ".capsules[\"$t\"].urls[]"
}

# ---------- verification primitives ----------
verify_sig() { # verify_sig MESSAGE SIGFILE PUBFILE   (signify / minisign-legacy format, pure Ed25519 over bytes)
  local msg=$1 sig=$2 pub=$3 tmp; tmp=$(mktemp -d -t idris2x-sig.XXXXXX)   # failures below exit the process
  sed -n 2p "$pub" | base64 -d > "$tmp/pub.bin" 2>/dev/null || fail E-SIG-INVALID malformed what="the trusted public key is not base64" file="$pub"
  sed -n 2p "$sig" | base64 -d > "$tmp/sig.bin" 2>/dev/null || fail E-SIG-INVALID malformed what="the signature is not base64" file="$sig"
  [ "$(head -c2 "$tmp/pub.bin")" = Ed ] || fail E-SIG-INVALID malformed what="the trusted public key is not an Ed25519 (Ed) key" file="$pub"
  [ "$(head -c2 "$tmp/sig.bin")" = Ed ] || fail E-SIG-INVALID malformed what="the signature is not plain Ed25519 (Ed); pre-hashed minisign (ED) signatures are not accepted" file="$sig"
  local kid sid; kid=$(tail -c +3 "$tmp/pub.bin" | head -c 8 | hexid); sid=$(tail -c +3 "$tmp/sig.bin" | head -c 8 | hexid)
  [ "$kid" = "$sid" ] || fail E-SIG-INVALID wrong-key url="${SIG_URL:-$msg}" signer="key id $sid" key="key id $kid"
  { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; tail -c 32 "$tmp/pub.bin"; } > "$tmp/pub.der"
  tail -c 64 "$tmp/sig.bin" > "$tmp/sig.raw"
  openssl pkeyutl -verify -pubin -keyform DER -inkey "$tmp/pub.der" -rawin -in "$msg" -sigfile "$tmp/sig.raw" >/dev/null 2>&1 \
    || fail E-SIG-INVALID bad-signature url="${SIG_URL:-$msg}" key="key id $kid" version="${PIN_VER:-<version>}"
  rm -rf "$tmp"
}
fetch_to() { # fetch_to OUT URL...  -> 0 on success; resumes partial downloads; TRIED records why each address failed
  local out=$1 u err rc; shift; TRIED=; FETCH_WRITE_ERR=
  for u in "$@"; do
    err=$(curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --speed-limit 1 --speed-time "$NET_TIMEOUT" -C - -o "$out" "$u" 2>&1) && { LAST_URL=$u; return 0; }; rc=$?
    if [ "$rc" != 23 ] && [ "$rc" != 153 ]; then rm -f "$out"; err=$(curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --speed-limit 1 --speed-time "$NET_TIMEOUT" -o "$out" "$u" 2>&1) && { LAST_URL=$u; return 0; }; rc=$?; fi
    rm -f "$out"   # the next mirror starts clean: bytes from one that failed are never resumed from another
    echo "$u: $err" >> "$CACHE/staging/fetch.log"; err=${err##*$'\n'}; err=${err#curl: }; TRIED="${TRIED:+$TRIED; }$u: ${err:-curl exit $rc}"
    [ "$rc" = 153 ] && err="the file size limit was reached"   # 128 + SIGXFSZ
    if [ "$rc" = 23 ] || [ "$rc" = 153 ]; then FETCH_WRITE_ERR=$err; return 1; fi     # could not write: the disk, not the network
    note "fetch failed from $u (trying next mirror)"
  done; return 1
}
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
inside_tree() { # inside_tree PATH -> 0 if normalising PATH never climbs above the archive root
  local part depth=0; local IFS=/
  for part in $1; do case "$part" in ''|.) ;; ..) depth=$((depth-1)); [ $depth -lt 0 ] && return 1;; *) depth=$((depth+1));; esac; done; return 0
}
safe_tar_list() { # reject absolute member paths, '..' components, and symlink/hardlink targets that escape the tree
  if tar -tzf "$1" 2>/dev/null | grep -E -q '(^/|(^|/)\.\.(/|$))'; then return 1; fi    # tar's own warnings are not our message
  local type member target dir
  while IFS=$'\t' read -r type member target; do
    case "$target" in /*) return 1;; esac
    if [ "$type" = l ]; then dir=${member%/*}; [ "$dir" = "$member" ] && dir=.; inside_tree "$dir/$target" || return 1
    else inside_tree "$target" || return 1; fi      # hardlink targets are archive-root relative
  done < <(tar -tvzf "$1" 2>/dev/null | sed -n  's/^\([lh]\)[^ ]* .* [0-9][0-9]:[0-9][0-9] \(.*\) -> \(.*\)$/\1\t\2\t\3/p; s/^\(h\)[^ ]* .* [0-9][0-9]:[0-9][0-9] \(.*\) link to \(.*\)$/\1\t\2\t\3/p')
  return 0
}

# ---------- store state machine: download → verify → unpack to tmp → probe → rename → .complete ----------
store_dir() { echo "$CACHE/store/sha256-$1"; }
install_capsule() { # install_capsule DIGEST SIZE URL... ; prints store dir
  local digest=$1 size=$2; shift 2; local dir; dir=$(store_dir "$digest")
  [ -f "$dir/.complete" ] && { echo "$dir"; return 0; }
  mkdir -p "$CACHE/locks" "$CACHE/staging" "$CACHE/store" 2>/dev/null || fail E-STORE-IO cannot-create path="$CACHE"
  exec 9>"$CACHE/locks/sha256-$digest.lock"
  local holder="$CACHE/locks/sha256-$digest.holder" hp who="unknown (the holder left no record)"
  if ! flock -w "$LOCK_TIMEOUT" 9; then     # only claim a holder we can see running; never advise deleting a held lock
    hp=$(cat "$holder" 2>/dev/null || true); [ -n "$hp" ] && kill -0 "$hp" 2>/dev/null && who="process $hp (still running)"
    fail E-LOCK-TIMEOUT held digest="sha256:$digest" seconds="$LOCK_TIMEOUT" lockfile="$CACHE/locks/sha256-$digest.lock" holder="$who"
  fi
  echo $$ > "$holder"
  [ -f "$dir/.complete" ] && { echo "$dir"; return 0; }      # finished by someone else while we waited
  local tarball="${IDRIS2X_FROM:-}"
  if [ -z "$tarball" ]; then
    [ "$OFFLINE" = 1 ] && fail E-OFFLINE capsule-missing digest="sha256:$digest" store="$CACHE/store" mode="IDRIS2X_OFFLINE=1" lock="$LOCK"
    [ $# -gt 0 ] || fail E-PIN-NOT-FOUND no-urls lock="$LOCK" digest="sha256:$digest" version="$(lock_get .toolchain.idris2)"
    tarball="$CACHE/staging/sha256-$digest.part"
    [ -f "$tarball" ] && [ "$(stat -c%s "$tarball")" -ge "$size" ] && rm -f "$tarball"
    if ! fetch_to "$tarball" "$@"; then rm -f "$tarball"
      [ -n "$FETCH_WRITE_ERR" ] && fail E-STORE-IO write-failed detail="downloading the capsule ($FETCH_WRITE_ERR)" path="$CACHE"
      fail E-NETWORK all-mirrors-failed digest="sha256:$digest" tried="$TRIED" log="$CACHE/staging/fetch.log"; fi
  fi
  local got; got=$(sha_of "$tarball")
  if [ "$got" != "$digest" ]; then local n; n="$(stat -c%s "$tarball") bytes (the lock says $size)"
    [ -n "${IDRIS2X_FROM:-}" ] && fail E-HASH-MISMATCH bundle lock="$LOCK" want="sha256:$digest" got="sha256:$got" bytes="$n" source="$tarball"
    rm -f "$tarball"; fail E-HASH-MISMATCH download lock="$LOCK" want="sha256:$digest" got="sha256:$got" bytes="$n" source="${LAST_URL:-unknown}"
  fi
  safe_tar_list "$tarball" || { [ -n "${IDRIS2X_FROM:-}" ] || rm -f "$tarball"; fail E-CAPSULE-INVALID unsafe-path digest="sha256:$digest"; }
  local stage; stage=$(mktemp -d "$CACHE/staging/stage.XXXXXX") || fail E-STORE-IO cannot-create path="$CACHE/staging"
  tar -xzf "$tarball" -C "$stage" --no-same-owner 2>>"$CACHE/staging/fetch.log" || { rm -rf "$stage"; fail E-STORE-IO write-failed detail="unpacking the capsule" path="$CACHE"; }
  [ -f "$stage/capsule.json" ] || { rm -rf "$stage"; fail E-CAPSULE-INVALID no-metadata digest="sha256:$digest"; }
  (cd "$stage" && grep -Eq '^[0-9a-f]{64}  (\./)?capsule\.json$' sha256sums.txt && sha256sum --quiet -c sha256sums.txt >/dev/null 2>&1) || { rm -rf "$stage"; fail E-CAPSULE-INVALID tree-mismatch digest="sha256:$digest"; }
  local iv; iv=$(cap '.idris2 // ""' "$stage")        # no other Idris 2 than the pinned one; a Chez-only capsule holds none
  [ -z "$iv" ] || [ "$iv" = "$(lock_get .toolchain.idris2)" ] || { rm -rf "$stage"
    fail E-CAPSULE-INVALID pin-mismatch digest="sha256:$digest" version="$(lock_get .toolchain.idris2)" found="$iv"; }
  probe_capsule "$stage" || { rm -rf "$stage"; exit "${EXIT[E-PROBE-CODEGEN]}"; }
  rm -rf "$dir"                                     # a dir without .complete is garbage by definition
  mv -T "$stage" "$dir" || { rm -rf "$stage"; fail E-STORE-IO rename-failed path="$dir"; }
  echo "sha256:$digest $(date -u +%FT%TZ)" > "$dir/.complete"
  sync -f "$dir" 2>/dev/null || true
  [ -z "${IDRIS2X_FROM:-}" ] && rm -f "$tarball"
  rm -f "$holder"
  echo "$dir"
}
cap() { jq -r "$1" "$2/capsule.json"; }
compose_env() { # compose_env STOREDIR — the environment contract (ADR 0005): a RESET of every Idris2/Chez search path
  local root=$1 cv; cv=$(cap .chez "$root")
  if [ "${IDRIS2X_INHERIT_ENV:-0}" != 1 ]; then   # inherited values are code-search paths => code execution; drop them
    unset IDRIS2_PATH IDRIS2_PACKAGE_PATH IDRIS2_DATA IDRIS2_LIBS IDRIS2_CG IDRIS2_INC_CGS LD_LIBRARY_PATH DYLD_LIBRARY_PATH \
      LD_PRELOAD LD_AUDIT
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
      || fail E-PROBE-CODEGEN chez-failed probe=pure_eval output="${out//$'\n'/ }"
    iv=$(cap '.idris2 // empty' "$root")
    if [ -n "$iv" ]; then
      out=$("$root/bin/scheme" --program "$root/bin/idris2_app/idris2.so" --version 2>&1) \
        || fail E-PROBE-CODEGEN idris2-failed probe=version_match output="${out//$'\n'/ }"
      case "$out" in *"version $iv"*) ;; *) fail E-PROBE-CODEGEN version-mismatch want="$iv" got="${out//$'\n'/ }";; esac
    fi )
}

# ---------- commands ----------
cmd_pin() { # pin VERSION: fetch + verify channel, write lock for all targets of that version
  local ver=${1:-}; [ -n "$ver" ] || fail E-USAGE missing-argument command=pin what="a version to pin" usage="idris2x pin <version>"
  [ -n "$CHANNEL_URL" ] || fail E-USAGE prototype-setting variable=IDRIS2X_CHANNEL_URL what="the address of the channel manifest"
  [ -f "$PUBKEY_FILE" ] || fail E-USAGE prototype-setting variable=IDRIS2X_PUBKEY_FILE what="the path of the trusted signify public key"
  mkdir -p "$CACHE/manifests" "$CACHE/staging"
  local m="$CACHE/manifests/v1.json"; SIG_URL=$CHANNEL_URL; PIN_VER=$ver
  if [ "$OFFLINE" != 1 ]; then
    rm -f "$m.tmp" "$m.sig.tmp"    # never resume a MUTABLE document: a Range resume splices new bytes onto a stale partial (found by the chaos drills)
    fetch_to "$m.tmp" "$CHANNEL_URL" && fetch_to "$m.sig.tmp" "$CHANNEL_URL.sig" || fail E-NETWORK manifest-unreachable url="$CHANNEL_URL" tried="$TRIED" log="$CACHE/staging/fetch.log" version="$ver"
    verify_sig "$m.tmp" "$m.sig.tmp" "$PUBKEY_FILE"; mv -f "$m.tmp" "$m"; mv -f "$m.sig.tmp" "$m.sig"
  else [ -f "$m" ] || fail E-OFFLINE no-manifest cache="$m" mode="IDRIS2X_OFFLINE=1" version="$ver"; verify_sig "$m" "$m.sig" "$PUBKEY_FILE"; fi
  [ "$(jq -r .schema "$m")" = 1 ] || fail E-CHANNEL-SCHEMA channel-newer url="$CHANNEL_URL" found="$(jq -r .schema "$m")" supports=1 version="$PROTO_VERSION"
  local cv; cv=$(jq -r .channel_version "$m")
  if [ -f "$LOCK" ]; then local lv; lv=$(lock_get '.channel.version // 0'); [ "$cv" -ge "$lv" ] || fail E-CHANNEL-ROLLBACK version-went-back url="$CHANNEL_URL" seen="$lv" offered="$cv" version="$ver"; fi
  local exp; exp=$(jq -r '.expires // empty' "$m")
  if [ -n "$exp" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$exp" +%s)" ] && [ "${IDRIS2X_ALLOW_EXPIRED:-0}" != 1 ]; then
    fail E-CHANNEL-EXPIRED expired url="$CHANNEL_URL" expires="$exp" now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" version="$ver"; fi
  jq -e --arg k "idris2@$ver" '.bundles[$k]' "$m" >/dev/null || fail E-PIN-NOT-FOUND no-version lock="$LOCK" version="$ver" available="$(jq -r '.bundles|keys|map(ltrimstr("idris2@"))|join(", ")' "$m")"
  # The temporary file is new (mktemp, O_EXCL): a file or link a project commits at a fixed name is never followed.
  local tmp; tmp=$(mktemp "$LOCK.XXXXXX" 2>/dev/null) || fail E-STORE-IO write-failed detail="writing the lock" path="$LOCK"
  jq --arg k "idris2@$ver" --arg v "$ver" --arg url "$CHANNEL_URL" --argjson cv "$cv" '
    {schema:1, toolchain:{idris2:$v, chez:(.compat[$k].chez)}, channel:{version:$cv, url:$url},
     capsules: (.bundles[$k] | with_entries(.value |= {sha256, size, urls, min_glibc}))}' "$m" > "$tmp" &&
    chmod "$(printf %o $((0666 & ~0$(umask))))" "$tmp" && mv -f "$tmp" "$LOCK" ||
    { rm -f "$tmp"; fail E-STORE-IO write-failed detail="writing the lock" path="$LOCK"; }
  note "pinned idris2 $ver (channel v$cv) into $LOCK for: $(lock_get '.capsules|keys|join(", ")')"
}
cmd_install() { local from=; while [ $# -gt 0 ]; do case "$1" in --locked) ;; --from) from=${2:-}; shift || true;; *) fail E-USAGE unknown-flag command=install word="$1" usage="idris2x install [--locked] [--from <bundle>]";; esac; shift || true; done
  local res; res=$(resolve) || exit $?            # never die inside a subshell: the exit code would be lost
  read -r digest size <<< "${res%%$'\n'*}"; mapfile -t urls < <(tail -n +2 <<< "$res")
  [ -n "$from" ] && { [ -f "$from" ] || fail E-USAGE no-such-file path="$from" dir="$(pwd)"; export IDRIS2X_FROM=$from; }
  install_capsule "$digest" "$size" "${urls[@]}"; }
cmd_exec() { [ "${1:-}" = -- ] && shift; local root; root=$(cmd_install --locked); compose_env "$root"
  [ -n "$(cap '.idris2 // empty' "$root")" ] || fail E-PIN-NOT-FOUND no-idris2 name="$(cap .name "$root")"
  exec "$root/bin/scheme" --program "$root/bin/idris2_app/idris2.so" "$@"; }
cmd_run()  { [ "${1:-}" = -- ] && shift; local root; root=$(cmd_install --locked); compose_env "$root"; exec "$root/bin/scheme" "$@"; }
cmd_env()  { local root; root=$(cmd_install --locked); compose_env "$root"
  if [ "${1:-}" = --json ]; then jq -n --arg c "$IDRIS2X_CAPSULE" --arg p "$IDRIS2_PREFIX" --arg z "$CHEZ" --arg h "$SCHEMEHEAPDIRS" --arg i "$IDRIS2_INC_SRC" --arg l "$LD_LIBRARY_PATH" --arg pa "$PATH" '{IDRIS2X_CAPSULE:$c,IDRIS2_PREFIX:$p,CHEZ:$z,SCHEMEHEAPDIRS:$h,IDRIS2_INC_SRC:$i,LD_LIBRARY_PATH:$l,PATH:$pa}'
  else for v in IDRIS2X_CAPSULE IDRIS2_PREFIX CHEZ SCHEMEHEAPDIRS IDRIS2_INC_SRC LD_LIBRARY_PATH PATH; do echo "export $v=\"${!v}\""; done; fi; }
cmd_verify() { local res; res=$(resolve) || exit $?; read -r digest _ <<< "${res%%$'\n'*}"; local dir; dir=$(store_dir "$digest")
  [ -f "$dir/.complete" ] || fail E-PIN-NOT-FOUND not-installed digest="sha256:$digest"
  (cd "$dir" && grep -Eq '^[0-9a-f]{64}  (\./)?capsule\.json$' sha256sums.txt && sha256sum --quiet -c sha256sums.txt >/dev/null 2>&1) || fail E-HASH-MISMATCH store-modified digest="sha256:$digest" dir="$dir"
  probe_capsule "$dir" || exit "${EXIT[E-PROBE-CODEGEN]}"; note "OK sha256:$digest verified ($(cap .name "$dir"))"; }
cmd_gc() { local keep=3; [ "${1:-}" = --keep-last ] && keep=$2
  mkdir -p "$CACHE/store" "$CACHE/staging"; local d n=0
  for d in "$CACHE"/store/*/; do [ -d "$d" ] || continue; [ -f "$d/.complete" ] || { note "gc: removing incomplete $d"; rm -rf "$d"; }; done
  find "$CACHE/staging" -mindepth 1 -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
  mapfile -t dirs < <(ls -1dt "$CACHE"/store/*/ 2>/dev/null)
  for d in "${dirs[@]}"; do n=$((n+1)); if [ $n -gt "$keep" ]; then note "gc: removing old $d"; rm -rf "$d"; fi; done
  return 0; }   # a trailing false '&&' would otherwise become the function's status and trip set -e
cmd_fetch() { local out=; [ "${1:-}" = -o ] && out=${2:-}; [ -n "$out" ] || fail E-USAGE missing-argument command=fetch what="a file to write, after -o" usage="idris2x fetch -o <bundle>"
  local res; res=$(resolve) || exit $?; read -r digest size <<< "${res%%$'\n'*}"; mapfile -t urls < <(tail -n +2 <<< "$res"); mkdir -p "$CACHE/staging"
  if ! fetch_to "$out.part" "${urls[@]}"; then rm -f "$out.part"
    [ -n "$FETCH_WRITE_ERR" ] && fail E-STORE-IO write-failed detail="writing the bundle ($FETCH_WRITE_ERR)" path="$(dirname "$out")"
    fail E-NETWORK all-mirrors-failed digest="sha256:$digest" tried="$TRIED" log="$CACHE/staging/fetch.log"; fi
  local got; got=$(sha_of "$out.part")
  [ "$got" = "$digest" ] || { local n; n="$(stat -c%s "$out.part") bytes (the lock says $size)"; rm -f "$out.part"; fail E-HASH-MISMATCH download lock="$LOCK" want="sha256:$digest" got="sha256:$got" bytes="$n" source="${LAST_URL:-unknown}"; }
  mv -f "$out.part" "$out"; note "fetched sha256:$digest -> $out ($size bytes); copy it with $LOCK to the air-gapped host"; }
cmd_doctor() { local t; t=$(target); echo "[info] idris2x $PROTO_VERSION  target=$t  glibc=$(ldd --version 2>/dev/null | head -1 | grep -o '[0-9.]*$' || echo n/a)  cache=$CACHE"
  mkdir -p "$CACHE/locks" 2>/dev/null && ( exec 9>"$CACHE/locks/.doctor"; flock -n 9 ) && echo "[OK] store writable, flock works" || echo "[FAIL] store not writable or flock broken -> E-STORE-IO"
  if [ -f "$LOCK" ]; then local res; res=$(resolve) || exit $?; read -r digest _ <<< "${res%%$'\n'*}"; local dir; dir=$(store_dir "$digest")
    [ -f "$dir/.complete" ] && echo "[OK] capsule sha256:${digest:0:12} installed ($(cap .name "$dir"))" || echo "[..] capsule sha256:${digest:0:12} not installed (idris2x install --locked)"
    for u in $(tail -n +2 <<< "$res"); do [ "$OFFLINE" = 1 ] && break; local ms; ms=$(curl -sS -o /dev/null -I --connect-timeout 5 -w '%{http_code} %{time_total}' "$u" 2>/dev/null || echo "000 -")
      case "$ms" in 2*|3*) echo "[OK] mirror reachable ${ms#* }s $u";; *) echo "[FAIL] mirror unreachable ($ms) $u -> E-NETWORK";; esac; done
    [ -f "$dir/.complete" ] && { probe_capsule "$dir" 2>/dev/null && echo "[OK] probes: pure_eval, version_match" || echo "[FAIL] probes failed -> E-PROBE-CODEGEN"; }
  else echo "[..] no $LOCK here (idris2x pin <version>)"; fi
  local v names=; for v in IDRIS2_PREFIX IDRIS2_PATH IDRIS2_PACKAGE_PATH IDRIS2_DATA IDRIS2_LIBS IDRIS2_CG IDRIS2_INC_CGS; do [ -n "${!v:-}" ] && names="${names:+$names, }$v"; done
  [ -n "$names" ] && [ "${IDRIS2X_INHERIT_ENV:-0}" != 1 ] && advice env-ignored names="$names"
  if [ -f "$LOCK" ] && command -v idris2-lsp >/dev/null 2>&1; then local pv; pv=$(lock_get .toolchain.idris2)
    case "$(idris2-lsp --version 2>&1 || true)" in *"$pv"*) ;; *) advice lsp-mismatch pinned="$pv";; esac; fi
  return 0; }
advice() { # advice ID key=value... — a note that is not an error; text, silencing variable and review date live in errors.toml
  local id=$1 j; shift; [ "${IDRIS2X_ADVICE:-1}" = 0 ] && return 0
  j=$("$HERE/../lib/toml2json.sh" "$ERRORS_TOML" | jq -c --arg id "$id" '.advice[] | select(.id == $id)'); [ -n "$j" ] || fail E-INTERNAL bug detail="no advice called $id" version="$PROTO_VERSION"
  local var; var=$(jq -r .silence <<< "$j"); [ "${!var:-1}" = 0 ] && return 0
  jq -r -L "$HERE" --argjson ctx "$(jq -n '[$ARGS.positional[] | capture("^(?<key>[^=]+)=(?<value>.*)$"; "s")] | from_entries' --args "$@")" \
    'include "clean"; ($ctx | map_values(clean)) as $ctx | "note: " + (.text | gsub("\\{(?<k>[a-z_]+)\\}"; .k as $k | $ctx[$k] // "{" + $k + "}")),
     ((.facts // "") | split(" ")[] | select(. != "") | split("=") | "    " + .[0] + ": " + ($ctx[.[1]] // error("advice fact has no value: " + .[1]))),
     "note: silence this note with " + .silence + "=0"' <<< "$j"; }
cmd_selftest() { local root; root=$(cmd_install --locked); compose_env "$root"
  [ -n "$(cap '.idris2 // empty' "$root")" ] || fail E-PIN-NOT-FOUND no-idris2 name="$(cap .name "$root")"
  local w; w=$(mktemp -d)
  # Expand $w now, not at exit: locals are gone when the EXIT trap fires.
  # shellcheck disable=SC2064
  trap "rm -rf '$w'" EXIT
  cd "$w"
  local kind=codegen-failed; case "$root" in *[[:space:]]*) kind=path-has-spaces;; esac    # the kernel splits a #! line at spaces
  printf 'module Main\nmain : IO ()\nmain = putStrLn "chez_codegen ok"\n' > Main.idr
  "$root/bin/scheme" --program "$root/bin/idris2_app/idris2.so" -o hello Main.idr >/dev/null 2>&1 || fail E-PROBE-CODEGEN $kind probe="chez_codegen (compile)" store="$root"
  [ "$(./build/exec/hello 2>/dev/null)" = "chez_codegen ok" ] || fail E-PROBE-CODEGEN $kind probe="chez_codegen (run the compiled program)" store="$root"
  mkdir -p "$w/moved dir" && mv build/exec "$w/moved dir/exec" && [ "$(env -i PATH=/usr/bin:/bin "$w/moved dir/exec/hello" 2>/dev/null)" = "chez_codegen ok" ] \
    || fail E-PROBE-CODEGEN $kind probe="relocatable_artifact (run after moving, clean environment)" store="$root"
  if command -v cc >/dev/null; then "$root/bin/scheme" --program "$root/bin/idris2_app/idris2.so" --cg refc -o hello_refc Main.idr >/dev/null 2>&1 && [ "$(./build/exec/hello_refc)" = "chez_codegen ok" ] && echo "[OK] refc_codegen" || echo "[FAIL] refc_codegen (cc present but RefC path broken)"; else echo "[skip] refc_codegen (no cc)"; fi
  echo "[OK] pure_eval version_match chez_codegen relocatable_artifact"; }

cmd_explain() { # explain [ID]: the long form of an error, offline, from the same data as the message itself
  local id=${1:-} j; j=$("$HERE/../lib/toml2json.sh" "$ERRORS_TOML")
  if [ -z "$id" ]; then jq -r '.error[] | .id + (" " * (24 - (.id | length))) + "exit " + (.exit | tostring | (" " * (2 - length)) + .) + "  " + (.title // .meaning)' <<< "$j"; return 0; fi
  jq -e --arg id "$id" '.error[] | select(.id == $id)' <<< "$j" >/dev/null || fail E-USAGE no-such-id word="$id"
  jq -r -L "$HERE" --arg id "$id" --arg r "$RUNBOOK" 'include "clean"; ($r | clean) as $r | (.error[] | select(.id == $id)) as $e | [(.case // [])[] | select(.error == $id)] as $c
    | "\($id) (exit \($e.exit)): \($e.title // $e.meaning)", "", "Meaning: \($e.meaning)", "Usual fix: \($e.fix)",
      (if ($c | length) > 0 then "", "It takes \($c | length) shape(s). Words in {braces} are filled in when it happens.",
         ($c[] | "", "  \(.case): \(.summary)", "    why: \(.why)", "    now: \(.state)",
            (if .fix_cmd != "" then "    fix: \(.fix_cmd)" else empty end), (if .fix_note != "" then "    note: \(.fix_note)" else empty end))
       else empty end), "", "Runbook: \($r)/\($id).adoc"' <<< "$j"; }

USAGE=("pin <version>|choose a version; writes idris2x.lock" "install [--locked] [--from <bundle>]|fetch and verify the pinned capsule" "exec -- <idris2 args>|run the pinned Idris 2" "run -- <chez args>|run the pinned Chez Scheme" "env [--json]|print the environment the toolchain runs in" "verify|re-check the installed capsule" "gc [--keep-last N]|remove old capsules" "fetch -o <bundle>|download the pinned capsule to a file" "doctor|report on this machine and project" "selftest|compile and run a test program" "explain [<id>]|describe an error id")
cmd=${1:-}; shift || true

case "$cmd" in
  pin) cmd_pin "$@";; install) cmd_install "$@";; exec) cmd_exec "$@";; run) cmd_run "$@";; env) cmd_env "$@";;
  verify) cmd_verify;; gc) cmd_gc "$@";; fetch) cmd_fetch "$@";; doctor) cmd_doctor;; selftest) cmd_selftest;;
  explain) cmd_explain "$@";; __render) render "$@";;      # __render FORM ID CASE k=v...: test hook for scripts/proto/dx-golden.sh
  version|--version) echo "idris2x $PROTO_VERSION (prototype)";;
  help|--help|-h) echo "usage: idris2x <command>"; for u in "${USAGE[@]}"; do printf '  %-38s %s\n' "${u%%|*}" "${u#*|}"; done;;

  *) fail E-USAGE unknown-command word="${cmd:-(nothing)}" commands="pin, install, exec, run, env, verify, gc, fetch, doctor, selftest, explain, help";;
esac
