// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! A capsule tree: its capsule.json, the environment it runs in (ADR 0005), and the probes that show it runs.

use crate::msg::{check_version, embedded, host, lock, Checked, Fail, Txt, R};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

/// capsule.json, or null if it cannot be read.
pub fn json(root: &Path) -> serde_json::Value {
    let b = std::fs::read(root.join("capsule.json")).unwrap_or_default();
    serde_json::from_slice(&b).unwrap_or_default()
}
/// A string field of capsule.json, or "" if it is absent.
pub fn meta(root: &Path, key: &str) -> String {
    json(root)[key].as_str().unwrap_or_default().into()
}
/// capsule.json describes the capsule: it names it, gives its Chez Scheme version and, when it has Idris 2, that
/// version too. The versions become a heap path and a probe's expected answer, so they must pass the version check.
pub fn valid(root: &Path) -> bool {
    let j = json(root);
    let version =
        |v: &serde_json::Value| v.as_str().is_some_and(|v| check_version(&lock(v)).is_some());
    let named = j["name"].as_str().is_some_and(|n| !n.is_empty());
    named && version(&j["chez"]) && (j["idris2"].is_null() || version(&j["idris2"]))
}
/// The capsule holds no other Idris 2 than the one the lock pins. A capsule of Chez Scheme only holds none, and is
/// refused later, by `exec` (E-PIN-NOT-FOUND/no-idris2).
pub fn holds(root: &Path, pinned: &Txt<Checked>) -> bool {
    json(root)["idris2"].as_str().is_none_or(|v| pinned == v)
}

fn join(a: String, b: &str) -> String {
    if b.is_empty() {
        a
    } else {
        format!("{a}:{b}")
    }
}
/// The variables the capsule runs with. Inherited library paths are kept only with `inherit`; PATH always is.
pub fn vars(root: &Path, inherit: bool) -> Vec<(&'static str, String)> {
    let (r, get) =
        (root.display(), |k| std::env::var(k).ok().filter(|_| inherit).unwrap_or_default());
    let lib = format!("{r}/bin/idris2_app");
    vec![
        ("IDRIS2X_CAPSULE", r.to_string()),
        ("IDRIS2_PREFIX", r.to_string()),
        ("CHEZ", format!("{r}/bin/scheme")),
        ("SCHEMEHEAPDIRS", format!("{r}/lib/csv{}/%m", meta(root, "chez"))),
        ("IDRIS2_INC_SRC", lib.clone()),
        ("LD_LIBRARY_PATH", join(lib.clone(), &get("LD_LIBRARY_PATH"))),
        ("DYLD_LIBRARY_PATH", join(lib, &get("DYLD_LIBRARY_PATH"))),
        ("PATH", join(format!("{r}/bin"), &std::env::var("PATH").unwrap_or_default())),
    ]
}
/// A variable that changes what code a process loads: Idris 2 and Chez read every IDRIS2_*, DYLD_*,
/// LD_LIBRARY_PATH, CHEZ and SCHEMEHEAPDIRS as a place to load code from, and the dynamic loader loads LD_PRELOAD and
/// LD_AUDIT into every process (ADR 0005).
pub fn code(k: &str) -> bool {
    ["IDRIS2_", "DYLD_"].iter().any(|p| k.starts_with(p))
        || ["LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT", "CHEZ", "SCHEMEHEAPDIRS"].contains(&k)
}
/// Apply the environment contract to `c`. It is a reset: no code variable is inherited unless `inherit`.
pub fn reset(c: &mut Command, root: &Path, inherit: bool) {
    c.env_clear().envs(std::env::vars_os().filter(|(k, _)| inherit || !code(&k.to_string_lossy())));
    c.envs(vars(root, inherit));
}
/// The capsule's Chez with the environment contract applied.
pub fn command(root: &Path, inherit: bool) -> Command {
    let mut c = Command::new(root.join("bin/scheme"));
    reset(&mut c, root, inherit);
    c
}

/// Run the capsule's Chez with `args` and `input`: whether it succeeded, and what it printed, on one line.
fn run(root: &Path, args: &[&str], input: &[u8]) -> (bool, String) {
    let (o, i, e) = (Stdio::piped(), Stdio::piped(), Stdio::piped());
    let child = command(root, false).args(args).stdin(i).stdout(o).stderr(e).spawn();
    let done = child.and_then(|mut ch| {
        _ = ch.stdin.take().map(|mut s| s.write_all(input));
        ch.wait_with_output()
    });
    match done {
        Ok(o) => (
            o.status.success(),
            String::from_utf8_lossy(&[o.stdout, o.stderr].concat())
                .trim_end_matches('\n')
                .replace('\n', " "),
        ),
        Err(e) => (false, e.to_string()),
    }
}
/// The embedded canaries 1 (pure_eval) and 12 (version_match). They run with a reset environment, always.
pub fn probe(root: &Path) -> R<()> {
    let (ok, out) = run(root, &["-q"], b"(display (+ 40 2))");
    if !ok || out != "42" {
        return Err(Fail::ProbeCodegenChezFailed {
            probe: embedded("pure_eval").into(),
            output: host(out).into(),
        });
    }
    let iv = meta(root, "idris2");
    if iv.is_empty() {
        return Ok(());
    }
    let so = format!("{}/bin/idris2_app/idris2.so", root.display());
    match run(root, &["--program", &so, "--version"], b"") {
        (false, out) => Err(Fail::ProbeCodegenIdris2Failed {
            probe: embedded("version_match").into(),
            output: host(out).into(),
        }),
        (_, out) if !out.contains(&format!("version {iv}")) => {
            Err(Fail::ProbeCodegenVersionMismatch { want: lock(iv).into(), got: host(out).into() })
        }
        _ => Ok(()),
    }
}
