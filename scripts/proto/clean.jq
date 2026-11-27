# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose)
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# clean.jq — characters that can hide or rewrite text on a terminal. src/msg.rs `hidden` is the same set.
# A value read from a lock, a capsule or the host can hold them; a message must not let it move the cursor, clear the
# screen or reorder the text around it.
# hidden: a code point that is a control character (Unicode category Cc: C0, DEL, C1), a format character (every Cf of
# Unicode 15.0: zero-width and bidirectional controls, tags and the rest; the whole tag block), or a no-break space.
def hidden: . < 32 or (. >= 127 and . <= 160) or . == 173 or (. >= 1536 and . <= 1541) or . == 1564 or . == 1757
  or . == 1807 or . == 2192 or . == 2193 or . == 2274 or . == 6158 or (. >= 8203 and . <= 8207)
  or (. >= 8234 and . <= 8239) or (. >= 8288 and . <= 8292) or (. >= 8294 and . <= 8303) or . == 65279
  or (. >= 65529 and . <= 65531) or . == 69821 or . == 69837 or (. >= 78896 and . <= 78911)
  or (. >= 113824 and . <= 113827) or (. >= 119155 and . <= 119162) or (. >= 917504 and . <= 917631);
# clean: the text with each hidden character shown as "?", for a text or terminal message.
def clean: explode | map(if hidden then 63 else . end) | implode;
# inert: JSON text with each hidden character written as \uXXXX, as UTF-16, so a character past U+FFFF is a surrogate
# pair. A parser reads the same value; a terminal shows plain characters.
def hex4: . as $n | [4096, 256, 16, 1] | map(. as $d | "0123456789abcdef"[($n / $d | floor) % 16:][:1]) | add;
def units: if . > 65535 then (. - 65536) as $m | (55296 + ($m / 1024 | floor)), (56320 + $m % 1024) else . end;
def inert: explode | map(if hidden then (units | "\\u" + hex4 | explode)[] else . end) | implode;
