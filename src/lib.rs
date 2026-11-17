// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//!
//! Hermetic, lockfile-pinned toolchain materializer for Idris 2 + Chez Scheme: signed, self-testing capsules and a tiny launcher designed to survive abandonment
//!
//! The library half of the crate, so the behaviour is testable without spawning
//! the binary. Keep `main.rs` a thin shell around this.

/// One line describing what this program is, used by `--version` and the tests.
pub fn about() -> String {
    format!("idris2x {}", env!("CARGO_PKG_VERSION"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn about_names_the_package() {
        assert!(about().starts_with("idris2x "));
    }
}
