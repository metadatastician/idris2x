// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! `pin`, the resolver: fetch the channel that idris2x.toml names (or the built-in one), check its signature, version
//! and expiry (ADR 0008), and write idris2x.lock. This is the only module that reads the channel and the only caller
//! of `msg::channel`, so channel text never reaches the executor (ADR 0012).

use crate::lock::{flag, path, runs, setting, toml, toml_path};
use crate::msg::{channel, embedded, host, is_digest, is_version, lock, note, Fail, R};
use crate::net::{doc, logged};
use crate::store::{cache, hex, hold, now, utc, write_failed};
use serde_json::{json, Map, Value};
use std::{fs, io::Write, path::Path};

/// The release channel's address and signify public key. None until the first release is signed, so for now the
/// channel must be named in idris2x.toml. No environment variable can name another key.
const RELEASE: Option<(&str, &str)> = None;
const B64: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard padded base64, or None.
fn b64(s: &str) -> Option<Vec<u8>> {
    let s = s.as_bytes();
    let body = s.strip_suffix(b"==").or(s.strip_suffix(b"=")).unwrap_or(s);
    let mut out = vec![];
    for ch in body.chunks(4) {
        let six = |n: u32, c: &u8| Some(n << 6 | B64.iter().position(|a| a == c)? as u32);
        let n = ch.iter().try_fold(0, six)? << (6 * (4 - ch.len()));
        out.extend_from_slice(&n.to_be_bytes()[1..ch.len()]);
    }
    s.len().is_multiple_of(4).then_some(out)
}
/// signify data: "Ed", an 8-byte key id, then `n` bytes of key or signature, as (key id in hex, bytes). A pre-hashed
/// "ED" signature is refused.
fn signify(text: &str, n: usize) -> Option<(String, Vec<u8>)> {
    let b = b64(text.trim()).filter(|b| b.len() == n + 10 && b.starts_with(b"Ed"))?;
    Some((hex(&b[2..10]), b[10..].to_vec()))
}

/// Is `t` a real time, as RFC 3339 UTC to the second with a four-digit year? Its fields are read as numbers (the
/// days-from-civil algorithm) and the time is written back by `utc`: only a time that comes back the same, byte for
/// byte, passes.
fn real(t: &str) -> bool {
    let n = |a: usize| t.get(a..a + 2).and_then(|d| d.parse::<i64>().ok());
    let f = || {
        // Four digits: a sign or a fifth digit would break the order of the text.
        let (m, y) = (n(5)?, i64::from(t.get(..4)?.parse::<u16>().ok()?));
        let y = y - i64::from(m <= 2);
        let (era, yoe) = (y.div_euclid(400), y.rem_euclid(400));
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + (153 * ((m + 9) % 12) + 2) / 5 + n(8)? - 1;
        let s = (era * 146097 + doe - 719468) * 86400 + n(11)? * 3600 + n(14)? * 60 + n(17)?;
        Some(s)
    };
    f().is_some_and(|s| utc(s) == t)
}

/// Replace `p` whole, by one rename, or leave it as it was (I2).
fn put(p: &Path, b: &[u8]) -> std::io::Result<()> {
    let tmp = p.with_extension(format!("{}.tmp", std::process::id()));
    let w = fs::File::create(&tmp).and_then(|mut f| f.write_all(b).and_then(|()| f.sync_all()));
    w.and_then(|()| fs::rename(&tmp, p)).inspect_err(|_| _ = fs::remove_file(&tmp))
}

/// `idris2x pin <version>`: resolve `ver` through the channel and write idris2x.lock for every target it lists.
pub fn pin(ver: &str) -> R<()> {
    let lf = path()?;
    let wait =
        setting("IDRIS2X_LOCK_TIMEOUT", "a whole number of seconds", 600, |v| v.parse().ok())?;
    let tf = toml_path(&lf);
    let named =
        || R::Ok(toml(&lf)?.and_then(|t| t.channel).or(RELEASE.map(|(u, k)| (u.into(), k.into()))));
    let Some((url, key)) = named()? else {
        return Err(Fail::UsageNoChannel { file: host(&tf).into() });
    };
    let malformed = |what: &'static str, file: String| Fail::SigInvalidMalformed {
        what: embedded(what).into(),
        file: host(file).into(),
    };
    let what = "the key in idris2x.toml is not a signify Ed25519 public key";
    let (kid, pk) = signify(&key, 32).ok_or_else(|| malformed(what, tf.clone()))?;
    let (c, offline, sig_url) = (cache()?, flag("IDRIS2X_OFFLINE")?, format!("{url}.sig"));
    let id = hex(ring::digest::digest(&ring::digest::SHA256, url.as_bytes()).as_ref());
    let (m, log) = (c.join(format!("manifests/{}.sig", &id[..16])), c.join("staging/fetch.log"));
    let at = |p: &Path| p.display().to_string();
    _ = fs::create_dir_all(c.join("staging")).and(fs::create_dir_all(c.join("manifests")));
    // Offline, the manifest is the last copy that passed every check below, kept as one signify file with the body
    // embedded (the signature's two lines, then the body), so the pair is replaced whole or not at all (I2). The copy is
    // written before the lock, so a lock write that fails leaves a checked copy, and an offline pin checks it again.
    // Online each is fetched whole, never resumed, and nothing reaches the cache before every check below has passed.
    let get = |u: &str| {
        doc(u).map_err(|e| {
            logged(&log, &e);
            Fail::NetworkManifestUnreachable {
                url: lock(&url).into(),
                tried: lock(e).into(),
                log: host(at(&log)).into(),
                version: host(ver).into(),
            }
        })
    };
    let (body, sig) = if offline {
        let b = fs::read(&m).map_err(|_| Fail::OfflineNoManifest {
            cache: host(at(&m)).into(),
            mode: embedded("IDRIS2X_OFFLINE=1").into(),
            version: host(ver).into(),
        })?;
        let cut =
            b.iter().enumerate().filter(|c| *c.1 == b'\n').nth(1).map_or(b.len(), |c| c.0 + 1);
        (b[cut..].to_vec(), b[..cut].to_vec())
    } else {
        (get(&url)?, get(&sig_url)?)
    };
    let what = "the signature is not a signify Ed25519 signature; pre-hashed (ED) ones are refused";
    let two: Vec<&str> = std::str::from_utf8(&sig).map_or(vec![], |t| t.lines().take(2).collect());
    let found = two.get(1).and_then(|l| signify(l, 64));
    let (sid, sg) = found.ok_or_else(|| malformed(what, if offline { at(&m) } else { sig_url }))?;
    let key_id = |id: &str| format!("key id {id}");
    if sid != kid {
        return Err(Fail::SigInvalidWrongKey {
            url: lock(&url).into(),
            signer: channel(key_id(&sid)).into(),
            key: lock(key_id(&kid)).into(),
        });
    }
    let ed = ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, &pk);
    ed.verify(&body, &sg).map_err(|_| Fail::SigInvalidBadSignature {
        url: lock(&url).into(),
        key: lock(key_id(&kid)).into(),
        version: host(ver).into(),
    })?;
    // Pins of one lock file take turns, so the rollback check and the new lock are one step. The turn is the lock file's
    // real directory, locked as it is, so every spelling of the path and every cache share it. Only the holder's note is
    // in this cache.
    let p = Path::new(&lf);
    let dir =
        fs::canonicalize(p.parent().filter(|d| *d != Path::new("")).unwrap_or(Path::new(".")));
    let dir = dir.map_err(|e| write_failed("taking the lock", &e, p))?;
    let turn =
        hex(ring::digest::digest(&ring::digest::SHA256, dir.as_os_str().as_encoded_bytes())
            .as_ref());
    _ = fs::create_dir_all(c.join("locks"));
    let (_held, holder) =
        hold(&dir, c.join(format!("locks/pin-{}.holder", &turn[..16])), wait, |_, who| {
            let (seconds, lock, version) =
                (host(wait.to_string()).into(), host(&lf).into(), host(ver).into());
            Fail::LockTimeoutPinHeld { lock, holder: who, seconds, version }
        })?;
    let r = (|| {
        // idris2x.toml is read again in the turn: a pin that waited writes a lock only for the channel and key the project
        // still names (I1).
        let pair = |(u, k): &(String, String)| lock(format!("{u} with key {k}")).into();
        let ours = (url.clone(), key.clone());
        match named()? {
            Some(now) if now == ours => {}
            now => {
                return Err(Fail::PinDriftChannelChanged {
                    checked: pair(&ours),
                    now: now.as_ref().map_or_else(|| embedded("no channel").into(), pair),
                    file: host(&tf).into(),
                    version: host(ver).into(),
                })
            }
        }
        let (new, cv, targets) = resolve(&body, ver, &lf, &url, &kid)?;
        if !offline {
            let kept = [format!("{}\n{}\n", two[0], two[1]).as_bytes(), &body].concat();
            put(&m, &kept).map_err(|e| write_failed("keeping the channel manifest", &e, &m))?;
        }
        let w = put(Path::new(&lf), format!("{new:#}\n").as_bytes());
        w.map_err(|e| write_failed("writing the lock", &e, Path::new(&lf)))?;
        note(&format!("pinned idris2 {ver} (channel v{cv}) into {lf} for: {targets}"));
        Ok(())
    })();
    _ = fs::remove_file(holder);
    r
}

/// The checks on a manifest whose signature verified: format, version, expiry, then the lock for `ver`, with its channel
/// version and targets. Nothing is written.
fn resolve(body: &[u8], ver: &str, lf: &str, url: &str, kid: &str) -> R<(Value, u64, String)> {
    let bad = |field: &'static str| Fail::ChannelSchemaMalformedManifest {
        url: lock(url).into(),
        field: embedded(field).into(),
    };
    let v: Value = serde_json::from_slice(body).map_err(|_| bad("body (it is not JSON)"))?;
    if v["schema"] != 1 {
        return Err(Fail::ChannelSchemaChannelNewer {
            url: lock(url).into(),
            found: channel(v["schema"].to_string()).into(),
            supports: embedded("1").into(),
            version: embedded(env!("CARGO_PKG_VERSION")).into(),
        });
    }
    // A manifest that asks for a newer launcher is refused, never half read (I4).
    let min = match &v["min_launcher"] {
        Value::Null => "0.0",
        m => m.as_str().filter(|m| is_version(m)).ok_or_else(|| bad("min_launcher"))?,
    };
    // is_version keeps each run within 64 bits, so this cannot fail; if it did, the field is refused, never read as 0.
    let needs = runs(min).ok_or_else(|| bad("min_launcher"))?;
    if Some(needs) > runs(env!("CARGO_PKG_VERSION")) {
        return Err(Fail::ChannelSchemaNeedsNewerLauncher {
            url: lock(url).into(),
            needs: channel(min).into(),
            version: embedded(env!("CARGO_PKG_VERSION")).into(),
        });
    }
    let cv = v["channel_version"].as_u64().ok_or_else(|| bad("channel_version"))?;
    // Only versions of the same channel compare: a project that moves to another channel starts from its versions. Only
    // a missing lock is a first pin; a lock that cannot be read, or does not say what it saw, never starts the count again.
    let unknown =
        |problem| Fail::ChannelRollbackSeenVersionUnknown { lock: host(lf).into(), problem };
    let old = match fs::read(lf) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        r => r
            .map_err(|e| e.to_string())
            .and_then(|b| serde_json::from_slice(&b).map(Some).map_err(|e| e.to_string())),
    }
    .map_err(|e| unknown(lock(e).into()))?;
    let ch = old.as_ref().map(|o: &Value| &o["channel"]);
    let (u, n) = (ch.and_then(|c| c["url"].as_str()), ch.and_then(|c| c["version"].as_u64()));
    let seen = match (ch.is_none(), u, n) {
        (true, ..) => 0,
        (_, Some(u), Some(_)) if u != url => 0,
        (_, Some(_), Some(n)) => n,
        _ => {
            let problem = "it does not record its channel's address and a whole-number version";
            return Err(unknown(embedded(problem).into()));
        }
    };
    if cv < seen {
        return Err(Fail::ChannelRollbackVersionWentBack {
            url: lock(url).into(),
            seen: lock(seen.to_string()).into(),
            offered: channel(cv.to_string()).into(),
            version: host(ver).into(),
        });
    }
    // RFC 3339 in UTC to the second, so that the text orders as the time does, and a real time: 2099-99-99 is refused.
    let exp = v["expires"].as_str().unwrap_or_default();
    if !real(exp) {
        return Err(bad("expires"));
    }
    let now = utc(now());
    if exp < now.as_str() && !flag("IDRIS2X_ALLOW_EXPIRED")? {
        return Err(Fail::ChannelExpiredExpired {
            url: lock(url).into(),
            expires: channel(exp).into(),
            now: host(now).into(),
            version: host(ver).into(),
        });
    } else if exp < now.as_str() {
        note("IDRIS2X_ALLOW_EXPIRED=1: using a channel manifest that has expired");
    }
    let k = format!("idris2@{ver}");
    let Some(bundle) = v["bundles"][&k].as_object() else {
        let have = v["bundles"].as_object().into_iter().flat_map(|m| m.keys());
        let have: Vec<_> = have.map(|k| k.trim_start_matches("idris2@")).collect();
        return Err(Fail::PinNotFoundNoVersion {
            lock: host(lf).into(),
            version: host(ver).into(),
            available: channel(have.join(", ")).into(),
        });
    };
    let chez = v["compat"][&k]["chez"].as_str().filter(|c| is_version(c));
    let chez = chez.ok_or_else(|| bad("chez version"))?;
    // Every value copied into the lock passes the check the lock reader applies to it.
    let mut caps = Map::new();
    for (t, c) in bundle {
        let s = |f: &str| c[f].as_str().unwrap_or_default();
        let (urls, glibc) =
            (c["urls"].as_array(), c["min_glibc"].is_null() || is_version(s("min_glibc")));
        let urls = urls.is_some_and(|u| !u.is_empty() && u.iter().all(Value::is_string));
        if !(is_digest(s("sha256")) && c["size"].is_u64() && urls && glibc) {
            return Err(bad("capsule entry"));
        }
        let keep = ["sha256", "size", "urls", "min_glibc"].map(|f| (f.to_owned(), c[f].clone()));
        caps.insert(t.clone(), Value::Object(keep.into_iter().collect()));
    }
    // A deprecated version still pins, with a note: deprecation is announced two quarters before removal. An entry is
    // a bundle name, then optionally ": " and the channel's own words, which are not shown (ADR 0012).
    let dep = v["deprecated"].as_array().filter(|d| d.iter().all(Value::is_string));
    let dep = dep.ok_or_else(|| bad("deprecated"))?.iter().filter_map(Value::as_str);
    if dep.map(|d| d.split([':', ' ']).next()).any(|d| d == Some(&k)) {
        note(&format!("idris2 {ver} is deprecated in this channel. It keeps running from this lock; pin a newer version when you can."));
    }
    let targets = caps.keys().cloned().collect::<Vec<_>>().join(", ");
    let new = json!({"schema": 1, "toolchain": {"idris2": ver, "chez": chez},
        "channel": {"version": cv, "url": url, "key": kid}, "capsules": caps});
    Ok((new, cv, targets))
}
