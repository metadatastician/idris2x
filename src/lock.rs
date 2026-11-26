// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! idris2x.lock and the one capsule it pins for this machine. Reading it needs no network (ADR 0008).

use crate::msg::{check_digest, check_version, embedded, host, lock, Checked, Fail, Txt, R};
use serde_json::Value;

/// This machine's capsule as the lock pins it. The digest and the version have passed their checks.
pub struct Pin {
    pub lock: String,
    pub version: Txt<Checked>,
    pub digest: String,
    pub size: u64,
    pub urls: Vec<String>,
}

/// An environment setting. Unset or empty gives `default`. A value `parse` refuses, or one that is not Unicode, is
/// E-USAGE, never a default.
pub fn setting<T>(
    name: &'static str,
    what: &'static str,
    default: T,
    parse: fn(&str) -> Option<T>,
) -> R<T> {
    let v = std::env::var_os(name).unwrap_or_default();
    match (v.is_empty(), v.to_str().and_then(parse)) {
        (true, _) => Ok(default),
        (false, Some(t)) => Ok(t),
        (false, None) => Err(Fail::UsageBadSetting {
            variable: embedded(name).into(),
            value: host(v.to_string_lossy()).into(),
            what: embedded(what).into(),
        }),
    }
}
pub fn cwd() -> String {
    std::env::current_dir().map_or(".".into(), |d| d.display().to_string())
}

/// The capsule target this launcher runs on, named as the channel names it.
pub fn target() -> R<String> {
    use std::env::consts::{ARCH, OS};
    if !matches!(ARCH, "x86_64" | "aarch64") {
        let (arch, supported) = (host(ARCH).into(), embedded("x86_64, aarch64").into());
        return Err(Fail::PlatformUnsupportedUnknownArch { arch, supported });
    }
    match OS {
        "linux" => Ok(format!("{ARCH}-unknown-linux-gnu")),
        "macos" => Ok(format!("{ARCH}-apple-darwin")),
        os => Err(Fail::PlatformUnsupportedUnknownOs {
            os: host(os).into(),
            supported: embedded("Linux, macOS").into(),
        }),
    }
}

/// The glibc version of this system, or None if getconf cannot tell (no getconf, or no glibc). getconf gets PATH and
/// nothing else, so an inherited LD_LIBRARY_PATH or LD_PRELOAD cannot make it report another C library than the one
/// the capsule will run with (ADR 0005).
pub fn glibc() -> Option<String> {
    let path = std::env::var_os("PATH").map(|p| ("PATH", p));
    let o = std::process::Command::new("getconf")
        .env_clear()
        .envs(path)
        .arg("GNU_LIBC_VERSION")
        .output()
        .ok()?;
    let v = String::from_utf8_lossy(&o.stdout)
        .split_whitespace()
        .nth(1)?
        .to_owned();
    o.status.success().then_some(v)
}
/// A version as numbers, for ordering: "2.39+git" orders as 2.39, and a run with no leading digit as 0. None if a
/// number is too large to compare, so it is refused, never read as 0.
fn runs(v: &str) -> Option<Vec<u64>> {
    let lead = |r: &str| match r.split(|c: char| !c.is_ascii_digit()).next() {
        Some("") | None => Some(0),
        Some(d) => d.parse().ok(),
    };
    v.split('.').map(lead).collect()
}

/// Read the lock (IDRIS2X_LOCK, else ./idris2x.lock) and find this machine's capsule in it.
pub fn resolve() -> R<Pin> {
    let path = setting("IDRIS2X_LOCK", "a file path", "idris2x.lock".into(), |p| {
        Some(p.into())
    })?;
    let bad = |e: String| Fail::PinNotFoundUnreadableLock {
        problem: lock(e).into(),
        lock: host(&path).into(),
    };
    let text = match std::fs::read_to_string(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(Fail::PinNotFoundNoLock {
                lock: host(&path).into(),
                dir: host(cwd()).into(),
            })
        }
        r => r.map_err(|e| bad(e.to_string()))?,
    };
    let v: Value = serde_json::from_str(&text).map_err(|e| bad(e.to_string()))?;
    match v["schema"].as_u64() {
        Some(1) => {}
        Some(n) if n > 1 => {
            return Err(Fail::ChannelSchemaLockNewer {
                file: host(&path).into(),
                found: lock(n.to_string()).into(),
                supports: embedded("1").into(),
                version: embedded(env!("CARGO_PKG_VERSION")).into(),
            })
        }
        _ => {
            return Err(Fail::PinNotFoundUnreadableLock {
                problem: embedded("its schema field is missing or is not a format number").into(),
                lock: host(&path).into(),
            })
        }
    }
    let t = target()?;
    let malformed = |field: &'static str| Fail::PinNotFoundMalformedLock {
        target: host(&t).into(),
        field: embedded(field).into(),
        lock: host(&path).into(),
    };
    let s = |x: &Value| lock(x.as_str().unwrap_or_default());
    let version =
        check_version(&s(&v["toolchain"]["idris2"])).ok_or_else(|| malformed("version"))?;
    let c = &v["capsules"][&t];
    if c.is_null() {
        let keys = v["capsules"]
            .as_object()
            .map(|m| m.keys().cloned().collect::<Vec<_>>());
        return Err(Fail::PinNotFoundNoTarget {
            target: host(&t).into(),
            covered: lock(keys.unwrap_or_default().join(", ")).into(),
            lock: host(&path).into(),
            version: version.into(),
        });
    }
    let digest = c["sha256"].as_str().unwrap_or_default().to_owned();
    check_digest(&lock(&*digest)).ok_or_else(|| malformed("digest"))?;
    let size = c["size"].as_u64().ok_or_else(|| malformed("size"))?;
    let urls = match &c["urls"] {
        Value::Null => Some(vec![]),
        u => u
            .as_array()
            .and_then(|a| a.iter().map(|u| u.as_str().map(Into::into)).collect()),
    };
    let urls = urls.ok_or_else(|| malformed("mirror list"))?;
    // ADR 0006: refuse a capsule this glibc cannot run, before anything is downloaded.
    if !c["min_glibc"].is_null() {
        let needs = c["min_glibc"].as_str().unwrap_or_default();
        let floor = check_version(&lock(needs))
            .and_then(|_| runs(needs))
            .ok_or_else(|| malformed("glibc floor"))?;
        let d = || lock(format!("sha256:{digest}")).into();
        // Only Linux capsules are built against glibc; there the floor is checked or the pin refused, never skipped.
        // A host version too large to compare is one getconf could not report.
        match glibc().and_then(|h| Some((runs(&h)?, h))) {
            None if cfg!(target_os = "linux") => {
                return Err(Fail::GlibcFloorUnknown {
                    needs: lock(needs).into(),
                    digest: d(),
                })
            }
            Some((r, h)) if r < floor => {
                return Err(Fail::GlibcFloorTooOld {
                    host: host(h).into(),
                    needs: lock(needs).into(),
                    digest: d(),
                })
            }
            _ => {}
        }
    }
    Ok(Pin {
        lock: path,
        version,
        digest,
        size,
        urls,
    })
}
