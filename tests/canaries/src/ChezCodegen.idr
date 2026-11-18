-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
module Main
-- canary 2/3: compile + run via Chez (and via RefC with --cg refc); exact stdout is asserted
main : IO ()
main = putStrLn "chez_codegen ok"
