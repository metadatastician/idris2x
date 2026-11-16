#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# dx-golden.sh — the wording contract. Renders every [[case]] in src/errors/errors.toml with fixed sample values, in both
# A/B styles and all three forms (terminal, plain, --json), into docs/dx/ERROR-CATALOGUE-RENDERED.adoc.
# `--check` exits 1 if that file would change: a wording change must be made on purpose, in the TOML, and reviewed as a diff.
# Needs only bash, jq and awk (no capsule, no network), so it runs in every CI job. chaos.sh checks the live call sites.
set -euo pipefail
P=$(cd "$(dirname "$0")" && pwd); R=$(cd "$P/../.." && pwd); X="$P/idris2x.sh"; out="$R/docs/dx/ERROR-CATALOGUE-RENDERED.adoc"
check=0; [ "${1:-}" = --check ] && check=1
unset NO_COLOR IDRIS2X_JSON IDRIS2X_COLOR IDRIS2X_ERROR_FILE IDRIS2X_RUNBOOK; export COLUMNS=80
A=0d7a4c1e9b52f6a83c07d1e45b9a2f6c8e13d7b0a5942c6f1e8d3b7a094c5e21; B=3f1c88a2d4e6071b95c3fa2e6d8097b4c1a5e3f7029b6d4c8a1e5f3b7d902c64
samples() { cat <<S
E-USAGE|unknown-command|word=instal|commands=pin, install, exec, run, env, verify, gc, fetch, doctor, selftest, explain, help
E-USAGE|unknown-flag|command=install|word=--lock|usage=idris2x install [--locked] [--from <bundle>]
E-USAGE|missing-argument|command=pin|what=a version to pin|usage=idris2x pin <version>
E-USAGE|no-such-file|path=capsule.tar.gz|dir=/home/ada/proofs
E-USAGE|no-such-id|word=E-HASH
E-USAGE|prototype-setting|variable=IDRIS2X_CHANNEL_URL|what=the address of the channel manifest
E-PIN-NOT-FOUND|no-lock|lock=idris2x.lock|dir=/home/ada/proofs
E-PIN-NOT-FOUND|no-target|lock=idris2x.lock|target=aarch64-unknown-linux-gnu|covered=x86_64-apple-darwin, x86_64-unknown-linux-gnu|version=0.8.0
E-PIN-NOT-FOUND|no-version|lock=idris2x.lock|version=0.9.0|available=0.7.0, 0.8.0
E-PIN-NOT-FOUND|not-installed|digest=sha256:$A
E-PIN-NOT-FOUND|no-idris2|name=chez-10.4.1-x86_64-unknown-linux-gnu
E-PIN-NOT-FOUND|no-urls|lock=idris2x.lock|digest=sha256:$A|version=0.8.0
E-HASH-MISMATCH|download|lock=idris2x.lock|want=sha256:$A|got=sha256:$B|bytes=17706495 bytes (the lock says 35412990)|source=https://mirror.example.org/idris2-0.8.0-x86_64-unknown-linux-gnu-chez10.4.1.tar.gz
E-HASH-MISMATCH|bundle|lock=idris2x.lock|want=sha256:$A|got=sha256:$B|bytes=35412990 bytes (the lock says 35412990)|source=/media/usb/capsule.tar.gz
E-HASH-MISMATCH|store-modified|digest=sha256:$A|dir=/home/ada/.cache/idris2x/store/sha256-$A
E-SIG-INVALID|bad-signature|url=https://channel.example.org/v1.json|key=key id 9c41d07be2a5f316|version=0.8.0
E-SIG-INVALID|wrong-key|url=https://channel.example.org/v1.json|signer=key id 5be07a11c3d9f248|key=key id 9c41d07be2a5f316
E-SIG-INVALID|malformed|what=the signature is not base64|file=/home/ada/.cache/idris2x/manifests/v1.json.sig.tmp
E-PLATFORM-UNSUPPORTED|unknown-arch|arch=riscv64|supported=x86_64, aarch64
E-PLATFORM-UNSUPPORTED|unknown-os|os=FreeBSD|supported=Linux, macOS
E-NETWORK|all-mirrors-failed|digest=sha256:$A|tried=https://mirror.example.org/idris2.tar.gz: (22) The requested URL returned error: 404; https://backup.example.net/idris2.tar.gz: (6) Could not resolve host: backup.example.net|log=/home/ada/.cache/idris2x/tmp/fetch.log
E-NETWORK|manifest-unreachable|url=https://channel.example.org/v1.json|tried=https://channel.example.org/v1.json: (28) Connection timed out after 10002 milliseconds|log=/home/ada/.cache/idris2x/tmp/fetch.log|version=0.8.0
E-LOCK-TIMEOUT|held|digest=sha256:$A|seconds=600|lockfile=/home/ada/.cache/idris2x/locks/sha256-$A.lock|holder=process 48213 (still running)
E-GLIBC-FLOOR|too-old|host=2.17|needs=2.28|digest=sha256:$A
E-PROBE-CODEGEN|chez-failed|probe=pure_eval|output=error while loading shared libraries: libtinfo.so.6: cannot open shared object file
E-PROBE-CODEGEN|idris2-failed|probe=version_match|output=Exception: (while loading libidris2_support.so) cannot open shared object file
E-PROBE-CODEGEN|version-mismatch|want=0.8.0|got=Idris 2, version 0.7.0
E-PROBE-CODEGEN|path-has-spaces|probe=chez_codegen (run the compiled program)|store=/home/ada/My Cache/idris2x/store/sha256-$A
E-PROBE-CODEGEN|codegen-failed|probe=chez_codegen (compile)|store=/home/ada/.cache/idris2x/store/sha256-$A
E-CHANNEL-SCHEMA|lock-newer|file=idris2x.lock|found=2|supports=1|version=0.1.0
E-CHANNEL-SCHEMA|channel-newer|url=https://channel.example.org/v1.json|found=2|supports=1|version=0.1.0
E-PIN-DRIFT|toml-vs-lock|toml=0.8.1|locked=0.8.0
E-OFFLINE|capsule-missing|digest=sha256:$A|store=/home/ada/.cache/idris2x/store|mode=IDRIS2X_OFFLINE=1|lock=idris2x.lock
E-OFFLINE|no-manifest|cache=/home/ada/.cache/idris2x/manifests/v1.json|mode=IDRIS2X_OFFLINE=1|version=0.8.0
E-CAPSULE-INVALID|unsafe-path|digest=sha256:$A
E-CAPSULE-INVALID|no-metadata|digest=sha256:$A
E-CAPSULE-INVALID|tree-mismatch|digest=sha256:$A
E-CHANNEL-ROLLBACK|version-went-back|url=https://channel.example.org/v1.json|seen=7|offered=5|version=0.8.0
E-CHANNEL-EXPIRED|expired|url=https://channel.example.org/v1.json|expires=2026-10-01T00:00:00Z|now=2026-11-16T09:30:00Z|version=0.8.0
E-STORE-IO|cannot-create|path=/opt/shared/idris2x
E-STORE-IO|write-failed|detail=downloading the capsule ((23) Failure writing output to destination)|path=/home/ada/.cache/idris2x
E-STORE-IO|rename-failed|path=/home/ada/.cache/idris2x/store/sha256-$A
E-INTERNAL|bug|detail=no advice called gc-warning|version=0.1.0
E-INTERNAL|missing-tool|tool=flock
S
}
block() { printf '.%s\n[source,text]\n----\n' "$1"; sed 's/\x1b/<ESC>/g'; printf -- '----\n\n'; }
new=$( cat <<H
// SPDX-License-Identifier: CC-BY-SA-4.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// GENERATED by scripts/proto/dx-golden.sh from src/errors/errors.toml and scripts/proto/render.jq. Do not edit.
= Error catalogue: rendered messages (generated, regression-tested)
:toc: macro

This page is the wording contract for both message styles; link:ERROR-CATALOGUE.adoc[the error catalogue] explains them.
Every block is the exact output of the *prototype* launcher (\`scripts/proto/idris2x.sh\`) for fixed sample values, at 80 columns.
\`scripts/proto/dx-golden.sh --check\` fails when any character here would change. The Rust launcher does not exist yet;
when it does, it must reproduce the chosen style byte for byte.

In the terminal form, \`<ESC>\` stands for the escape byte (0x1b) that starts a colour sequence: \`<ESC>[1;31m\` is bold red,
\`<ESC>[36m\` cyan, \`<ESC>[1m\` bold and \`<ESC>[0m\` reset. \`--json\` output is one line; it is the same for both styles.

toc::[]

H
  prev=
  while IFS='|' read -r id case rest; do
    IFS='|' read -r -a ctx <<< "$rest"
    [ "$id" = "$prev" ] || printf '== %s\n\n' "$id"; prev=$id
    printf '=== %s, case `%s`\n\n' "$id" "$case"
    for s in a b; do
      IDRIS2X_STYLE=$s "$X" __render plain "$id" "$case" "${ctx[@]}" | block "Style ${s^^}, plain (not a terminal, NO_COLOR set, or TERM=dumb)"
      IDRIS2X_STYLE=$s "$X" __render tty   "$id" "$case" "${ctx[@]}" | block "Style ${s^^}, interactive terminal"
    done
    "$X" __render json "$id" "$case" "${ctx[@]}" | block "--json (both styles)"
  done < <(samples) )
want=$("$R/scripts/lib/toml2json.sh" "$R/src/errors/errors.toml" | jq -r '.case[] | "\(.error)|\(.case)"' | sort)
have=$(samples | cut -d'|' -f1,2 | sort)
[ "$want" = "$have" ] || { echo "dx-golden: samples() and the [[case]] list in errors.toml differ:" >&2; diff <(echo "$want") <(echo "$have") >&2 || true; exit 1; }
if [ $check = 1 ]; then
  if [ -f "$out" ] && [ "$(cat "$out")" = "$new" ]; then echo "dx-golden: wording contract holds ($(samples | wc -l) cases x 5 renderings)"
  else echo "dx-golden: rendered messages differ from $out (run scripts/proto/dx-golden.sh and review the diff)" >&2
    diff <(printf '%s\n' "$new") "$out" 2>&1 | head -20 >&2 || true; exit 1; fi
else mkdir -p "$(dirname "$out")"; printf '%s\n' "$new" > "$out"; echo "wrote $out"; fi
