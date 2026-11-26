<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
## Summary

<!-- Briefly describe what this PR does and why. Link to related issues with "Closes #N". -->

## Changes

<!-- List the key changes introduced by this PR. -->

-

## RSR Quality Checklist

<!-- Check all that apply. PRs that fail required checks will not be merged. -->

### Required

- [ ] Tests pass (`just test` or equivalent)
- [ ] Code is formatted (`just fmt` or equivalent)
- [ ] Linter is clean (no new warnings or errors)
- [ ] No banned language patterns (no Python, Go, TypeScript or ReScript; JavaScript runs Bun > Deno > pnpm > npm)
- [ ] No `unsafe` blocks without `// SAFETY:` comments
- [ ] No banned functions (`believe_me`, `unsafeCoerce`, `Obj.magic`, `Admitted`, `sorry`)
- [ ] SPDX license headers present on all new/modified source files
- [ ] No secrets, credentials, or `.env` files included

### As Applicable

- [ ] Repo deed (`*_chora.deed`) `(status)` / `(maturity)` updated (if project state changed)
- [ ] Repo deed `(ecosystem)` updated (if integrations changed)
- [ ] Repo deed `(meta)` and/or `docs/decisions/` updated (if architectural decisions changed)
- [ ] `docs/status/ROADMAP.adoc` updated (if milestones or next actions changed)
- [ ] Documentation updated for user-facing changes
- [ ] `docs/architecture/TOPOLOGY.adoc` updated (if architecture changed)
- [ ] `CHANGELOG` or release notes updated
- [ ] New dependencies reviewed for license compatibility (compatible with MPL-2.0)
- [ ] Interface contract changes (`src/contracts/`, `src/errors/errors.toml`) reflected in the ADRs and regenerated outputs

## Testing

<!-- Describe how you tested these changes. -->

## Screenshots

<!-- If applicable, add screenshots or terminal output demonstrating the change. -->

## idris2x specifics

<!-- Delete the rows that do not apply. -->

- Risk class: [ ] A (mirror, URL, docs) · [ ] B (version pin, checksum) · [ ] C (launcher, schema, exit codes, support matrix: link the ADR)
- [ ] Channel patch: `channel_version` is exactly +1, the manifest validates against `src/contracts/channel-v1.schema.json`, and `expires` is set
- [ ] Canaries green on three targets (link the run)
- [ ] Error taxonomy changed: `src/errors/errors.toml` edited (exit codes append-only), then `scripts/gen-runbooks.sh` and `scripts/gen-issue-forms.sh` re-run
- [ ] Launcher still under 2,000 lines of our own code; new crates vendored and allowed in `deny.toml`
- [ ] User-facing output changed: before/after transcript pasted below (plain, `NO_COLOR=1` and `--json`)
- [ ] Wiki source changed in `docs/wikis/` (published on merge)
