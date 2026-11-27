// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! Running the pinned toolchain: exec, run, env and selftest. Each needs only idris2x.lock and the capsule, and
//! installs the capsule first if it is missing, as `install --locked` does (ADR 0008).

use crate::capsule::{self, meta};
use crate::msg::{clean, embedded, host, lock, out, shq, Fail, R};
use crate::store::{self, cache, write_failed};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The installed capsule this project's lock pins.
pub fn root() -> R<PathBuf> {
    store::install(&crate::lock::resolve()?, None)
}
fn idris2(root: &Path) -> R<PathBuf> {
    if meta(root, "idris2").is_empty() {
        let name = lock(clean(&meta(root, "name"))).into();
        return Err(Fail::PinNotFoundNoIdris2 { name });
    }
    Ok(root.join("bin/idris2_app/idris2.so"))
}
/// A program on PATH.
pub fn on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path).map(|d| d.join(name)).find(|p| p.is_file())
}

/// `exec`: replace this process with `name` from the capsule's exec map (ADR 0005), then `args`. In the map each word
/// that starts with "-" is passed as it is, and every other word is a path that must stay inside the capsule; the
/// first word is always such a path. `inherit` keeps the code variables.
pub fn exec(name: &str, args: &[String], inherit: bool) -> R<()> {
    let root = root()?;
    let map = capsule::json(&root)["exec"].take();
    let Some(words) = map[name].as_array().filter(|w| !w.is_empty()) else {
        let have = map.as_object().into_iter().flat_map(|m| m.keys());
        let programs = lock(have.cloned().collect::<Vec<_>>().join(", ")).into();
        return Err(Fail::UsageNoSuchProgram { word: host(name).into(), programs });
    };
    let mut argv = vec![];
    for (i, w) in words.iter().enumerate() {
        let bad = || Fail::CapsuleInvalidBadExec {
            program: host(name).into(),
            entry: lock(w.to_string()).into(),
            store: host(root.display().to_string()).into(),
        };
        let s = w.as_str().ok_or_else(bad)?;
        let (opt, path) = (i > 0 && s.starts_with('-'), Path::new(s));
        argv.push(match opt || !s.is_empty() && store::plain(path) {
            true if opt => s.into(),
            true => root.join(path),
            false => return Err(bad()),
        });
    }
    let mut c = Command::new(&argv[0]);
    capsule::reset(&mut c, &root, inherit);
    let detail = host(c.args(&argv[1..]).args(args).exec().to_string()).into();
    let program = host(argv[0].display().to_string()).into();
    Err(Fail::ProbeCodegenCannotStart { program, detail })
}

/// `env`: the variables the toolchain runs with, as shell lines for `eval`, or one JSON object. The text form also
/// unsets each code variable in the shell, so the shell gets the same reset as `exec`.
pub fn env(json: bool) -> R<()> {
    let vars = capsule::vars(&root()?, false);
    if json {
        let m: serde_json::Map<_, _> =
            vars.into_iter().map(|(k, v)| (k.into(), v.into())).collect();
        return out(&format!("{}\n", serde_json::Value::Object(m)));
    }
    let shell = |k: &str| k.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
    let names = std::env::vars_os().map(|(k, _)| k.to_string_lossy().into_owned());
    let mut gone: Vec<String> =
        names.filter(|k| capsule::code(k) && shell(k) && !vars.iter().any(|v| v.0 == k)).collect();
    gone.sort();
    let unset = gone.iter().map(|k| format!("unset {k}\n"));
    let set = vars.iter().map(|(k, v)| format!("export {k}={}\n", shq(v)));
    out(&unset.chain(set).collect::<String>())
}

/// `selftest`: compile a small program, run it, then run it again after moving it, with an empty environment.
pub fn selftest() -> R<()> {
    let root = root()?;
    let so = idris2(&root)?;
    capsule::probe(&root)?; // the last line names pure_eval and version_match, so run them now, not only at install
    let w = cache()?.join(format!("staging/selftest-{}", std::process::id()));
    _ = std::fs::remove_dir_all(&w);
    let made = std::fs::create_dir_all(&w);
    made.map_err(|_| Fail::StoreIoCannotCreate { path: host(w.display().to_string()).into() })?;
    let r = steps(&root, &so, &w);
    _ = std::fs::remove_dir_all(&w);
    r
}
fn steps(root: &Path, so: &Path, w: &Path) -> R<()> {
    let main = "module Main\nmain : IO ()\nmain = putStrLn \"chez_codegen ok\"\n";
    let wrote = std::fs::write(w.join("Main.idr"), main);
    wrote.map_err(|e| write_failed("writing the test program", &e, w))?;
    let spaces = root.to_string_lossy().contains(char::is_whitespace);
    let failed = |probe: &'static str| {
        let (p, store) = (embedded(probe), host(root.display().to_string()).into());
        match spaces {
            true => Fail::ProbeCodegenPathHasSpaces { probe: p.into(), store },
            false => Fail::ProbeCodegenCodegenFailed { probe: p.into(), store },
        }
    };
    let says = |c: &mut Command| {
        let o = c.current_dir(w).stdin(Stdio::null()).output();
        o.is_ok_and(|o| o.status.success() && o.stdout == b"chez_codegen ok\n")
    };
    let compile = |cg: &[&str], name: &str| {
        let mut c = capsule::command(root, false);
        c.arg("--program").arg(so).args(cg).args(["-o", name, "Main.idr"]);
        c.current_dir(w).stdin(Stdio::null()).output().is_ok_and(|o| o.status.success())
    };
    if !compile(&[], "hello") {
        return Err(failed("chez_codegen (compile)"));
    }
    let mut hello = Command::new(w.join("build/exec/hello"));
    capsule::reset(&mut hello, root, false);
    if !says(&mut hello) {
        return Err(failed("chez_codegen (run the compiled program)"));
    }
    let moved = w.join("moved dir/exec");
    let gone = std::fs::create_dir_all(w.join("moved dir"))
        .and_then(|()| std::fs::rename(w.join("build/exec"), &moved));
    let mut clean_env = Command::new(moved.join("hello"));
    if gone.is_err() || !says(clean_env.env_clear().env("PATH", "/usr/bin:/bin")) {
        return Err(failed("relocatable_artifact (run after moving, clean environment)"));
    }
    // RefC needs a C compiler, so it is reported and never decides the exit code, as in the prototype.
    let refc = || {
        compile(&["--cg", "refc"], "hello_refc")
            && says(&mut Command::new(w.join("build/exec/hello_refc")))
    };
    let refc = match on_path("cc") {
        None => "[skip] refc_codegen (no cc on PATH)",
        Some(_) if refc() => "[OK] refc_codegen",
        Some(_) => {
            "[FAIL] refc_codegen (cc is on PATH, and a program built with --cg refc did not run)"
        }
    };
    out(&format!("{refc}\n[OK] pure_eval version_match chez_codegen relocatable_artifact\n"))
}
