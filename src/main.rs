// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
#![forbid(unsafe_code)]

use idris2x::msg::{self, embedded, host, Fail, R};

/// The commands this build has, for `help` and for the unknown-command message. A command
/// joins this list in the milestone that builds it, so the binary never offers what it lacks.
const USAGE: [(&str, &str); 1] = [("explain [<id>]", "describe an error id")];
const COMMANDS: &str = "explain, help";

fn run(args: &[String]) -> R<()> {
    match args.first().map(String::as_str) {
        Some("explain") => msg::explain(args.get(1).map(String::as_str)),
        Some("__render") => msg::render_hook(&args[1..]),
        Some("version" | "--version") => {
            println!("{}", idris2x::about());
            Ok(())
        }
        Some("help" | "--help" | "-h") => {
            println!("usage: idris2x <command>");
            USAGE.iter().for_each(|(c, d)| println!("  {c:<38} {d}"));
            Ok(())
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
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Err(f) = run(&args) {
        msg::fail(f)
    }
}
