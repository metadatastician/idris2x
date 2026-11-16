-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
module Main
-- canary 4: exercises libidris2_support (idris2_getPID) and the C FFI loader path
import System
main : IO ()
main = do pid <- getPID
          putStrLn (if pid > 0 then "c_ffi_support ok" else "c_ffi_support FAIL pid=" ++ show pid)
