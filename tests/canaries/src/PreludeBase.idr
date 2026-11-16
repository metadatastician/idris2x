-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
module Main
-- canary 7: prelude + base libraries resolve and typecheck (Data.List, Data.String, Data.Vect)
import Data.List
import Data.String
import Data.Vect
total
v : Vect 3 Nat
v = [1, 2, 3]
main : IO ()
main = putStrLn ("prelude_base ok " ++ show (sum [1..10]) ++ " " ++ show (length (words "a b c")) ++ " " ++ show (toList v))
