# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# render.jq — turn (error id, case, context) into the message a user reads. Every word comes from src/errors/errors.toml.
# Input: errors.toml as JSON. Args: $id $case $style (a|b) $form (tty|plain|json) $width $runbook, $ctx (object).
# Style a is conversational (after Elm); style b is one labelled field per line (after rustc and cargo).
# The exact output is a contract: docs/dx/ERROR-CATALOGUE-RENDERED.adoc holds it and scripts/proto/dx-golden.sh checks it.
# A context value can come from a lock, a capsule or the host. Text and terminal forms show each hidden character in it
# as "?", and JSON writes it as \uXXXX (clean.jq).
include "clean";
# One pass over the template: an inserted value is never scanned again, so it cannot pull in another key's value.
def fill($c): gsub("\\{(?<k>[a-z_]+)\\}"; .k as $k | if $c | has($k) then $c[$k] else "{" + $k + "}" end);
# A value placed in a fix command is shell text the user will paste: leave plain words bare, single-quote everything else.
def shq: if test("^[A-Za-z0-9_./:@%+=,-]+$") then . else "'" + gsub("'"; "'\\''") + "'" end;
def wrap($w): reduce (split(" ")[] | select(. != "")) as $word ([""];
    if (.[-1] | length) == 0 then .[-1] = $word
    elif ((.[-1] | length) + 1 + ($word | length)) <= $w then .[-1] += " " + $word
    else . + [$word] end) | join("\n");
def para($w): if . == "" then empty else wrap($w) end;
def paint($on; $code): if $on then "\u001b[" + $code + "m" + . + "\u001b[0m" else . end;
($width | tonumber) as $w | ($form == "tty") as $tty
| ($ctx | if $form == "json" then . else map_values(clean) end) as $ctx
| (.error[] | select(.id == $id)) as $e
| ((.case // [])[] | select(.error == $id and .case == $case)) as $k
| ($k | with_entries(select(.value | type == "string") | if .key == "fix_cmd" then .value |= fill($ctx | map_values(shq)) else .value |= fill($ctx) end)) as $t
| ($t.facts | split(" ") | map(select(. != "") | split("=") | {label: .[0], value: ($ctx[.[1]] // error("missing context value: " + .[1]))})) as $facts
| if any($k | to_entries[] | select(.value | type == "string") | .value | scan("\\{([a-z_]+)\\}") | .[0]; . as $p | $ctx | has($p) | not) then error("unfilled {placeholder} in " + $id + "/" + $case) else . end
| ($runbook + "/" + $id + ".adoc") as $docs
| if $form == "json" then
    {schema: 1, tool: "idris2x", level: "error", id: $id, case: $case, exit: $e.exit, title: $e.title, summary: $t.summary,
     context: $ctx, state: $t.state, why: $t.why, fix: {command: $t.fix_cmd, note: $t.fix_note, auto: $t.auto},
     explain: ("idris2x explain " + $id), docs: $docs} | tojson | inert
  elif $style == "a" then
    [ (if $tty then ("-- " + $id + " (exit " + ($e.exit | tostring) + ") ") as $h
         | ($h + ("-" * ([$w - ($h | length) - 8, 2] | max)) + " idris2x") | paint(true; "36")
       else "idris2x: " + $id + " (exit " + ($e.exit | tostring) + ")" end),
      ($t.story | wrap($w)),
      ($facts | (map(.label | length) | max // 0) as $m
         | map("    " + .label + (" " * ($m - (.label | length) + 2)) + .value) | join("\n") | select(. != "")),
      ($t.state | para($w)),
      ($t.why | para($w)),
      (if $t.fix_cmd != "" then (($t.fix_lead | para($w)), "    " + ($t.fix_cmd | paint($tty; "1"))) else empty end),
      ($t.fix_note | para($w)),
      "More: idris2x explain " + $id + "\n" + $docs
    ] | join("\n\n")
  else
    [ "idris2x: " + ("error[" + $id + "]" | paint($tty; "1;31")) + ": " + $t.summary,
      ($facts[] | "    " + .label + ": " + .value),
      "  " + ("state" | paint($tty; "1")) + ": " + $t.state,
      "  " + ("why" | paint($tty; "1")) + ": " + $t.why,
      (if $t.fix_cmd != "" then "  " + ("fix" | paint($tty; "1")) + ": " + ($t.fix_cmd | paint($tty; "1")) else empty end),
      (if $t.fix_note != "" then "  " + ((if $t.fix_cmd != "" then "note" else "fix" end) | paint($tty; "1")) + ": " + $t.fix_note else empty end),
      "  " + ("see" | paint($tty; "1")) + ": idris2x explain " + $id,
      "  " + ("see" | paint($tty; "1")) + ": " + $docs
    ] | join("\n")
  end
