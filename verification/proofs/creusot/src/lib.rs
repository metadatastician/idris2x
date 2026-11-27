// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
//! Creusot proofs of the launcher's date arithmetic. `src/civil.rs` is included by path, unchanged, with its
//! contracts; this crate adds the logic they are stated in (`spec`), the lemmas, and one assumed boundary, the
//! standard library's Euclidean division. Run `scripts/check-creusot.sh`; see README.adoc beside this crate.
use creusot_std::prelude::*;

#[path = "../../../../src/civil.rs"]
pub mod civil;

pub mod spec {
    use creusot_std::prelude::*;
    /// A real date: month 1 to 12, and a day of that month in the Gregorian calendar.
    #[logic(open)]
    pub fn valid(y: Int, m: Int, d: Int) -> bool {
        pearlite! {
            let leap = y.rem_euclid(4) == 0 && (y.rem_euclid(100) != 0 || y.rem_euclid(400) == 0);
            let last = if m == 2 { if leap { 29 } else { 28 } }
                else if m == 4 || m == 6 || m == 9 || m == 11 { 30 } else { 31 };
            1 <= m && m <= 12 && 1 <= d && d <= last
        }
    }
    /// `civil::civil` in logic: the year, month and day of a day count since 1970-01-01.
    #[logic(open)]
    pub fn civil(n: Int) -> (Int, Int, Int) {
        pearlite! {
            let z = n + 719468;
            let doe = z.rem_euclid(146097);
            let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            let mp = (5 * doy + 2) / 153;
            let d = doy - (153 * mp + 2) / 5 + 1;
            let m = if mp < 10 { mp + 3 } else { mp - 9 };
            let y = yoe + z.div_euclid(146097) * 400;
            (if m <= 2 { y + 1 } else { y }, m, d)
        }
    }
    /// Every real date comes back from its day count unchanged: so no two real dates share a day count.
    #[logic(open)]
    #[requires(valid(y, m, d))]
    #[ensures(civil(days(y, m, d)) == (y, m, d))]
    pub fn date_back(y: Int, m: Int, d: Int) {
        pearlite! {
            let yy = if m <= 2 { y - 1 } else { y };
            let mp = (m + 9) % 12;
            let doy = (153 * mp + 2) / 5 + d - 1;
            let yoe = yy.rem_euclid(400);
            month_back(mp, d);
            if m == 2 && d == 29 { leap_back(y) };
            year_back(yoe, doy);
            era_back(yy.div_euclid(400), 365 * yoe + yoe / 4 - yoe / 100 + doy)
        }
    }
    /// In a leap year `y`, the year of the era that holds its 29 February is one before a leap year of the era.
    #[logic(open)]
    #[requires(y.rem_euclid(4) == 0 && (y.rem_euclid(100) != 0 || y.rem_euclid(400) == 0))]
    #[ensures((y - 1).rem_euclid(400) == 399 || (y - 1).rem_euclid(400) + 1 == y.rem_euclid(400))]
    #[ensures({
        let yoe = (y - 1).rem_euclid(400);
        (yoe + 1) % 4 == 0 && ((yoe + 1) % 100 != 0 || yoe == 399)
    })]
    pub fn leap_back(y: Int) {}
    /// A day count splits back into its era and its day of the era.
    #[logic(open)]
    #[requires(0 <= doe && doe <= 146096)]
    #[ensures((era * 146097 + doe).rem_euclid(146097) == doe)]
    #[ensures((era * 146097 + doe).div_euclid(146097) == era)]
    pub fn era_back(era: Int, doe: Int) {}
    /// A day of month `mp` (counted from March as 0) comes back as that month.
    #[logic(open)]
    #[requires(0 <= mp && mp <= 11 && 1 <= d && (153 * mp + 2) / 5 + d - 1 < (153 * (mp + 1) + 2) / 5)]
    #[ensures((5 * ((153 * mp + 2) / 5 + d - 1) + 2) / 153 == mp)]
    pub fn month_back(mp: Int, d: Int) {}
    /// A day of year `yoe` of an era (counted from March) comes back as that year.
    #[logic(open)]
    #[requires(0 <= yoe && yoe <= 399 && 0 <= doy && doy <= 365)]
    #[requires(doy == 365 ==> (yoe + 1) % 4 == 0 && ((yoe + 1) % 100 != 0 || yoe == 399))]
    #[ensures({
        let doe = 365 * yoe + yoe / 4 - yoe / 100 + doy;
        0 <= doe && doe <= 146096 && (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 == yoe
    })]
    pub fn year_back(yoe: Int, doy: Int) {}
    /// `civil::days` in logic: the day count since 1970-01-01 of a civil date.
    #[logic(open)]
    pub fn days(y: Int, m: Int, d: Int) -> Int {
        pearlite! {
            let y = if m <= 2 { y - 1 } else { y };
            let doe = y.rem_euclid(400) * 365 + y.rem_euclid(400) / 4 - y.rem_euclid(400) / 100
                + (153 * ((m + 9) % 12) + 2) / 5 + d - 1;
            y.div_euclid(400) * 146097 + doe - 719468
        }
    }
}

// ASSUMED: the standard library's i64 Euclidean division, as documented. Creusot does not check std.
extern_spec! {
    impl i64 {
        #[check(ghost)]
        #[requires(rhs@ != 0 && !(self@ == i64::MIN@ && rhs@ == -1))]
        #[ensures(result@ == self@.div_euclid(rhs@))]
        fn div_euclid(self, rhs: i64) -> i64;

        #[check(ghost)]
        #[requires(rhs@ != 0 && !(self@ == i64::MIN@ && rhs@ == -1))]
        #[ensures(result@ == self@.rem_euclid(rhs@))]
        fn rem_euclid(self, rhs: i64) -> i64;
    }
}
