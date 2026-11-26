# SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
# MPL-2.0 (code) and CC-BY-SA-4.0 (prose)
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
# clean.jq — characters that can hide or rewrite text on a terminal. src/msg.rs `hidden` is the same set.
# A value read from a lock, a capsule or the host can hold them; a message must not let it move the cursor, clear the
# screen or reorder the text around it.
# hidden: a code point that is a control character (C0, DEL or C1), a no-break or soft hyphen space, a zero-width
# character or a bidirectional control.
def hidden: . < 32 or (. >= 127 and . <= 160) or . == 173 or (. >= 8203 and . <= 8207) or (. >= 8234 and . <= 8239)
  or . == 8288 or (. >= 8294 and . <= 8297) or . == 65279;
# clean: the text with each hidden character shown as "?", for a text or terminal message.
def clean: explode | map(if hidden then 63 else . end) | implode;
# inert: JSON text with each hidden character written as \uXXXX. A parser reads the same value; a terminal shows six
# plain characters.
def hex4: . as $n | [4096, 256, 16, 1] | map(. as $d | "0123456789abcdef"[($n / $d | floor) % 16:][:1]) | add;
def inert: explode | map(if hidden then ("\\u" + hex4 | explode)[] else . end) | implode;
