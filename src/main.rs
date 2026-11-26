// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
#![forbid(unsafe_code)]

use idris2x::msg::{self, embedded, host, Fail, R};
use idris2x::{doctor, gc, lock, pin, run, store};
use std::path::Path;

/// The commands this build has, as `usage|description`, for `help` and the usage messages. A command joins this list
/// in the milestone that builds it, so the binary never offers what it lacks.
const USAGE: [&str; 11] = [
    "idris2x pin <version>|resolve a version through the channel and write idris2x.lock",
    "idris2x install [--locked] [--from <bundle>]|fetch, check and store the pinned capsule",
    "idris2x exec [--locked] [--inherit-env] [--] <program> <args>|run a program of the pinned capsule, such as idris2",
    "idris2x run [--locked] [--inherit-env] [--] <chez args>|run the pinned Chez Scheme, as exec -- chez does",
    "idris2x env [--json]|print the environment the toolchain runs in",
    "idris2x verify|re-check the installed capsule",
    "idris2x gc [--keep-last <n>] [--dry-run] [--yes]|remove old capsules",
    "idris2x fetch -o <bundle>|download the pinned capsule to a file",
    "idris2x doctor [--json] [--offline]|report on this machine and project",
    "idris2x selftest|compile and run a test program",
    "idris2x explain [<id>]|describe an error id",
];
const COMMANDS: &str =
    "pin, install, exec, run, env, verify, gc, fetch, doctor, selftest, explain, help";

/// The usage line of `command`.
fn usage(command: &str) -> &'static str {
    let u = USAGE.iter().find(|u| u.split(' ').nth(1) == Some(command));
    u.and_then(|u| u.split('|').next()).unwrap_or("idris2x help")
}
/// The usage error for a missing value: `what` names it.
fn missing(command: &'static str, what: &'static str) -> Fail {
    let (usage, what) = (embedded(usage(command)).into(), embedded(what).into());
    Fail::UsageMissingArgument { usage, command: embedded(command).into(), what }
}
/// The flags after `command`, as (flag, value). `spec` lists each flag the command takes; a flag that takes a value
/// says what the value is, for the message when it is missing.
fn flags(
    rest: &[String],
    command: &'static str,
    spec: &[(&str, Option<&'static str>)],
) -> R<Vec<(String, String)>> {
    let (mut it, mut got) = (rest.iter(), vec![]);
    while let Some(w) = it.next() {
        let v = match spec.iter().find(|f| f.0 == w) {
            Some((_, None)) => String::new(),
            Some((_, Some(what))) => it.next().ok_or_else(|| missing(command, what))?.clone(),
            None => {
                let (word, usage) = (host(w).into(), embedded(usage(command)).into());
                let command = embedded(command).into();
                return Err(Fail::UsageUnknownFlag { word, usage, command });
            }
        };
        got.push((w.clone(), v));
    }
    Ok(got)
}
/// The value of `flag`, the last one given.
fn get<'a>(got: &'a [(String, String)], flag: &str) -> Option<&'a str> {
    got.iter().rev().find(|p| p.0 == flag).map(|p| p.1.as_str())
}

fn run(args: &[String]) -> R<()> {
    let rest = args.get(1..).unwrap_or_default();
    match args.first().map(String::as_str) {
        Some("pin") => {
            let v = rest.first().ok_or_else(|| missing("pin", "a version to pin"))?;
            flags(&rest[1..], "pin", &[])?;
            pin::pin(v)
        }
        Some("install") => {
            let spec = [("--locked", None), ("--from", Some("a bundle file, after --from"))];
            let got = flags(rest, "install", &spec)?;
            let from = get(&got, "--from");
            let pin = lock::resolve()?;
            if let Some(f) = from.filter(|f| !Path::new(f).is_file()) {
                let (path, dir) = (host(f).into(), host(lock::cwd()).into());
                return Err(Fail::UsageNoSuchFile { path, dir });
            }
            let dir = store::install(&pin, from.map(Path::new))?;
            msg::out(&format!("{}\n", dir.display()))
        }
        Some(c @ ("exec" | "run")) => {
            // The launcher's own flags come first. From the first other word, or after a `--`, every word is the
            // program's, so `run --script a.ss` reaches Chez. `--locked` changes nothing: exec never reads the channel.
            let n = rest
                .iter()
                .take_while(|w| ["--locked", "--inherit-env"].contains(&w.as_str()))
                .count();
            let inherit = rest[..n].iter().any(|w| w == "--inherit-env");
            let words = &rest[n + rest.get(n).is_some_and(|w| w == "--") as usize..];
            let what = "a program from the capsule, such as idris2";
            let (name, args) = match (c, words.split_first()) {
                ("run", _) => ("chez", words),
                (_, Some((p, a))) => (p.as_str(), a),
                _ => return Err(missing("exec", what)),
            };
            run::exec(name, args, inherit)
        }
        Some("env") => run::env(get(&flags(rest, "env", &[("--json", None)])?, "--json").is_some()),
        Some("verify") => {
            flags(rest, "verify", &[])?;
            store::verify(&lock::resolve()?)
        }
        Some("gc") => {
            let what = "a whole number, after --keep-last";
            let spec = [("--keep-last", Some(what)), ("--dry-run", None), ("--yes", None)];
            let got = flags(rest, "gc", &spec)?;
            let keep = get(&got, "--keep-last").map_or(Some(3), |k| k.parse().ok());
            let (dry, yes) = (get(&got, "--dry-run").is_some(), get(&got, "--yes").is_some());
            gc::gc(keep.ok_or_else(|| missing("gc", what))?, dry, yes)
        }
        Some("fetch") => {
            let what = "a file to write, after -o";
            let got = flags(rest, "fetch", &[("-o", Some(what))])?;
            let out = get(&got, "-o").ok_or_else(|| missing("fetch", what))?;
            store::bundle(&lock::resolve()?, Path::new(out))
        }
        Some("doctor") => {
            let got = flags(rest, "doctor", &[("--json", None), ("--offline", None)])?;
            let (json, offline) = (get(&got, "--json").is_some(), get(&got, "--offline").is_some());
            doctor::doctor(json, offline)
        }
        Some("selftest") => {
            flags(rest, "selftest", &[])?;
            run::selftest()
        }
        Some("explain") => msg::explain(args.get(1).map(String::as_str)),
        Some("__render") => msg::render_hook(rest),
        Some("version" | "--version") => msg::out(&format!("{}\n", idris2x::about())),
        Some("help" | "--help" | "-h") => {
            let row = |u: &&str| u[8..].split_once('|').map(|(c, d)| format!("  {c:<40} {d}\n"));
            let rows: String = USAGE.iter().filter_map(row).collect();
            msg::out(&format!("usage: idris2x <command>\n{rows}"))
        }
        w => Err(Fail::UsageUnknownCommand {
            word: host(w.unwrap_or("(nothing)")).into(),
            commands: embedded(COMMANDS).into(),
        }),
    }
}

fn main() {
    // A panic is a launcher bug: report it as E-INTERNAL (exit 70), naming only where it happened.
    std::panic::set_hook(Box::new(|info| {
        let at = info
            .location()
            .map_or("an unknown place".into(), |l| format!("{}:{}", l.file(), l.line()));
        msg::fail(Fail::InternalBug {
            detail: host(format!("panic at {at}")).into(),
            version: embedded(env!("CARGO_PKG_VERSION")).into(),
        })
    }));
    // Past a file size limit (ulimit -f) a write must fail with EFBIG and be reported, not kill the
    // launcher silently. A caught signal is reset to its default in a child at exec.
    if let Err(e) =
        signal_hook::flag::register(signal_hook::consts::SIGXFSZ, std::sync::Arc::default())
    {
        msg::fail(msg::bug(format!("cannot catch SIGXFSZ ({e})")))
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Err(f) = run(&args) {
        msg::fail(f)
    }
}
