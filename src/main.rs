// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
#![forbid(unsafe_code)]

use idris2x::msg::{self, embedded, host, Fail, R};
use idris2x::{lock, store};
use std::path::Path;

/// The commands this build has, for `help` and for the unknown-command message. A command
/// joins this list in the milestone that builds it, so the binary never offers what it lacks.
const USAGE: [(&str, &str); 4] = [
    (
        "install [--locked] [--from <bundle>]",
        "fetch, check and store the pinned capsule",
    ),
    ("verify", "re-check the installed capsule"),
    ("fetch -o <bundle>", "download the pinned capsule to a file"),
    ("explain [<id>]", "describe an error id"),
];
const COMMANDS: &str = "install, verify, fetch, explain, help";

/// The words after `command`: `--locked` (install only), and `flag` with its value.
fn flag(
    rest: &[String],
    command: &'static str,
    usage: &'static str,
    flag: Option<&str>,
    what: &'static str,
) -> R<Option<String>> {
    let missing = || Fail::UsageMissingArgument {
        usage: embedded(usage).into(),
        command: embedded(command).into(),
        what: embedded(what).into(),
    };
    let (mut it, mut value) = (rest.iter(), None);
    while let Some(w) = it.next() {
        match w.as_str() {
            "--locked" if command == "install" => {}
            f if Some(f) == flag => value = Some(it.next().ok_or_else(missing)?.clone()),
            w => {
                let (word, usage, command) = (
                    host(w).into(),
                    embedded(usage).into(),
                    embedded(command).into(),
                );
                return Err(Fail::UsageUnknownFlag {
                    word,
                    usage,
                    command,
                });
            }
        }
    }
    Ok(value)
}

fn run(args: &[String]) -> R<()> {
    let rest = args.get(1..).unwrap_or_default();
    match args.first().map(String::as_str) {
        Some("install") => {
            let usage = "idris2x install [--locked] [--from <bundle>]";
            let from = flag(
                rest,
                "install",
                usage,
                Some("--from"),
                "a bundle file, after --from",
            )?;
            let pin = lock::resolve()?;
            if let Some(f) = from.as_deref().filter(|f| !Path::new(f).is_file()) {
                return Err(Fail::UsageNoSuchFile {
                    path: host(f).into(),
                    dir: host(lock::cwd()).into(),
                });
            }
            let dir = store::install(&pin, from.as_deref().map(Path::new))?;
            msg::out(&format!("{}\n", dir.display()))
        }
        Some("verify") => {
            flag(rest, "verify", "idris2x verify", None, "")?;
            store::verify(&lock::resolve()?)
        }
        Some("fetch") => {
            let (usage, what) = ("idris2x fetch -o <bundle>", "a file to write, after -o");
            let out = flag(rest, "fetch", usage, Some("-o"), what)?;
            let out = out.ok_or_else(|| Fail::UsageMissingArgument {
                usage: embedded(usage).into(),
                command: embedded("fetch").into(),
                what: embedded(what).into(),
            })?;
            store::bundle(&lock::resolve()?, Path::new(&out))
        }
        Some("explain") => msg::explain(args.get(1).map(String::as_str)),
        Some("__render") => msg::render_hook(rest),
        Some("version" | "--version") => msg::out(&format!("{}\n", idris2x::about())),
        Some("help" | "--help" | "-h") => {
            let rows: String = USAGE
                .iter()
                .map(|(c, d)| format!("  {c:<38} {d}\n"))
                .collect();
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
        let at = info.location().map_or("an unknown place".into(), |l| {
            format!("{}:{}", l.file(), l.line())
        });
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
