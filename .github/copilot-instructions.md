<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk> -->
<!-- Authoritative source: docs/practice/AI-CONVENTIONS.adoc -->

# Copilot Instructions

## Before Writing Code

- Read the repo deed (`*_chora.deed` in the repo root) for canonical file locations
  (its `(ply ...)` clauses carry the canonical-locations tables).
- No `.a2ml` file may exist anywhere: state and metadata are clauses of the repo deed.

## License

- SPDX: `MPL-2.0` on all new files.
- Never use AGPL-3.0.
- Copyright: `Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>`

## Code Style

- Use descriptive variable names.
- Annotate and document all files.
- Add SPDX header to every source file.
- Use `just` for build/test/lint commands.

## Banned Patterns

- Idris2: no `believe_me`, no `assert_total`
- Haskell: no `unsafeCoerce`, no `unsafePerformIO`
- OCaml: no `Obj.magic`
- Coq: no `Admitted`
- Lean: no `sorry`
- Rust: no `transmute` unless FFI with `// SAFETY:` comment

## JavaScript / TypeScript runtimes

Ordered preference (`standards/3-practice/LANGUAGE-POLICY.adoc` §1) — reach for the first
that can do the job:

1. **Bun** — default for all new work. Runs compiled ESM/JS directly, no bundler
   step. Uses an npm-compatible `package.json` plus `bun.lock`; both are
   expected, not anti-patterns.
2. **Deno** — permitted (tier 2). Deno 2 reads the same `package.json` and runs
   its scripts with `deno task`.
3. **pnpm** — tier 3.
4. **npm** — last resort. Permitted, never preferred; it keeps no lock
   (`package-lock.json` stays refused).

**One manifest, every runtime** (owner ruling 2026-10-14, `LANGUAGE-POLICY.adoc`
§1.3–§1.4). `package.json` is the only manifest and carries every runtime's lock:
`bun.lock`, `deno.lock` and `pnpm-lock.yaml`. `js-runtimes regen` is the only
writer; run it after every `bun add`. Governance checks each runtime against its
lock. The ruling supersedes the 2026-08-26 one that removed Deno.

**TypeScript is not the language for new application code — AffineScript is.**
`LANGUAGE-POLICY.adoc` §1.2, ruled 2026-08-25, separates two questions the older
text ran together: *runtime* is Bun (where `.ts` runs at all, Bun runs it), while
the *language* target is AffineScript. TypeScript is permitted only where
AffineScript cannot reach — the same narrow, transitional carve-out JavaScript
holds for MCP protocol glue and runtime APIs. ReScript remains banned; its
migration destination is AffineScript.

## Banned Languages

- No Go (use Rust)
- No Python (use Julia or Rust)
- No Nix (use Guix)
- No ReScript (`LANGUAGE-POLICY.adoc` §3) — migrate to AffineScript

## Containers

Only if this repo builds a container; otherwise skip.

- Use Podman, never Docker.
- Name the file `Containerfile`, never `Dockerfile`.
- Base image: `cgr.dev/chainguard/wolfi-base`, pinned by digest (`@sha256:<digest>`; `scripts/pin-container-digests.sh`). A tag alone, `:latest` included, is not a pin: `scripts/check-container-pins.sh` fails a `FROM` that has a tag and no digest (a tag followed by a digest passes).

## ABI/FFI

This repository has no ABI/FFI seam yet: the `rust-cli` mint pruned the template's Idris 2 + Zig seam. ADR 0011 plans an
Idris 2 contract for `idris2x.lock` and `capsule.json` instead. Until it exists, do not create Zig FFI code here.

## State Files

No `.a2ml` file may exist anywhere: the format is retired. State, metadata,
`(neurosym)` and `(playbook)` are clauses of the repo deed (`*_chora.deed`);
the journal is `docs/status/ROADMAP.adoc`. Never recreate them as separate files.

## idris2x: rules for agents working in this repository

These are project facts, measured in Phase 0 (docs/status/PHASE0-REPORT.adoc). They bind every agent.

* **Five invariants.** I1 no silent drift, I2 atomic or absent, I3 loud by default, I4 the past never breaks, I5 verify before trust. A change that adds a silent fallback, an untyped failure or a network call on the execution path is wrong even if tests pass.
* **Execution never reads the channel.** `install --locked` and `exec --locked` need only `idris2x.lock` and capsule bytes. Expiry, rollback protection and deprecation gate `pin`/`update` only (ADR 0008).
* **Every failure is typed.** Add or change errors only in `src/errors/errors.toml` (exit codes are append-only), then run `scripts/gen-runbooks.sh` and `scripts/gen-issue-forms.sh`. Never hand-edit `docs/runbooks/*.adoc` above the marker or `.github/ISSUE_TEMPLATE/error_report.yml`.
* **The environment contract is a reset** (ADR 0005): inherited `IDRIS2_*`, `LD_LIBRARY_PATH`, `DYLD_*`, `CHEZ`, `SCHEMEHEAPDIRS` are code search paths, and the dynamic loader loads `LD_PRELOAD` and `LD_AUDIT` into every process; the launcher sets the search paths, clears the other two, and inherits none unless `--inherit-env`.
* **Resume only immutable, digest-addressed downloads.** Never resume the channel manifest or any mutable document.
* **Archive extraction** rejects absolute names, `..`, links escaping the staging tree, devices and setuid bits, and uses a containment check, never `join(dst, clean(name))`.
* **Languages:** Rust for the launcher, bash + jq + awk for scripts. No Python, Go or Node.js (estate policy and this repo's anchor). The capsule factory *invokes* upstream Makefiles; it never patches Idris 2 or Chez Scheme (zero-fork policy).
* **The launcher stays under 2,000 lines of our own code.** A feature that does not fit belongs in the channel (data) or the capsule.
* **The maintenance agent** may only propose one of four shapes (`compat_patch`, `pin_bump`, `mirror_add`, `escalate`), never signs, never approves or merges its own PR, never widens `src/definitions/targets.toml`. Any open issue labelled `agent:kill-switch` stops it.
* **Report faithfully.** The launcher, factory and published capsules do not exist yet; do not describe planned behaviour as shipped.
