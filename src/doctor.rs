// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! `doctor`: one line per check on this machine, the lock and the installed capsule, then the notes. It changes
//! nothing. Nothing leaves the machine except the mirror check, one HEAD request per mirror, which `--offline` skips.

use crate::capsule::{self, meta};
use crate::msg::{advice, brief, clean, host, out, Advice, Fail, R};
use crate::{lock, net, run, store};
use std::path::{Path, PathBuf};

type Line = (&'static str, &'static str, String);

/// Whether the store directory takes a new file and a lock on it. The file is removed again.
fn store_line(c: &Path) -> (&'static str, String) {
    let c_ = c.display();
    if !c.is_dir() {
        return ("info", format!("{c_} does not exist yet; the first install creates it"));
    }
    let p = c.join(format!(".doctor-{}", std::process::id()));
    let r = std::fs::File::create(&p).and_then(|f| f.try_lock().map_err(std::io::Error::from));
    _ = std::fs::remove_file(&p);
    match r {
        Ok(()) => ("ok", format!("{c_} is writable and locks work")),
        Err(e) => ("problem", format!("{c_} cannot be written or locked ({e}) -> E-STORE-IO")),
    }
}

/// The lock's capsule: installed and intact, its probes, and each mirror. Returns whether a request left the machine.
fn pin_lines(
    pin: &lock::Pin,
    cache: Option<&Path>,
    offline: bool,
    lines: &mut Vec<Line>,
    notes: &mut Vec<String>,
) -> bool {
    let mut say = |s: &'static str, c: &'static str, t: String| lines.push((s, c, t));
    let v = pin.version.shown();
    let t = format!("{} pins idris2 {v} for this machine", pin.lock);
    say("ok", "lock", t);
    let dir = cache.map_or_else(PathBuf::new, |c| c.join(format!("store/sha256-{}", pin.digest)));
    let short = format!("sha256:{}…", &pin.digest[..12]);
    if cache.is_none() {
        say("skip", "capsule", "not checked: the store cannot be found".into());
    } else if !dir.join(".complete").is_file() {
        let t = format!("{short} is not installed yet; idris2x install installs it");
        say("info", "capsule", t);
    } else if !store::sums(&dir) {
        let digest = crate::msg::lock(format!("sha256:{}", pin.digest)).into();
        let dir = host(dir.display().to_string()).into();
        say("problem", "capsule", brief(&Fail::HashMismatchStoreModified { digest, dir }));
    } else {
        say("ok", "capsule", format!("{short} is installed and matches its checksums"));
        let iv = meta(&dir, "idris2");
        let (s, t) = match capsule::probe(&dir) {
            Err(f) => ("problem", brief(&f)),
            Ok(()) if iv.is_empty() => ("ok", "Chez evaluates; this capsule has no Idris 2".into()),
            Ok(()) => ("ok", format!("Chez evaluates, Idris 2 reports {iv}")),
        };
        say(s, "probes", t);
    }
    if let Some(lsp) = run::on_path("idris2-lsp") {
        let mut c = std::process::Command::new(lsp);
        let o = c.arg("--version").stdin(std::process::Stdio::null()).output();
        if !o.is_ok_and(|o| String::from_utf8_lossy(&[o.stdout, o.stderr].concat()).contains(v)) {
            let pinned = pin.version.clone().into();
            notes.extend(advice(Advice::LspMismatch { pinned }));
        }
    }
    if offline {
        say("skip", "mirror", "not checked: offline".into());
        return false;
    }
    for u in &pin.urls {
        let host = u.split("://").nth(1).and_then(|r| r.split('/').next());
        let name = host.unwrap_or(u);
        let (s, t) = match net::head(u) {
            Ok(ms) => ("ok", format!("{name} answered in {ms} ms")),
            Err(e) => ("problem", format!("{name} did not answer ({e}) -> E-NETWORK")),
        };
        say(s, "mirror", t);
    }
    !pin.urls.is_empty()
}

pub fn doctor(json: bool, offline: bool) -> R<()> {
    let cache = store::cache();
    let (s, t) = match &cache {
        Ok(c) => store_line(c),
        Err(f) => ("problem", brief(f)),
    };
    let (mut lines, mut notes, mut sent) = (vec![(s, "store", t)], vec![], false);
    // An IDRIS2X_OFFLINE that cannot be read is a problem, and doctor then sends nothing.
    let offline = lock::flag("IDRIS2X_OFFLINE").unwrap_or_else(|f| {
        lines.push(("problem", "setting", brief(&f)));
        true
    }) || offline;
    let target = lock::target();
    match (&target, lock::resolve()) {
        (Err(f), _) => lines.push(("problem", "platform", brief(f))),
        // Outside a project there is no lock, and that is not a fault of this machine.
        (_, Err(f @ Fail::PinNotFoundNoLock { .. })) => lines.push(("info", "lock", brief(&f))),
        (_, Err(f)) => lines.push(("problem", "lock", brief(&f))),
        (_, Ok(pin)) => {
            let c = cache.as_deref().ok();
            sent = pin_lines(&pin, c, offline, &mut lines, &mut notes);
        }
    }
    let os = format!("{}-{}", std::env::consts::ARCH, std::env::consts::OS);
    let target = target.unwrap_or(os);
    let code = |k: &std::ffi::OsString| capsule::code(&k.to_string_lossy());
    let env = std::env::vars_os().filter(|(k, v)| code(k) && !v.is_empty());
    let mut set: Vec<String> = env.map(|(k, _)| k.to_string_lossy().into()).collect();
    set.sort();
    if !set.is_empty() {
        let names = host(set.join(", ")).into();
        notes.extend(advice(Advice::EnvIgnored { names }));
    }
    let lines: Vec<Line> = lines.into_iter().map(|(s, c, t)| (s, c, clean(&t))).collect();
    let problems = lines.iter().filter(|l| l.0 == "problem").count();
    let glibc = lock::glibc();
    if json {
        let check = |(s, c, t): &Line| serde_json::json!({"status": s, "check": c, "text": t});
        let checks: Vec<_> = lines.iter().map(check).collect();
        let j = serde_json::json!({"schema": 1, "tool": "idris2x", "version": env!("CARGO_PKG_VERSION"),
            "target": target, "glibc": glibc, "checks": checks, "notes": notes, "problems": problems,
            "changed": false, "network": sent});
        return out(&format!("{j}\n"));
    }
    let n = |k: usize, w: &str| format!("{k} {w}{}", if k == 1 { "" } else { "s" });
    let (p, k) = (n(problems, "problem"), n(notes.len(), "note"));
    let glibc = glibc.map(|g| format!(" (glibc {})", clean(&g)));
    let row = |(s, c, t): &Line| format!("{s:<8}{c}: {t}\n");
    let (rows, glibc): (String, _) = (lines.iter().map(row).collect(), glibc.unwrap_or_default());
    let left = if sent { " except the mirror check" } else { "" };
    let (about, notes) = (crate::about(), notes.concat());
    let end = format!("{p}, {k}. Nothing was changed. No data left this machine{left}.\n");
    out(&format!("{about} on {target}{glibc}\n\n{rows}{notes}\n{end}"))
}
