-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
--
-- Client-side experiment for Diagnostics.Provenance: code OUTSIDE the trusted module.
-- The `failing` blocks are the negative results: each must be rejected by the type checker,
-- and this file only compiles if every one of them is.

module Diagnostics.ProvenanceClient

import Diagnostics.Provenance

%default total

||| Accepted: a fix built from the embedded table and a host value (the version the user typed).
pinFix : String -> List (Frag Resolver Fix)
pinFix version = [MkFrag Embedded (embedded PinAgain), MkFrag Host (fromHost version)]

||| Accepted: the resolver may show channel data as a fact and as a labelled advisory.
offered : String -> Frag Resolver Fact
offered versions = MkFrag Channel (fromChannel versions)

advisory : String -> Frag Resolver Advisory
advisory note = MkFrag Channel (fromChannel note)

||| Accepted: the executor shows lock data as a fact.
pinnedDigest : String -> Frag Executor Fact
pinnedDigest d = MkFrag Lock (fromLock d)

-- Rejected 1: channel text in the fix slot.
failing "Can't find an implementation for Allowed Resolver Fix Channel"
  evilFix : String -> Frag Resolver Fix
  evilFix s = MkFrag Channel (fromChannel s)

-- Rejected 2: channel text in prose (summary, state, why, note).
failing "Can't find an implementation for Allowed Resolver Prose Channel"
  evilProse : String -> Frag Resolver Prose
  evilProse s = MkFrag Channel (fromChannel s)

-- Rejected 3: the executor showing channel text anywhere, even as a fact or an advisory.
failing "Can't find an implementation for Allowed Executor Fact Channel"
  execFact : String -> Frag Executor Fact
  execFact s = MkFrag Channel (fromChannel s)

failing "Can't find an implementation for Allowed Executor Advisory Channel"
  execAdvice : String -> Frag Executor Advisory
  execAdvice s = MkFrag Channel (fromChannel s)

-- Rejected 4: relabelling. Channel text cannot be passed off as embedded text...
failing "Mismatch between: Channel and Embedded"
  relabel : String -> Frag Resolver Fix
  relabel s = MkFrag Embedded (fromChannel s)

-- Rejected 5: ...and the constructor that would forge a label is not visible here.
failing "MkTxt is private"
  forge : String -> Txt Embedded
  forge s = MkTxt s

-- Rejected 6: lock data in the fix slot (a lock is a local file an attacker may have written).
failing "Can't find an implementation for Allowed Executor Fix Lock"
  lockFix : String -> Frag Executor Fix
  lockFix s = MkFrag Lock (fromLock s)
