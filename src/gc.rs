// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! `gc`. Incomplete installs and day-old staging files go without asking, since nothing can depend on them.
//! Complete capsules beyond the newest `keep` (by install time) are listed first, and removed only after `yes` at a
//! terminal, or with `--yes`. gc touches only names idris2x writes, each under its capsule's lock.

use crate::capsule::meta;
use crate::msg::{advice, clean, out, Advice, R};
use crate::store::{cache, write_failed};
use std::fs::{self, File, TryLockError::WouldBlock};
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// The digest in a name idris2x writes, `<pre><64 hex><post>`, or nothing for any other name.
fn digest(name: &str, pre: &str, post: &str) -> Option<String> {
    let d = name.strip_prefix(pre)?.strip_suffix(post)?;
    let hex = |b: u8| matches!(b, b'0'..=b'9' | b'a'..=b'f');
    (d.len() == 64 && d.bytes().all(hex)).then(|| d.into())
}
/// Remove `p` (a file or a tree) under the lock of capsule `d`. False if an install holds that lock now.
fn remove(c: &Path, d: Option<&str>, p: &Path) -> R<bool> {
    let mut held = None;
    if let Some(d) = d {
        let l = c.join(format!("locks/sha256-{d}.lock"));
        let f = fs::create_dir_all(c.join("locks")).and_then(|()| File::create(&l));
        let f = f.map_err(|e| write_failed("taking the lock", &e, &l))?;
        match f.try_lock() {
            Err(WouldBlock) => return Ok(false),
            r => r.map_err(|e| write_failed("taking the lock", &e.into(), &l))?,
        }
        held = Some(f);
    }
    // `.complete` goes first, so a removal cut short leaves an incomplete entry, never a damaged complete one (I2).
    _ = fs::remove_file(p.join(".complete"));
    let r = match p.is_dir() {
        true => fs::remove_dir_all(p),
        false => fs::remove_file(p),
    };
    drop(held);
    r.map_err(|e| write_failed("removing an old file", &e, p))?;
    Ok(true)
}
fn size(p: &Path) -> u64 {
    match fs::symlink_metadata(p) {
        Ok(m) if m.is_dir() => names(p).iter().map(|n| size(&p.join(n))).sum(),
        m => m.map_or(0, |m| m.len()),
    }
}
fn mb(b: u64) -> String {
    format!("{} MB", (b + 500_000) / 1_000_000)
}
fn names(dir: &Path) -> Vec<String> {
    let all = fs::read_dir(dir).into_iter().flatten().flatten();
    let mut v: Vec<String> = all
        .map(|e| e.file_name().to_string_lossy().into())
        .collect();
    v.sort();
    v
}
fn plural(n: usize) -> String {
    format!("{n} capsule{}", if n == 1 { "" } else { "s" })
}

pub fn gc(keep: usize, dry: bool, yes: bool) -> R<()> {
    let c = cache()?;
    let verb = if dry { "would remove" } else { "removed" };
    let mut text = String::new();
    let mut debris = |what: &str, d: Option<String>, p: PathBuf| -> R<()> {
        if dry || remove(&c, d.as_deref(), &p)? {
            text += &format!("idris2x: {verb} {what} {}\n", p.display());
        }
        Ok(())
    };
    let mut done = vec![];
    for name in names(&c.join("store")) {
        let (Some(d), p) = (digest(&name, "sha256-", ""), c.join("store").join(&name)) else {
            continue;
        };
        match fs::metadata(p.join(".complete")).and_then(|m| m.modified()) {
            Ok(t) => done.push((t, d, p)),
            Err(_) => debris("an incomplete install", Some(d), p)?,
        }
    }
    let day = Duration::from_secs(86_400);
    for name in names(&c.join("staging")) {
        let p = c.join("staging").join(&name);
        let d = digest(&name, "sha256-", ".part").or_else(|| digest(&name, "stage-sha256-", ""));
        let pid = name.strip_prefix("selftest-");
        let ours = d.is_some()
            || name == "fetch.log"
            || pid.is_some_and(|n| n.bytes().all(|b| b.is_ascii_digit()));
        let t = fs::symlink_metadata(&p).and_then(|m| m.modified());
        if ours && t.is_ok_and(|t| t.elapsed().unwrap_or_default() > day) {
            debris("a day-old staging file", d, p)?;
        }
    }
    done.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    let gone = done.split_off(keep.min(done.len()));
    let row = |(_, d, p): &(SystemTime, String, PathBuf)| {
        let iv = meta(p, "idris2");
        let what = match iv.is_empty() {
            true => format!("chez {}", meta(p, "chez")),
            false => format!("idris2 {iv}"),
        };
        format!(
            "    {}  sha256:{}…  {}\n",
            clean(&what),
            &d[..12],
            mb(size(p))
        )
    };
    if gone.is_empty() {
        let n = plural(done.len());
        return out(&format!("{text}idris2x: nothing to remove; keeping {n}\n"));
    }
    let (n, free) = (
        plural(gone.len()),
        mb(gone.iter().map(|g| size(&g.2)).sum()),
    );
    text += &format!("idris2x: would remove {n} and free {free}:\n");
    text.extend(gone.iter().map(row));
    text += &format!("idris2x: keeping {}:\n", plural(done.len()));
    text.extend(done.iter().map(row));
    text.extend(advice(Advice::GcCompiledPrograms {}));
    let ask = !dry && !yes && std::io::stdin().is_terminal();
    let mut answer = String::new();
    if ask {
        out(&format!("{text}Remove {n}? Type yes to continue: "))?;
        text.clear();
        _ = std::io::stdin().read_line(&mut answer);
    }
    if dry || !yes && answer.trim() != "yes" {
        let how = if dry {
            ""
        } else {
            " Pass --yes to remove them."
        };
        return out(&format!("{text}Nothing was removed.{how}\n"));
    }
    let (mut n, mut freed) = (0, 0);
    for (_, d, p) in &gone {
        let b = size(p);
        if remove(&c, Some(d), p)? {
            (n, freed) = (n + 1, freed + b);
        } else {
            text += &format!(
                "idris2x: kept sha256:{}…: an install holds its lock\n",
                &d[..12]
            );
        }
    }
    let (n, freed) = (plural(n), mb(freed));
    out(&format!("{text}idris2x: removed {n} and freed {freed}\n"))
}
