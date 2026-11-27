// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! The store. A capsule lives at `<cache>/store/sha256-<digest>` and is complete once `.complete` is there.
//! It is written once, under a per-digest lock: download, check the digest, unpack into staging, check the
//! tree, run the probes, then one rename (I2: atomic or absent).

use crate::capsule;
use crate::lock::{setting, Pin};
use crate::msg::{embedded, host, lock, note, Fail, R};
use crate::net::{self, Io, Lost};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};

/// The store's directory: IDRIS2X_CACHE, else $XDG_CACHE_HOME/idris2x, else $HOME/.cache/idris2x. With none of them
/// set there is no store, and the working directory is never taken in its place.
pub fn cache() -> R<PathBuf> {
    let v = |k| std::env::var_os(k).filter(|v| !v.is_empty()).map(PathBuf::from);
    let own = setting("IDRIS2X_CACHE", "a directory", None, |p| Some(Some(p.into())))?;
    own.or_else(|| v("XDG_CACHE_HOME").map(|x| x.join("idris2x")))
        .or_else(|| v("HOME").map(|h| h.join(".cache/idris2x")))
        .ok_or(Fail::StoreIoNoCacheDir {})
}
fn s(p: &Path) -> String {
    p.display().to_string()
}
fn sha(d: &str) -> crate::msg::Fact {
    lock(format!("sha256:{d}")).into()
}

/// Hold `lockfile` for this process, waiting up to `wait` seconds, and record this process in `holder`. A directory is
/// locked as it is; a missing lock file is made. The lock is released when the returned File is dropped or the process
/// ends. On a timeout the failure is `held(lockfile, holder)`, which names a holder only if it can be seen running, and
/// never advises deleting the lock.
pub fn hold(
    lockfile: &Path,
    holder: PathBuf,
    wait: u64,
    held: impl Fn(crate::msg::Fact, crate::msg::Fact) -> Fail,
) -> R<(File, PathBuf)> {
    let f = if lockfile.is_dir() { File::open(lockfile) } else { File::create(lockfile) };
    let f = f.map_err(|e| write_failed("taking the lock", &e, lockfile))?;
    let t0 = std::time::Instant::now();
    loop {
        match f.try_lock() {
            Ok(()) => break,
            Err(fs::TryLockError::WouldBlock) if t0.elapsed().as_secs() < wait => {
                std::thread::sleep(std::time::Duration::from_millis(100))
            }
            Err(fs::TryLockError::Error(e)) => {
                return Err(write_failed("taking the lock", &e, lockfile))
            }
            Err(fs::TryLockError::WouldBlock) => {
                let pid = fs::read_to_string(&holder).unwrap_or_default().trim().to_owned();
                let running = || {
                    std::process::Command::new("kill")
                        .args(["-0", &pid])
                        .stderr(std::process::Stdio::null())
                        .status()
                };
                let seen = !pid.is_empty()
                    && pid.bytes().all(|b| b.is_ascii_digit())
                    && running().is_ok_and(|st| st.success());
                let who = if seen {
                    format!("process {pid} (still running)")
                } else {
                    "unknown (the holder left no record)".into()
                };
                return Err(held(host(s(lockfile)).into(), host(who).into()));
            }
        }
    }
    fs::write(&holder, format!("{}\n", std::process::id()))
        .map_err(|e| write_failed("recording the lock holder", &e, &holder))?;
    Ok((f, holder))
}
/// Bytes as lowercase hexadecimal.
pub fn hex(b: &[u8]) -> String {
    b.iter().map(|b| format!("{b:02x}")).collect()
}
pub fn sha_file(p: &Path) -> io::Result<String> {
    let (mut f, mut b) = (File::open(p)?, vec![0; 1 << 16]);
    let mut c = ring::digest::Context::new(&ring::digest::SHA256);
    loop {
        match f.read(&mut b)? {
            0 => return Ok(hex(c.finish().as_ref())),
            n => c.update(&b[..n]),
        }
    }
}
/// Seconds since 1970 by this machine's clock; a clock before 1970 reads as 0.
pub fn now() -> i64 {
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
    t.map_or(0, |t| t.as_secs().try_into().unwrap_or(i64::MAX))
}
/// A date as RFC 3339 UTC, from seconds since 1970 (the civil-from-days algorithm).
pub fn utc(t: i64) -> String {
    let ((y, m, d), sec) = (crate::civil::civil(t.div_euclid(86400)), t.rem_euclid(86400));
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", sec / 3600, sec / 60 % 60, sec % 60)
}
pub fn write_failed(what: &str, e: &io::Error, at: &Path) -> Fail {
    let why = if e.kind() == io::ErrorKind::FileTooLarge {
        "the file size limit was reached".into()
    } else {
        e.to_string()
    };
    Fail::StoreIoWriteFailed {
        detail: host(format!("{what} ({why})")).into(),
        path: host(s(at)).into(),
    }
}

/// Download this machine's capsule to `out` and check its digest. `what` and `at` name the place on a disk failure.
fn download(pin: &Pin, out: &Path, what: &str, at: &Path) -> R<()> {
    let stall = setting("IDRIS2X_NET_TIMEOUT", "a whole number of seconds, at least 1", 30, |v| {
        v.parse().ok().filter(|&n| n > 0)
    })?;
    let log = cache()?.join("staging/fetch.log");
    if pin.urls.is_empty() {
        let (digest, lock, version) =
            (sha(&pin.digest), host(&pin.lock).into(), pin.version.clone().into());
        return Err(Fail::PinNotFoundNoUrls { digest, lock, version });
    }
    let stall = std::time::Duration::from_secs(stall);
    let url = net::fetch(out, &pin.urls, pin.size, &log, stall).map_err(|e| {
        _ = fs::remove_file(out);
        match e {
            Lost::Disk(e) => write_failed(what, &e, at),
            Lost::Net(t) => Fail::NetworkAllMirrorsFailed {
                digest: sha(&pin.digest),
                tried: lock(t).into(),
                log: host(s(&log)).into(),
            },
        }
    })?;
    checked(pin, out, Some(url))
}
/// The file at `p` has the pinned digest. A download that does not is deleted; a bundle (`url` None) is kept.
fn checked(pin: &Pin, p: &Path, url: Option<String>) -> R<()> {
    let got = sha_file(p).map_err(|e| write_failed("reading the capsule", &e, p))?;
    if got == pin.digest {
        return Ok(());
    }
    let n = fs::metadata(p).map_or(0, |m| m.len());
    let (want, got) = (sha(&pin.digest), host(format!("sha256:{got}")).into());
    let (bytes, lock_) =
        (lock(format!("{n} bytes (the lock says {})", pin.size)).into(), host(&pin.lock).into());
    Err(match url {
        None => {
            Fail::HashMismatchBundle { want, got, bytes, source: host(s(p)).into(), lock: lock_ }
        }
        Some(u) => {
            _ = fs::remove_file(p);
            Fail::HashMismatchDownload { want, got, bytes, source: lock(u).into(), lock: lock_ }
        }
    })
}

/// Install this machine's capsule unless it is there already, and return its store path.
pub fn install(pin: &Pin, from: Option<&Path>) -> R<PathBuf> {
    let wait =
        setting("IDRIS2X_LOCK_TIMEOUT", "a whole number of seconds", 600, |v| v.parse().ok())?;
    let offline = crate::lock::flag("IDRIS2X_OFFLINE")?;
    let (c, d) = (cache()?, &pin.digest);
    let dir = c.join(format!("store/sha256-{d}"));
    if dir.join(".complete").is_file() {
        return cached(pin, dir);
    }
    for sub in ["locks", "staging", "store"] {
        fs::create_dir_all(c.join(sub))
            .map_err(|_| Fail::StoreIoCannotCreate { path: host(s(&c)).into() })?;
    }
    let (_held, holder) = hold(
        &c.join(format!("locks/sha256-{d}.lock")),
        c.join(format!("locks/sha256-{d}.holder")),
        wait,
        |at, who| Fail::LockTimeoutHeld {
            digest: sha(d),
            seconds: host(wait.to_string()).into(),
            lockfile: at,
            holder: who,
        },
    )?;
    // Another process may have finished while this one waited.
    let done = dir.join(".complete").is_file();
    let r = if done { cached(pin, dir) } else { fill(pin, from, offline, &c, dir) };
    _ = fs::remove_file(&holder);
    r
}
/// A finished entry is reused only for the pin that installed it: the digest must still name the version in the lock.
fn cached(pin: &Pin, dir: PathBuf) -> R<PathBuf> {
    match capsule::holds(&dir, &pin.version) {
        true => Ok(dir),
        false => Err(Fail::CapsuleInvalidPinMismatch {
            digest: sha(&pin.digest),
            version: pin.version.clone().into(),
            found: lock(capsule::meta(&dir, "idris2")).into(),
        }),
    }
}
/// The work under the lock: get the archive, unpack and check it in staging, then rename it into the store.
fn fill(pin: &Pin, from: Option<&Path>, offline: bool, c: &Path, dir: PathBuf) -> R<PathBuf> {
    let d = &pin.digest;
    let tgz = from.map_or_else(|| c.join(format!("staging/sha256-{d}.part")), Path::to_path_buf);
    if from.is_some() {
        checked(pin, &tgz, None)?;
    } else if offline {
        let (store, mode, lock) = (
            host(s(&c.join("store"))).into(),
            embedded("IDRIS2X_OFFLINE=1").into(),
            host(&pin.lock).into(),
        );
        return Err(Fail::OfflineCapsuleMissing { digest: sha(d), store, mode, lock });
    } else {
        if fs::metadata(&tgz).is_ok_and(|m| m.len() >= pin.size) {
            _ = fs::remove_file(&tgz); // a part that is not shorter than the capsule cannot be resumed
        }
        download(pin, &tgz, "downloading the capsule", c)?;
    }
    let stage = c.join(format!("staging/stage-sha256-{d}"));
    _ = fs::remove_dir_all(&stage);
    fs::create_dir(&stage)
        .map_err(|_| Fail::StoreIoCannotCreate { path: host(s(&stage)).into() })?;
    let unpacked = match unpack(&tgz, &stage) {
        Ok(()) if !stage.join("capsule.json").is_file() => {
            Err(Fail::CapsuleInvalidNoMetadata { digest: sha(d) })
        }
        Ok(()) if !sums(&stage) => Err(Fail::CapsuleInvalidTreeMismatch { digest: sha(d) }),
        Ok(()) if !capsule::valid(&stage) => {
            Err(Fail::CapsuleInvalidBadMetadata { digest: sha(d) })
        }
        Ok(()) if !capsule::holds(&stage, &pin.version) => Err(Fail::CapsuleInvalidPinMismatch {
            digest: sha(d),
            version: pin.version.clone().into(),
            found: lock(capsule::meta(&stage, "idris2")).into(),
        }),
        Ok(()) => capsule::probe(&stage),
        Err(Bad::Unsafe) => Err(Fail::CapsuleInvalidUnsafePath { digest: sha(d) }),
        // The archive matched its digest and still cannot be read: it is not a capsule.
        Err(Bad::Archive) => Err(Fail::CapsuleInvalidNoMetadata { digest: sha(d) }),
        Err(Bad::Disk(e)) => Err(write_failed("unpacking the capsule", &e, c)),
    };
    if from.is_none() {
        _ = fs::remove_file(&tgz);
    }
    let moved = unpacked.and_then(|()| {
        _ = fs::remove_dir_all(&dir); // a store entry without .complete is garbage by definition
        fs::rename(&stage, &dir)
            .map_err(|_| Fail::StoreIoRenameFailed { path: host(s(&dir)).into() })
    });
    if let Err(f) = moved {
        _ = fs::remove_dir_all(&stage);
        return Err(f);
    }
    let done = dir.join(".complete");
    let wrote = fs::write(&done, format!("sha256:{d} {}\n", utc(now())))
        .and_then(|()| File::open(&done)?.sync_all());
    wrote.map_err(|e| write_failed("marking the capsule complete", &e, &dir))?;
    _ = File::open(&dir).and_then(|f| f.sync_all());
    Ok(dir)
}

/// `idris2x verify`: the installed capsule still matches its checksum list, and its probes pass.
pub fn verify(pin: &Pin) -> R<()> {
    let dir = cache()?.join(format!("store/sha256-{}", pin.digest));
    if !dir.join(".complete").is_file() {
        return Err(Fail::PinNotFoundNotInstalled { digest: sha(&pin.digest) });
    }
    // capsule.json is read again: the entry must still describe what the lock pins, whichever launcher installed it.
    if !sums(&dir) || !capsule::valid(&dir) || !capsule::holds(&dir, &pin.version) {
        return Err(Fail::HashMismatchStoreModified {
            digest: sha(&pin.digest),
            dir: host(s(&dir)).into(),
        });
    }
    capsule::probe(&dir)?;
    note(&format!("OK sha256:{} verified ({})", pin.digest, capsule::meta(&dir, "name")));
    Ok(())
}
/// `idris2x fetch -o FILE`: download the capsule for an air-gapped host, which installs it with --from.
pub fn bundle(pin: &Pin, out: &Path) -> R<()> {
    let c = cache()?;
    fs::create_dir_all(c.join("staging"))
        .map_err(|_| Fail::StoreIoCannotCreate { path: host(s(&c)).into() })?;
    let part = PathBuf::from(format!("{}.part", s(out)));
    download(pin, &part, "writing the bundle", out.parent().unwrap_or(Path::new(".")))?;
    fs::rename(&part, out).map_err(|e| write_failed("writing the bundle", &e, out))?;
    let (d, n, l) = (&pin.digest, pin.size, &pin.lock);
    note(&format!(
        "fetched sha256:{d} -> {} ({n} bytes); copy it with {l} to the air-gapped host",
        s(out)
    ));
    Ok(())
}

/// Every line of sha256sums.txt names a file inside the tree whose digest matches, and one of them is capsule.json.
pub fn sums(dir: &Path) -> bool {
    let list = fs::read_to_string(dir.join("sha256sums.txt")).unwrap_or_default();
    let ok = |l: &str| {
        l.split_once("  ").is_some_and(|(h, p)| {
            plain(Path::new(p)) && sha_file(&dir.join(p)).is_ok_and(|g| g == h)
        })
    };
    // capsule.json says what the capsule is, so the list must cover it, as the factory's list does.
    let meta = |l: &str| {
        l.split_once("  ").is_some_and(|(_, p)| p.trim_start_matches("./") == "capsule.json")
    };
    list.lines().any(meta) && list.lines().all(ok)
}

enum Bad {
    Unsafe,
    Archive,
    Disk(io::Error),
}
/// A member name made only of plain components: not absolute, no `..`.
pub fn plain(p: &Path) -> bool {
    p.components().all(|c| matches!(c, Component::Normal(_) | Component::CurDir))
}
/// Walking `p` from the archive root never climbs above it.
fn inside(p: &Path) -> bool {
    let mut depth = 0;
    p.components().all(|c| {
        depth += match c {
            Component::Normal(_) => 1,
            Component::CurDir => 0,
            Component::ParentDir => -1,
            _ => return false,
        };
        depth >= 0
    })
}
/// Create the parents of `name` in `stage`, refusing to pass through anything but a real directory, so that no
/// write can follow a link out of the tree.
fn parents(stage: &Path, name: &Path) -> Result<(), Bad> {
    let mut p = stage.to_path_buf();
    for c in name.parent().into_iter().flat_map(Path::components) {
        p.push(c);
        match fs::symlink_metadata(&p) {
            Ok(m) if m.is_dir() => {}
            Ok(_) => return Err(Bad::Unsafe),
            Err(_) => fs::create_dir(&p).map_err(Bad::Disk)?,
        }
    }
    Ok(())
}
/// Unpack with our own containment checks (tar parses the headers only). Refused: absolute names, `..`,
/// setuid or setgid bits, devices and other special files, a member over an existing one, a hard link to anything
/// but a file in the tree, and a symbolic link that resolves outside the tree, even through another link.
fn unpack(tgz: &Path, stage: &Path) -> Result<(), Bad> {
    use std::os::unix::fs::{symlink, OpenOptionsExt};
    let mut a =
        tar::Archive::new(flate2::read::GzDecoder::new(File::open(tgz).map_err(Bad::Disk)?));
    let (root, mut links) = (fs::canonicalize(stage).map_err(Bad::Disk)?, vec![]);
    let within = |p: &Path| fs::canonicalize(p).is_ok_and(|p| p.starts_with(&root));
    for e in a.entries().map_err(|_| Bad::Archive)? {
        let mut e = e.map_err(|_| Bad::Archive)?;
        let (kind, mode) = (e.header().entry_type(), e.header().mode().map_err(|_| Bad::Archive)?);
        let name = e.path().map_err(|_| Bad::Archive)?.into_owned();
        let link = e.link_name().map_err(|_| Bad::Archive)?.map(|l| l.into_owned());
        let to = stage.join(&name);
        let there = fs::symlink_metadata(&to);
        let clash = there.as_ref().is_ok_and(|m| !(kind.is_dir() && m.is_dir()));
        if !plain(&name) || mode & 0o6000 != 0 || clash {
            return Err(Bad::Unsafe);
        }
        parents(stage, &name)?;
        match (kind, link) {
            (k, _) if k.is_dir() => {
                there.is_ok() || fs::create_dir(&to).map_err(Bad::Disk).map(|()| true)?
            }
            (k, _) if k.is_file() => {
                let mut f = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(mode & 0o777)
                    .open(&to)
                    .map_err(Bad::Disk)?;
                net::pump(&mut e, &mut f).map_err(|e| match e {
                    Io::Read(_) => Bad::Archive,
                    Io::Write(e) => Bad::Disk(e),
                })?;
                true
            }
            (k, Some(l))
                if k.is_symlink() && inside(&name.parent().unwrap_or(Path::new("")).join(&l)) =>
            {
                symlink(&l, &to).map_err(Bad::Disk)?;
                links.push(to);
                true
            }
            (k, Some(l)) if k.is_hard_link() && plain(&l) && within(&stage.join(&l)) => {
                // A link to anything but a file is unsafe; a link that cannot be written is a disk failure.
                let file = fs::symlink_metadata(stage.join(&l)).is_ok_and(|m| m.is_file());
                if file {
                    fs::hard_link(stage.join(&l), &to).map_err(Bad::Disk)?;
                }
                file
            }
            (tar::EntryType::XGlobalHeader, _) => true, // pax metadata for the whole archive; nothing to write
            _ => false,
        }
        .then_some(())
        .ok_or(Bad::Unsafe)?;
    }
    links.iter().all(|l| within(l)).then_some(()).ok_or(Bad::Unsafe)
}
