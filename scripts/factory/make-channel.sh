#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
# make-channel.sh — turn a directory of capsule bundle records into an UNSIGNED channel manifest (v1.json).
# usage: make-channel.sh --bundles DIR --base-url URL [--base-url URL ...] --channel-version N --expires YYYY-MM-DDTHH:MM:SSZ
#                        [--out FILE]   (default DIR/v1.json)
# DIR holds one `<triple>.bundle.json` per target: {"target","file","sha256","size","min_glibc","chez"}, as the factory
# workflow uploads them. Each --base-url gives one entry of every bundle's urls[] (ADR 0010: the release asset first, then
# the mirror); the launcher treats all of them as untrusted. The manifest is data only and is not signed here: the owner
# signs it offline with the root key (docs/MAINTAINERS.adoc). This script never reads a key.
# It refuses, with a message and exit 1, when: a Tier 1 target of src/definitions/targets.toml has no bundle; two bundles
# name the same target; a bundle names a target that targets.toml does not list; a field is malformed (sha256, size,
# min_glibc, chez, file name); the bundles disagree on the Idris 2 version or the Chez version; a URL is not https; the
# expiry is not a UTC date-time in the future; or the finished manifest breaks a rule of src/contracts/channel-v1.schema.json
# (the repository has no JSON Schema validator, so the rules are restated in jq below and are checked on the output).
# Exit 2 is a usage error. Needs jq; reads targets.toml through scripts/lib/toml2json.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
die() { echo "make-channel: REFUSED: $*" >&2; exit 1; }
usage() { echo "make-channel: usage: make-channel.sh --bundles DIR --base-url URL [--base-url URL ...] --channel-version N --expires YYYY-MM-DDTHH:MM:SSZ [--out FILE]" >&2; exit 2; }
DIR='' CHV='' EXP='' OUT=''; BASES=()
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --bundles) DIR=$2;; --base-url) BASES+=("$2");; --channel-version) CHV=$2;; --expires) EXP=$2;; --out) OUT=$2;;
    *) usage;;
  esac; shift 2
done
if [ -z "$DIR" ] || [ "${#BASES[@]}" -eq 0 ] || [ -z "$CHV" ] || [ -z "$EXP" ]; then usage; fi
[ -d "$DIR" ] || die "not a directory: $DIR"
OUT=${OUT:-$DIR/v1.json}

[[ "$CHV" =~ ^[1-9][0-9]*$ ]] || die "channel version '$CHV' is not a positive integer"
[[ "$EXP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die "expiry '$EXP' is not YYYY-MM-DDTHH:MM:SSZ (UTC)"
# A date that does not exist, such as 2027-02-30, comes back changed from jq's parse and print, so it is refused.
[ "$(jq -rn --arg e "$EXP" 'try ($e | fromdateiso8601 | todateiso8601) catch ""')" = "$EXP" ] || die "expiry '$EXP' is not a real UTC date and time"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
[[ "$EXP" > "$now" ]] || die "expiry $EXP is not in the future (now $now)"
for b in "${BASES[@]}"; do
  [[ "$b" =~ ^https://[^/[:space:]]+ ]] || die "base URL '$b' is not an https URL"
  [[ "$b" != */ ]] || die "base URL '$b' ends in a slash"
  [[ "$b" != *[?#]* ]] || die "base URL '$b' has a query or fragment; the capsule file name is appended to it, so it must be a plain path"
done

targets=$("$root/scripts/lib/toml2json.sh" "$root/src/definitions/targets.toml") || die "cannot read src/definitions/targets.toml"
tier1=$(jq -r '.target[] | select(.tier == 1) | .triple' <<< "$targets" | sort)
known=$(jq -r '.target[].triple' <<< "$targets" | sort)
[ -n "$tier1" ] || die "targets.toml lists no Tier 1 target"

shopt -s nullglob
files=("$DIR"/*.bundle.json)
[ "${#files[@]}" -gt 0 ] || die "no *.bundle.json in $DIR"

seen=''; vers=''; chezs=''; rows=()
for f in "${files[@]}"; do
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || die "$f is not a JSON object"
  jq -e '(keys | sort) == ["chez","file","min_glibc","sha256","size","target"]' "$f" >/dev/null 2>&1 \
    || die "$f must have exactly the keys target, file, sha256, size, min_glibc, chez (has: $(jq -c 'keys' "$f"))"
  t=$(jq -r '.target | if type == "string" then . else "" end' "$f")
  [ -n "$t" ] || die "$f: target is not a string"
  printf '%s\n' "$known" | grep -qxF -- "$t" || die "$f: target '$t' is not in src/definitions/targets.toml"
  case " $seen " in *" $t "*) die "duplicate target '$t' ($f)";; esac
  seen="$seen $t"
  [ "$(basename "$f")" = "$t.bundle.json" ] || die "$f: the file name does not match its target '$t'"
  jq -e '.sha256 | type == "string" and test("^[a-f0-9]{64}$")' "$f" >/dev/null || die "$f: sha256 is not 64 lower-case hex digits"
  jq -e '.size | type == "number" and . == floor and . >= 1' "$f" >/dev/null || die "$f: size is not a positive integer"
  jq -e '.min_glibc | . == null or (type == "string" and test("^[0-9]+\\.[0-9]+$"))' "$f" >/dev/null || die "$f: min_glibc is neither null nor MAJOR.MINOR"
  jq -e '.chez | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' "$f" >/dev/null || die "$f: chez is not MAJOR.MINOR.PATCH"
  file=$(jq -r '.file' "$f"); chez=$(jq -r '.chez' "$f")
  [[ "$file" =~ ^idris2-([0-9]+\.[0-9]+\.[0-9]+)-([a-z0-9_]+-[a-z]+-[a-z]+(-[a-z]+)?)-chez([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz$ ]] \
    || die "$f: file '$file' is not idris2-<version>-<triple>-chez<version>.tar.gz"
  [ "${BASH_REMATCH[2]}" = "$t" ] || die "$f: file '$file' names target '${BASH_REMATCH[2]}', not '$t'"
  [ "${BASH_REMATCH[4]}" = "$chez" ] || die "$f: file '$file' names chez ${BASH_REMATCH[4]}, the record says $chez"
  vers="$vers ${BASH_REMATCH[1]}"; chezs="$chezs $chez"
  rows+=("$(jq -c . "$f")")
done
for t in $tier1; do
  case " $seen " in *" $t "*) ;; *) die "no bundle for Tier 1 target '$t' (have:$seen)";; esac
done
uniq_words() { printf '%s\n' "$1" | tr ' ' '\n' | sed '/^$/d' | sort -u; }
[ "$(uniq_words "$vers" | wc -l | tr -d ' ')" = 1 ] || die "the bundles name different Idris 2 versions:$vers"
[ "$(uniq_words "$chezs" | wc -l | tr -d ' ')" = 1 ] || die "the bundles name different Chez versions:$chezs"
IV=$(uniq_words "$vers"); CV=$(uniq_words "$chezs")

urls=$(printf '%s\n' "${BASES[@]}" | jq -R . | jq -sc .)
printf '%s\n' "${rows[@]}" | jq -s --arg k "idris2@$IV" --arg cv "$CV" --argjson chv "$CHV" --arg exp "$EXP" --argjson bases "$urls" '
  { schema: 1, channel_version: $chv, expires: $exp,
    bundles: { ($k): (map({ key: .target, value: { urls: ([.file as $f | $bases[] | . + "/" + $f]), sha256, size, min_glibc, chez } }) | sort_by(.key) | from_entries) },
    compat: { ($k): { chez: $cv, platforms: (map(.target) | sort) } },
    deprecated: [] }' > "$OUT.tmp"

# The rules of src/contracts/channel-v1.schema.json, restated: required keys, no extra keys, the patterns, the minimums.
jq -e '
  def only($ks): (keys - $ks) == [];
  def hasall($ks): . as $o | all($ks[]; . as $k | $o | has($k));
  (type == "object") and only(["schema","channel_version","expires","bundles","compat","deprecated","min_launcher"])
  and hasall(["schema","channel_version","expires","bundles","compat","deprecated"])
  and .schema == 1 and (.channel_version | type == "number" and . == floor and . >= 1)
  and (.expires | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (.expires as $e | try ($e | fromdateiso8601 | todateiso8601 == $e) catch false)
  and (.deprecated | type == "array")
  and (.bundles | type == "object" and length > 0 and (keys | all(test("^idris2@[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9]+)?$")))
       and all(.[]; type == "object" and (keys | all(test("^[a-z0-9_]+-[a-z]+-[a-z]+(-[a-z]+)?$")))
         and all(.[]; only(["urls","sha256","size","chez","min_glibc","min_macos","provenance"]) and hasall(["urls","sha256","size","chez"])
           and (.urls | type == "array" and length >= 1 and all(type == "string" and test("^https://")))
           and (.sha256 | test("^[a-f0-9]{64}$")) and (.size | type == "number" and . >= 1)
           and (.chez | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
           and (.min_glibc == null or (.min_glibc | test("^[0-9]+\\.[0-9]+$"))))))
  and (.compat | type == "object" and all(.[]; has("chez") and has("platforms") and (.platforms | type == "array")))
' "$OUT.tmp" >/dev/null || { rm -f "$OUT.tmp"; die "the manifest I built breaks channel-v1.schema.json (this is a bug in make-channel.sh)"; }
mv "$OUT.tmp" "$OUT"
echo "make-channel: wrote $OUT (unsigned): idris2@$IV chez $CV, channel_version $CHV, expires $EXP, $(printf '%s\n' "${files[@]}" | wc -l | tr -d ' ') targets"
