// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//!
//! An integration test, so `cargo test --all-targets` runs something real from
//! the day the repo is minted. `cargo test` with no tests at all exits 0, and a
//! green suite that contains no test is the same fake gate as one that is
//! skipped.

use idris2x::about;

#[test]
fn about_is_not_empty() {
    assert!(!about().is_empty());
}

// The launcher's own command line, run as a user would run it. Every variable that changes the output is cleared,
// and stderr is a pipe, so messages come out in the plain form.
use std::process::{Command, Output};

fn idris2x(args: &[&str], env: &[(&str, &str)]) -> Output {
    let mut c = Command::new(env!("CARGO_BIN_EXE_idris2x"));
    c.env_clear().args(args).envs(env.iter().copied());
    c.output().expect("the launcher binary runs")
}
fn text(b: &[u8]) -> String {
    String::from_utf8(b.to_vec()).expect("output is UTF-8")
}

#[test]
fn help_and_version_succeed_on_stdout() {
    let h = idris2x(&["help"], &[]);
    assert_eq!(h.status.code(), Some(0));
    assert!(text(&h.stdout).starts_with("usage: idris2x <command>\n"));
    assert!(text(&h.stdout).contains("explain [<id>]"));
    let v = idris2x(&["--version"], &[]);
    assert_eq!(
        (v.status.code(), text(&v.stdout)),
        (Some(0), format!("{}\n", about()))
    );
}

#[test]
fn an_unknown_command_is_e_usage_with_its_json_in_the_error_file() {
    let dir = std::env::temp_dir().join(format!("idris2x-cli-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("error.json");
    let o = idris2x(
        &["instal"],
        &[("IDRIS2X_ERROR_FILE", file.to_str().unwrap())],
    );
    assert_eq!(o.status.code(), Some(2));
    assert!(o.stdout.is_empty());
    assert!(text(&o.stderr).starts_with("idris2x: error[E-USAGE]: no such command: instal\n"));
    let json = std::fs::read_to_string(&file).unwrap();
    assert!(json.starts_with(r#"{"schema":1,"tool":"idris2x","level":"error","id":"E-USAGE","case":"unknown-command","exit":2,"#));
    assert!(json.contains(
        r#""context":{"word":"instal","commands":"install, exec, run, env, verify, gc, fetch, doctor, selftest, explain, help"}"#
    ));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn an_error_file_that_cannot_be_written_is_reported_and_the_exit_code_kept() {
    let o = idris2x(
        &["instal"],
        &[("IDRIS2X_ERROR_FILE", "/nonexistent-dir/error.json")],
    );
    assert_eq!(o.status.code(), Some(2));
    assert!(text(&o.stderr)
        .contains("idris2x: could not write IDRIS2X_ERROR_FILE /nonexistent-dir/error.json: "));
}

#[test]
fn a_placeholder_typed_by_the_user_is_shown_and_never_filled() {
    // One pass over each template: `{commands}` arrives as a value, so it is printed, not replaced.
    let o = idris2x(&["{commands}"], &[]);
    assert_eq!(o.status.code(), Some(2));
    assert!(text(&o.stderr).starts_with("idris2x: error[E-USAGE]: no such command: {commands}\n"));
}

#[test]
fn explain_knows_every_id_and_refuses_an_unknown_one() {
    let all = idris2x(&["explain"], &[]);
    assert_eq!(all.status.code(), Some(0));
    assert_eq!(text(&all.stdout).lines().count(), 18);
    let one = idris2x(&["explain", "E-HASH-MISMATCH"], &[]);
    assert!(text(&one.stdout).starts_with("E-HASH-MISMATCH (exit 11): "));
    assert!(text(&one.stdout).ends_with("docs/runbooks/E-HASH-MISMATCH.adoc\n"));
    let bad = idris2x(&["explain", "E-HASH"], &[]);
    assert_eq!(bad.status.code(), Some(2));
    assert!(text(&bad.stderr).starts_with("idris2x: error[E-USAGE]: no such error id: E-HASH\n"));
}

#[cfg(target_os = "linux")]
#[test]
fn a_failed_write_to_stdout_is_e_output_not_a_bug_report() {
    // /dev/full refuses every write with ENOSPC. The launcher must say so, and must not blame itself.
    let full = std::fs::File::create("/dev/full").expect("/dev/full exists on Linux");
    let o = Command::new(env!("CARGO_BIN_EXE_idris2x"))
        .env_clear()
        .arg("explain")
        .stdout(full)
        .output()
        .expect("the launcher binary runs");
    assert_eq!(o.status.code(), Some(25));
    let err = text(&o.stderr);
    assert!(
        err.starts_with("idris2x: error[E-OUTPUT]: cannot write the output: "),
        "{err}"
    );
    assert!(!err.contains("E-INTERNAL"));
}
