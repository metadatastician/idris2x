#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# check-advice-review.sh — advice must earn its place. Every [[advice]] entry in src/errors/errors.toml carries
# `review_by`, `retire_when` and `basis`. This check fails once a review date has passed, so stale advice cannot linger:
# the reviewer either renews the date (and says why in the commit) or deletes the entry.
# usage: check-advice-review.sh [--today YYYY-MM-DD]    exit 0 = all current, 1 = review due or entry malformed
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); today=$(date -u +%F); [ "${1:-}" = --today ] && today=${2:?--today needs a date}
j=$("$R/scripts/lib/toml2json.sh" "$R/src/errors/errors.toml" | jq -c '.advice // []')
bad=$(jq -r '.[] | select((.id and .text and .silence and .added and .review_by and .retire_when and .basis) | not) | .id // "(no id)"' <<< "$j")
[ -z "$bad" ] || { echo "check-advice-review: entries missing a required field (id text silence added review_by retire_when basis): $bad" >&2; exit 1; }
due=$(jq -r --arg t "$today" '.[] | select(.review_by < $t) | "  \(.id): review was due \(.review_by)\n    retire when: \(.retire_when)\n    basis: \(.basis)"' <<< "$j")
if [ -n "$due" ]; then
  { echo "check-advice-review: advice past its review date (today is $today). Renew review_by with a reason, or delete the entry:"; echo "$due"; } >&2; exit 1
fi
echo "check-advice-review: $(jq length <<< "$j") advice entries, none due before $(jq -r 'map(.review_by) | min' <<< "$j")"
