#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# toml2json.sh — strict TOML *subset* to JSON, for data/*.toml (no Python, no yq: estate LANGUAGE-POLICY bans Python).
# Accepted: comments, blank lines, [[array-of-tables]] headers, `key = "string"` | integer | true | false, trailing # comments.
# Anything else is a hard error: the data files are deliberately kept inside this subset (the launcher's own TOML reader is similar).
set -euo pipefail
f=${1:?usage: toml2json.sh FILE.toml}
awk -v FILE="$f" '
function die(msg) { printf("toml2json: %s:%d: %s\n", FILE, NR, msg) > "/dev/stderr"; exit 1 }
function strip_comment(s,   i, c, inq, out) {           # drop a # comment that is outside double quotes
  inq = 0; out = ""
  for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
    if (c == "\"" && substr(s, i-1, 1) != "\\") inq = !inq
    if (c == "#" && !inq) break
    out = out c }
  return out }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function flush() { if (have) { printf("{\"_table\":\"%s\"%s}\n", table, fields); have = 0; fields = "" } }
BEGIN { have = 0; fields = ""; table = "" }
{ line = trim(strip_comment($0)); if (line == "") next
  if (line ~ /^\[\[[A-Za-z0-9_-]+\]\]$/) { flush(); table = substr(line, 3, length(line) - 4); have = 1; next }
  if (line ~ /^\[/) die("only [[array-of-tables]] headers are supported")
  if (table == "" && line ~ /^schema[ \t]*=[ \t]*[0-9]+$/) { split(line, kv, "="); schema = trim(kv[2]); next }
  if (line !~ /^[A-Za-z0-9_-]+[ \t]*=[ \t]*/) die("expected key = value")
  eq = index(line, "="); key = trim(substr(line, 1, eq - 1)); val = trim(substr(line, eq + 1))
  if (val ~ /^"([^"\\]|\\.)*"$/) { gsub(/\t/, "\\t", val); jv = val }          # already a JSON string literal
  else if (val ~ /^-?[0-9]+$/ || val == "true" || val == "false") jv = val
  else die("unsupported value (only \"string\", integer, true/false): " val)
  if (!have) die("key outside any [[table]]")
  fields = fields sprintf(",\"%s\":%s", key, jv) }
END { flush(); if (schema != "") printf("{\"_table\":\"_schema\",\"schema\":%s}\n", schema) }
' "$f" | jq -s 'group_by(._table) | map({key: (if .[0]._table == "_schema" then "schema" else .[0]._table end), value: (if .[0]._table == "_schema" then .[0].schema else map(del(._table)) end)}) | from_entries'
