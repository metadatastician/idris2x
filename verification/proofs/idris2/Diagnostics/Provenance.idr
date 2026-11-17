-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
--
-- Design model: provenance-typed diagnostic text (docs/decisions/0012, Proposed).
-- Question it answers: if the signed channel is ever allowed to carry message text, can the
-- type of a message guarantee that channel text never reaches the `fix` slot (the command a
-- user is told to paste), and that the execution path never shows channel text at all?
-- This is a model of the DESIGN. It says nothing about the Rust launcher, which does not exist.
-- All proofs are constructive and total; no escape hatches.

module Diagnostics.Provenance

import Data.List
import Data.List1
import Data.String

%default total

||| Where a piece of text came from. This is an integrity label, not a secrecy label.
public export
data Prov
  = Embedded  -- compiled into the launcher from src/errors/errors.toml
  | Host      -- this machine: argv, paths, environment, the clock
  | Lock      -- idris2x.lock, a local file; every capsule it names is digest-checked
  | Channel   -- the signed channel manifest (trusted as far as the channel key is)
  | Checked   -- a lock value that passed a format check in THIS module (checkDigest, checkVersion)

||| Text that remembers its provenance. The constructor is NOT exported: outside this module a
||| `Txt p` can only be obtained from the entry points below, so provenance cannot be forged.
export
data Txt : Prov -> Type where
  MkTxt : String -> Txt p

||| The embedded message table is the only source of `Embedded` text. In the launcher this is
||| the table generated from errors.toml; here a closed enumeration stands in for it.
public export
data Phrase = TryAgain | PinAgain | RemoveEntry | UpdateLauncher

export
embedded : Phrase -> Txt Embedded
embedded TryAgain       = MkTxt "idris2x install --locked"
embedded PinAgain       = MkTxt "idris2x pin "
embedded RemoveEntry    = MkTxt "rm -rf "
embedded UpdateLauncher = MkTxt "update idris2x"

||| Entry points for untrusted-by-the-binary text. Each fixes the label at the boundary.
export
fromHost : String -> Txt Host
fromHost = MkTxt

export
fromLock : String -> Txt Lock
fromLock = MkTxt

export
fromChannel : String -> Txt Channel
fromChannel = MkTxt

||| Format checks: the only way to obtain `Checked` text. A lock is a local file an attacker may
||| have written, so raw lock text never reaches a fix command (ClientRejected 6); a value that
||| passes one of these checks can carry no shell syntax, and may (FixChecked).
isLowerHex : Char -> Bool
isLowerHex c = isDigit c || (c >= 'a' && c <= 'f')

||| A sha256 digest: exactly 64 lowercase hexadecimal characters.
export
checkDigest : String -> Maybe (Txt Checked)
checkDigest s = if length s == 64 && all isLowerHex (unpack s) then Just (MkTxt s) else Nothing

||| A version: two to four non-empty runs of decimal digits separated by single dots.
export
checkVersion : String -> Maybe (Txt Checked)
checkVersion s =
  let parts = forget (split (== '.') s) in
  if length parts >= 2 && length parts <= 4 && all (\p => p /= "" && all isDigit (unpack p)) parts
     then Just (MkTxt s) else Nothing

||| Who is building the message. `Executor` is `install --locked` / `exec --locked` (ADR 0008:
||| execution never reads the channel); `Resolver` is `pin` / `update`.
public export
data Role = Resolver | Executor

||| The parts of a message.
public export
data Slot
  = Fix       -- the command to paste
  | Prose     -- summary, state, why, note
  | Fact      -- the labelled values shown to the user
  | Advisory  -- a labelled note from the channel publisher

||| The policy: which provenance may appear in which slot, for which role.
||| Read it as a table. There is no row that puts `Channel` in `Fix` or `Prose`,
||| and no row that gives the `Executor` any `Channel` text at all.
public export
data Allowed : Role -> Slot -> Prov -> Type where
  FixEmbedded   : Allowed r Fix Embedded
  FixHost       : Allowed r Fix Host            -- a quoted path or the version the user typed
  FixChecked    : Allowed r Fix Checked         -- a lock digest or version that passed its format check
  ProseEmbedded : Allowed r Prose Embedded
  ProseHost     : Allowed r Prose Host
  FactEmbedded  : Allowed r Fact Embedded
  FactHost      : Allowed r Fact Host
  FactLock      : Allowed r Fact Lock           -- digests, URLs and versions from the lock
  FactChecked   : Allowed r Fact Checked
  FactChannel   : Allowed Resolver Fact Channel -- e.g. the versions the channel offers
  AdviceChannel : Allowed Resolver Advisory Channel

||| One fragment of a slot: some text, with evidence that the policy allows it there.
public export
data Frag : Role -> Slot -> Type where
  MkFrag : (p : Prov) -> Txt p -> {auto 0 ok : Allowed r s p} -> Frag r s

public export
provOf : Frag r s -> Prov
provOf (MkFrag p _) = p

||| Rendered output is opaque: there is no function from `Rendered` back to `String` except the
||| IO sink `emit`, so rendered channel text cannot be fed to `fromHost` and relabelled
||| (ClientRejected 8). The trusted base is therefore only the ingress: the code that reads the
||| channel, the lock and the host must call the matching entry point above.
export
data Rendered = MkRendered String

raw : Frag r s -> String
raw (MkFrag _ (MkTxt str)) = str

export
render : Frag r s -> Rendered
render f = MkRendered (raw f)

export
renderAll : List (Frag r s) -> Rendered
renderAll fs = MkRendered (concat (map raw fs))

||| The only way out: print it.
export
emit : HasIO io => Rendered -> io ()
emit (MkRendered str) = putStr str

-- ---------------------------------------------------------------------------------------
-- Theorems
-- ---------------------------------------------------------------------------------------

Uninhabited (Allowed r Fix Channel) where
  uninhabited FixEmbedded impossible

Uninhabited (Allowed r Prose Channel) where
  uninhabited ProseEmbedded impossible

Uninhabited (Allowed Executor s Channel) where
  uninhabited FixEmbedded impossible

||| T1. No fix command contains channel text, for either role.
export
fixNeverChannel : (f : Frag r Fix) -> Not (provOf f = Channel)
fixNeverChannel (MkFrag Embedded _) Refl impossible
fixNeverChannel (MkFrag Host _) Refl impossible
fixNeverChannel (MkFrag Lock _ {ok}) Refl impossible
fixNeverChannel (MkFrag Checked _) Refl impossible
fixNeverChannel (MkFrag Channel _ {ok}) _ = void (absurd ok)

||| T2. On the execution path no slot contains channel text (the typed form of ADR 0008
||| for diagnostics: what `exec --locked` prints cannot depend on what the channel says).
export
executorNeverChannel : (f : Frag Executor s) -> Not (provOf f = Channel)
executorNeverChannel (MkFrag Embedded _) Refl impossible
executorNeverChannel (MkFrag Host _) Refl impossible
executorNeverChannel (MkFrag Lock _) Refl impossible
executorNeverChannel (MkFrag Checked _) Refl impossible
executorNeverChannel (MkFrag Channel _ {ok}) _ = void (absurd ok)

||| Replace every piece of channel text by the empty string: "what if the channel had said
||| something else, or nothing".
export
scrub : Frag r s -> Frag r s
scrub (MkFrag Channel _ {ok}) = MkFrag Channel (MkTxt "") {ok}
scrub f = f

scrubFixId : (f : Frag r Fix) -> scrub f = f
scrubFixId (MkFrag Embedded _) = Refl
scrubFixId (MkFrag Host _) = Refl
scrubFixId (MkFrag Lock _) = Refl
scrubFixId (MkFrag Checked _) = Refl
scrubFixId (MkFrag Channel _ {ok}) = void (absurd ok)

scrubExecId : (f : Frag Executor s) -> scrub f = f
scrubExecId (MkFrag Embedded _) = Refl
scrubExecId (MkFrag Host _) = Refl
scrubExecId (MkFrag Lock _) = Refl
scrubExecId (MkFrag Checked _) = Refl
scrubExecId (MkFrag Channel _ {ok}) = void (absurd ok)

mapId : {0 g : a -> a} -> ((x : a) -> g x = x) -> (xs : List a) -> map g xs = xs
mapId _ [] = Refl
mapId h (x :: xs) = rewrite h x in rewrite mapId h xs in Refl

||| T3 (non-interference for the fix slot). The rendered fix command is the same whatever
||| the channel text was: erasing all channel text does not change it.
export
fixIndependentOfChannel : (fs : List (Frag r Fix)) -> renderAll (map Provenance.scrub fs) = renderAll fs
fixIndependentOfChannel fs = rewrite mapId scrubFixId fs in Refl

||| T4 (non-interference for the execution path). Nothing the executor prints, in any slot,
||| changes when channel text is erased.
export
executorIndependentOfChannel : (fs : List (Frag Executor s)) -> renderAll (map Provenance.scrub fs) = renderAll fs
executorIndependentOfChannel fs = rewrite mapId scrubExecId fs in Refl

||| T5 (the policy is not vacuous). For the resolver, a channel advisory really does change
||| with the channel: scrubbing it changes what is rendered.
export
advisoryDependsOnChannel : Not (renderAll (map Provenance.scrub [the (Frag Resolver Advisory) (MkFrag Channel (MkTxt "x"))])
                                = renderAll [the (Frag Resolver Advisory) (MkFrag Channel (MkTxt "x"))])
advisoryDependsOnChannel Refl impossible
