// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose).
//! Day counts and civil dates in the proleptic Gregorian calendar (days-from-civil and civil-from-days, H. Hinnant).
//! Pure integer arithmetic. Its contracts are read only by Creusot, through the proof crate in
//! verification/proofs/creusot/, which includes this file and supplies `crate::spec`; a normal build drops them.
#[cfg(creusot)]
use creusot_std::prelude::*;

/// The day count since 1970-01-01 of year `y`, month `m` and day `d`. The fields are not checked: `real` writes the
/// count back as a date and keeps only one that comes back the same.
#[cfg_attr(creusot, requires(0 <= y@ && y@ <= 65535 && -9 <= m@ && m@ <= 99 && -9 <= d@ && d@ <= 99))]
#[cfg_attr(creusot, ensures(result@ == crate::spec::days(y@, m@, d@)))]
pub fn days(y: i64, m: i64, d: i64) -> i64 {
    let y = y - i64::from(m <= 2);
    let (era, yoe) = (y.div_euclid(400), y.rem_euclid(400));
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + (153 * ((m + 9) % 12) + 2) / 5 + d - 1;
    era * 146097 + doe - 719468
}

/// The year, month and day of day `n` since 1970-01-01.
#[cfg_attr(creusot, requires(n@ <= i64::MAX@ - 719468))]
#[cfg_attr(creusot, ensures(crate::spec::valid(result.0@, result.1@, result.2@)))]
#[cfg_attr(creusot, ensures(crate::spec::days(result.0@, result.1@, result.2@) == n@))]
#[cfg_attr(creusot, ensures((result.0@, result.1@, result.2@) == crate::spec::civil(n@)))]
pub fn civil(n: i64) -> (i64, i64, i64) {
    let z = n + 719468;
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let (mp, y) = ((5 * doy + 2) / 153, yoe + z.div_euclid(146097) * 400);
    let (d, m) = (doy - (153 * mp + 2) / 5 + 1, if mp < 10 { mp + 3 } else { mp - 9 });
    (y + i64::from(m <= 2), m, d)
}
