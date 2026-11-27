// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
//! The text `store::utc` writes, at the edges. Creusot proves the day arithmetic in `src/civil.rs`
//! (verification/proofs/creusot/); the formatting around it is only tested, here.
use idris2x::{civil, store::utc};

#[test]
fn utc_writes_rfc_3339_at_the_edges() {
    assert_eq!(utc(0), "1970-01-01T00:00:00Z");
    assert_eq!(utc(-1), "1969-12-31T23:59:59Z");
    assert_eq!(utc(951_782_400), "2000-02-29T00:00:00Z");
    assert_eq!(utc(253_402_300_799), "9999-12-31T23:59:59Z");
    assert_eq!(utc(-719_468 * 86_400), "0000-03-01T00:00:00Z");
}

#[test]
fn days_and_civil_agree_on_known_dates() {
    assert_eq!(civil::days(1970, 1, 1), 0);
    assert_eq!(civil::days(2000, 2, 29), 11_016);
    assert_eq!(civil::civil(11_016), (2000, 2, 29));
    assert_eq!(civil::civil(-1), (1969, 12, 31));
}
