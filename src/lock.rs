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

/// An environment setting. Unset or empty gives `default`. A value `parse` refuses is E-USAGE, never a default.
pub fn setting<T>(
    name: &'static str,
    what: &'static str,
    default: T,
    parse: fn(&str) -> Option<T>,
) -> R<T> {
    match std::env::var(name).unwrap_or_default() {
        v if v.is_empty() => Ok(default),
        v => parse(&v).ok_or_else(|| Fail::UsageBadSetting {
            variable: embedded(name).into(),
            value: host(v).into(),
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

/// The glibc version of this system, or None where there is no glibc (macOS, musl).
fn glibc() -> Option<String> {
    let o = std::process::Command::new("getconf")
        .arg("GNU_LIBC_VERSION")
        .output()
        .ok()?;
    let v = String::from_utf8_lossy(&o.stdout)
        .split_whitespace()
        .nth(1)?
        .to_owned();
    o.status.success().then_some(v)
}
/// A version as numbers, for ordering: "2.39+git" orders as 2.39.
fn runs(v: &str) -> Vec<u64> {
    let lead = |r: &str| r.split(|c: char| !c.is_ascii_digit()).next()?.parse().ok();
    v.split('.').map(|r| lead(r).unwrap_or(0)).collect()
}

/// Read the lock (IDRIS2X_LOCK, else ./idris2x.lock) and find this machine's capsule in it.
pub fn resolve() -> R<Pin> {
    let path = std::env::var("IDRIS2X_LOCK").ok().filter(|p| !p.is_empty());
    let path = path.unwrap_or_else(|| "idris2x.lock".into());
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
    if v["schema"] != 1 {
        return Err(Fail::ChannelSchemaLockNewer {
            file: host(&path).into(),
            found: lock(v["schema"].to_string()).into(),
            supports: embedded("1").into(),
            version: embedded(env!("CARGO_PKG_VERSION")).into(),
        });
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
        check_version(&lock(needs)).ok_or_else(|| malformed("glibc floor"))?;
        if let Some(h) = glibc().filter(|h| runs(h) < runs(needs)) {
            return Err(Fail::GlibcFloorTooOld {
                host: host(h).into(),
                needs: lock(needs).into(),
                digest: lock(format!("sha256:{digest}")).into(),
            });
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
