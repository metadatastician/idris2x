;; SPDX-License-Identifier: MPL-2.0
;; SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
;; canary 11: Chez was built --threads (Idris 2 bootstrap requires it) and can fork/join a thread
(unless (threaded?) (error 'chez_threads "chez built without --threads"))
(define t (fork-thread (lambda () (display "chez_threads ok") (newline))))
(thread-join t)
