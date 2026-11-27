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
    let v = String::from_utf8_lossy(&o.stdout).split_whitespace().nth(1)?.to_owned();
    o.status.success().then_some(v)
}
/// A version as numbers, for ordering: "2.39+git" orders as 2.39, and a run with no leading digit as 0. None if a
/// number is too large to compare, so it is refused, never read as 0.
pub fn runs(v: &str) -> Option<Vec<u64>> {
    let lead = |r: &str| match r.split(|c: char| !c.is_ascii_digit()).next() {
        Some("") | None => Some(0),
        Some(d) => d.parse().ok(),
    };
    v.split('.').map(lead).collect()
}

/// A 0/1 environment switch, off when unset.
pub fn flag(name: &'static str) -> R<bool> {
    let parse = |v: &str| ["0", "1"].contains(&v).then(|| v == "1");
    setting(name, "0 or 1", false, parse)
}
/// The lock's path: IDRIS2X_LOCK, else ./idris2x.lock. idris2x.toml is the file beside it.
pub fn path() -> R<String> {
    setting("IDRIS2X_LOCK", "a file path", "idris2x.lock".into(), |p| Some(p.into()))
}
pub fn toml_path(lock: &str) -> String {
    let p = std::path::Path::new(lock).with_file_name("idris2x.toml");
    p.display().to_string()
}

/// What idris2x.toml says: the Idris 2 version, and the channel's address and key if it names one.
pub struct Toml {
    pub idris2: Txt<Checked>,
    pub channel: Option<(String, String)>,
}
const KEYS: [&str; 3] = ["toolchain.idris2", "channel.url", "channel.key"];
/// Read idris2x.toml beside `lock`, or None if there is none. ADR 0007's strict subset, cut to what is used: [table]
/// headers, key = "string" lines, comments and blank lines, and only the keys in KEYS. Anything else is refused.
pub fn toml(lock: &str) -> R<Option<Toml>> {
    let file = toml_path(lock);
    let bad = |at: String, problem| Fail::PinDriftBadToml {
        file: host(&file).into(),
        at: host(at).into(),
        problem: embedded(problem).into(),
    };
    let text = match std::fs::read_to_string(&file) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        r => r.map_err(|e| bad(format!("reading it: {e}"), "it cannot be read"))?,
    };
    let (mut table, mut got, mut seen) = ("", std::collections::BTreeMap::new(), vec![]);
    for (n, l) in text.lines().enumerate() {
        let end = |r: &str| r.trim().is_empty() || r.trim().starts_with('#');
        let head = l.trim().strip_prefix('[').and_then(|t| t.split_once(']'));
        let head = head.filter(|h| end(h.1));
        table = head.map_or(table, |h| h.0.trim());
        // TOML refuses a table defined twice, even with other keys the second time.
        let twice = head.is_some() && seen.contains(&table);
        seen.extend(head.map(|_| table));
        let pair = l.split_once('=').and_then(|(k, v)| {
            let (v, r) = v.trim().strip_prefix('"')?.split_once('"')?;
            (end(r) && !v.contains('\\')).then(|| (format!("{table}.{}", k.trim()), v))
        });
        let problem = match pair {
            _ if head
                .is_some_and(|h| !KEYS.iter().any(|k| k.split('.').next() == Some(h.0.trim()))) =>
            {
                "it opens a [table] that idris2x does not read"
            }
            _ if twice => "it opens the same [table] twice",
            _ if end(l) || head.is_some() => "",
            Some((k, _)) if !KEYS.contains(&&*k) => "it sets a key that idris2x does not read",
            Some((k, v)) => got.insert(k, v).map_or("", |_| "it sets the same key twice"),
            None => "it is not a [table] header, a key = \"string\" line, a comment or blank",
        };
        if !problem.is_empty() {
            return Err(bad(format!("line {}", n + 1), problem));
        }
    }
    let (get, at) = (|k: &str| got.get(k).map(|v| v.to_string()), || "the end of the file".into());
    let idris2 = get("toolchain.idris2").and_then(|v| check_version(&crate::msg::lock(v)));
    let what = "its [toolchain] idris2 is missing, or is not a version such as 0.8.0";
    let idris2 = idris2.ok_or_else(|| bad(at(), what))?;
    let channel = get("channel.url").zip(get("channel.key"));
    if channel.is_none() && (get("channel.url").is_some() || get("channel.key").is_some()) {
        return Err(bad(at(), "its [channel] table needs both url and key"));
    }
    Ok(Some(Toml { idris2, channel }))
}

/// Read the lock (IDRIS2X_LOCK, else ./idris2x.lock) and find this machine's capsule in it.
pub fn resolve() -> R<Pin> {
    let path = path()?;
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
    // I1: a lock that no longer matches idris2x.toml is refused, never silently used.
    if let Some(toml) = toml(&path)?.filter(|t| t.idris2.shown() != version.shown()) {
        let (toml, locked) = (toml.idris2.into(), version.into());
        return Err(Fail::PinDriftTomlVsLock { toml, locked });
    }
    let c = &v["capsules"][&t];
    if c.is_null() {
        let keys = v["capsules"].as_object().map(|m| m.keys().cloned().collect::<Vec<_>>());
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
        u => u.as_array().and_then(|a| a.iter().map(|u| u.as_str().map(Into::into)).collect()),
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
                return Err(Fail::GlibcFloorUnknown { needs: lock(needs).into(), digest: d() })
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
    Ok(Pin { lock: path, version, digest, size, urls })
}
