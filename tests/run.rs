// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! exec, run, env, doctor, gc and selftest, run as a user runs them, against capsules installed from a bundle.
//! Their Chez is a shell script that also stands in for Idris 2 and for the programs it compiles.

mod common;
use common::*;
use std::fs::{self, File};
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, SystemTime};

/// Chez, Idris 2 (after `--program <so>`) and the compiler, in one script. Each run prints what it was given and the
/// two variables the environment contract decides.
const CHEZ: &str = r#"#!/bin/sh
case "$1" in
  -q) [ -z "$IDRIS2_PACKAGE_PATH" ] || exit 1; cat >/dev/null; printf 42 ;;
  --program) shift 2
    case "$1" in
      --version) echo 'Idris 2, version 0.8.0' ;;
      --cg|-o) [ "$1" = --cg ] && shift 2
        mkdir -p build/exec && printf '#!/bin/sh\necho chez_codegen ok\n' > "build/exec/$2" && chmod +x "build/exec/$2" ;;
      *) echo "idris2 $* prefix=$IDRIS2_PREFIX pkg=$IDRIS2_PACKAGE_PATH" ;;
    esac ;;
  *) echo "chez $* prefix=$IDRIS2_PREFIX pkg=$IDRIS2_PACKAGE_PATH" ;;
esac
"#;

/// Install `tgz` from a bundle under the lock in `t`, and return its store directory.
fn installed(t: &Tmp, tgz: &[u8], env: &[(&str, &str)]) -> PathBuf {
    write_lock(t, &sha(tgz), tgz.len(), &[]);
    fs::write(t.p("c.tgz"), tgz).unwrap();
    PathBuf::from(ok(&run(t, &["install", "--from", "c.tgz"], env)).trim())
}
/// A capsule with Chez and no Idris 2.
fn chez_only() -> Vec<u8> {
    let json = br#"{"name":"chez-only","chez":"10.0.0","exec":{"chez":["bin/scheme"]}}"#;
    let sums = format!(
        "{}  capsule.json\n{}  bin/scheme\n",
        sha(json),
        sha(CHEZ.as_bytes())
    );
    let t = Tgz::new().entry(tar::EntryType::Directory, "bin/", 0o755, "", b"");
    let t = t.entry(
        tar::EntryType::Regular,
        "bin/scheme",
        0o755,
        "",
        CHEZ.as_bytes(),
    );
    t.file("capsule.json", json)
        .file("sha256sums.txt", sums.as_bytes())
        .done()
}

#[test]
fn exec_and_run_reset_the_environment_and_pass_every_word() {
    let t = Tmp::new("exec");
    let root = installed(&t, &capsule(CHEZ, &[]), &[]);
    let r = root.display();
    let leak = [("IDRIS2_PACKAGE_PATH", "/elsewhere")];
    let out = ok(&run(
        &t,
        &["exec", "--locked", "--", "idris2", "--check", "Main.idr"],
        &leak,
    ));
    assert_eq!(out, format!("idris2 --check Main.idr prefix={r} pkg=\n"));
    let out = ok(&run(
        &t,
        &["exec", "--inherit-env", "--", "idris2", "x"],
        &leak,
    ));
    assert_eq!(out, format!("idris2 x prefix={r} pkg=/elsewhere\n"));
    let out = ok(&run(&t, &["exec", "idris2", "--", "-x"], &leak));
    assert_eq!(
        out,
        format!("idris2 -- -x prefix={r} pkg=\n"),
        "after the program, every word is its own"
    );
    let out = ok(&run(&t, &["run", "--script", "a.ss"], &leak));
    assert_eq!(out, format!("chez --script a.ss prefix={r} pkg=\n"));
    let out = ok(&run(&t, &["exec", "--", "chez", "--script", "a.ss"], &leak));
    assert_eq!(
        out,
        format!("chez --script a.ss prefix={r} pkg=\n"),
        "run is exec -- chez"
    );
    failed(
        &t,
        &run(&t, &["exec"], &[]),
        "E-USAGE",
        "missing-argument",
        2,
    );
    failed(
        &t,
        &run(&t, &["exec", "--version"], &[]),
        "E-USAGE",
        "no-such-program",
        2,
    );
    let j = failed(
        &t,
        &run(&t, &["exec", "--", "racket"], &[]),
        "E-USAGE",
        "no-such-program",
        2,
    );
    assert!(j.contains(r#""programs":"chez, idris2""#), "{j}");
    // A Chez that cannot be started is a typed failure, not a crash.
    let scheme = root.join("bin/scheme");
    let mut p = fs::metadata(&scheme).unwrap().permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut p, 0o644);
    fs::set_permissions(&scheme, p).unwrap();
    failed(
        &t,
        &run(&t, &["run"], &[]),
        "E-PROBE-CODEGEN",
        "cannot-start",
        17,
    );
}

#[test]
fn exec_of_a_capsule_without_idris2_is_refused_and_run_still_works() {
    let t = Tmp::new("chez-only");
    installed(&t, &chez_only(), &[]);
    let j = failed(
        &t,
        &run(&t, &["exec", "--", "idris2", "--version"], &[]),
        "E-USAGE",
        "no-such-program",
        2,
    );
    assert!(j.contains(r#""programs":"chez""#), "{j}");
    assert!(ok(&run(&t, &["run", "x"], &[])).starts_with("chez x "));
    assert!(ok(&run(&t, &["exec", "chez", "x"], &[])).starts_with("chez x "));
}

/// A capsule whose exec map names `words` for the program `p`.
fn mapped(p: &str, words: &str) -> Vec<u8> {
    let json = format!(r#"{{"name":"odd","chez":"10.0.0","exec":{{"{p}":{words}}}}}"#);
    let sums = format!(
        "{}  capsule.json\n{}  bin/scheme\n",
        sha(json.as_bytes()),
        sha(CHEZ.as_bytes())
    );
    let t = Tgz::new().entry(tar::EntryType::Directory, "bin/", 0o755, "", b"");
    let t = t.entry(
        tar::EntryType::Regular,
        "bin/scheme",
        0o755,
        "",
        CHEZ.as_bytes(),
    );
    t.file("capsule.json", json.as_bytes())
        .file("sha256sums.txt", sums.as_bytes())
        .done()
}

#[test]
fn an_exec_map_entry_that_leaves_the_capsule_is_refused() {
    let bad = [
        r#"["/bin/sh"]"#,
        r#"["../../../../bin/sh"]"#,
        r#"["bin/../../x"]"#,
        r#"[""]"#,
        r#"["bin/scheme", "/bin/sh"]"#,
        r#"["bin/scheme", 7]"#,
    ];
    for words in bad {
        let t = Tmp::new("bad-exec");
        installed(&t, &mapped("x", words), &[]);
        let j = failed(
            &t,
            &run(&t, &["exec", "x"], &[]),
            "E-CAPSULE-INVALID",
            "bad-exec",
            21,
        );
        assert!(j.contains(r#""program":"x""#), "{words}: {j}");
    }
    // An empty list names no command at all.
    let t = Tmp::new("empty-exec");
    installed(&t, &mapped("x", "[]"), &[]);
    failed(
        &t,
        &run(&t, &["exec", "x"], &[]),
        "E-USAGE",
        "no-such-program",
        2,
    );
    // A later word that starts with a dash is an option, and a path word is joined to the capsule.
    let t = Tmp::new("good-exec");
    let root = installed(
        &t,
        &mapped("x", r#"["bin/scheme", "--program", "bin/x.so"]"#),
        &[],
    );
    let out = ok(&run(&t, &["exec", "x", "y"], &[]));
    assert_eq!(out, format!("idris2 y prefix={} pkg=\n", root.display()));
}

#[test]
fn env_lines_reset_a_shell_and_survive_quotes_and_spaces() {
    let t = Tmp::new("env");
    let cache = t.p("it's a cache");
    let at = [("IDRIS2X_CACHE", cache.to_str().unwrap())];
    let root = installed(&t, &capsule(CHEZ, &[]), &at);
    let with = [at[0], ("IDRIS2_PACKAGE_PATH", "/elsewhere")];
    let lines = ok(&run(&t, &["env"], &with));
    assert!(
        lines.starts_with("unset IDRIS2_PACKAGE_PATH\nexport IDRIS2X_CAPSULE='"),
        "{lines}"
    );
    let sh = Command::new("/bin/sh")
        .args([
            "-c",
            "eval \"$0\"; printf '%s|%s' \"$IDRIS2_PREFIX\" \"${IDRIS2_PACKAGE_PATH-unset}\"",
        ])
        .arg(&lines)
        .env("IDRIS2_PACKAGE_PATH", "/elsewhere")
        .output()
        .unwrap();
    assert_eq!(
        String::from_utf8(sh.stdout).unwrap(),
        format!("{}|unset", root.display())
    );
    let json: serde_json::Value =
        serde_json::from_str(&ok(&run(&t, &["env", "--json"], &with))).unwrap();
    assert_eq!(json["IDRIS2_PREFIX"], root.display().to_string());
    assert_eq!(json.as_object().unwrap().len(), 8);
    failed(
        &t,
        &run(&t, &["env", "--jsn"], &at),
        "E-USAGE",
        "unknown-flag",
        2,
    );
}

#[test]
fn doctor_reports_each_check_and_changes_nothing() {
    let t = Tmp::new("doctor");
    let outside = ok(&run(&t, &["doctor", "--offline"], &[]));
    assert!(outside.contains("\ninfo    store: "), "{outside}");
    assert!(outside.contains("\ninfo    lock: "), "{outside}");
    assert!(
        outside.ends_with("0 problems, 0 notes. Nothing was changed. No data left this machine.\n")
    );
    assert!(!t.p("cache").exists(), "doctor creates nothing");

    let tgz = capsule(CHEZ, &[]);
    let root = installed(&t, &tgz, &[]);
    let (url, log) = serve(vec![], 200, None);
    write_lock(&t, &sha(&tgz), tgz.len(), &[url]);
    let leak = [("IDRIS2_PACKAGE_PATH", "/elsewhere")];
    let text = ok(&run(&t, &["doctor"], &leak));
    for want in [
        "\nok      store: ",
        " is writable and locks work\n",
        "\nok      lock: ",
        " is installed and matches its checksums\n",
        "\nok      probes: Chez evaluates, Idris 2 reports 0.8.0\n",
        "\nok      mirror: 127.0.0.1:",
        "note: IDRIS2_PACKAGE_PATH is set in your shell and idris2x will ignore it.",
        "0 problems, 1 note. Nothing was changed. No data left this machine except the mirror check.\n",
    ] {
        assert!(text.contains(want), "want {want:?} in\n{text}");
    }
    assert_eq!(log.lock().unwrap().len(), 1, "one request per mirror");
    let quiet = ok(&run(
        &t,
        &["doctor", "--offline"],
        &[leak[0], ("IDRIS2X_ADVICE_ENV", "0")],
    ));
    assert!(quiet.contains("\nskip    mirror: not checked: offline\n") && !quiet.contains("note:"));
    assert_eq!(log.lock().unwrap().len(), 1, "--offline sends nothing");
    let unread = ok(&run(&t, &["doctor"], &[("IDRIS2X_OFFLINE", "yes")]));
    assert!(unread.contains("\nproblem setting: "), "{unread}");
    assert!(
        unread.contains("\nskip    mirror: not checked: offline\n"),
        "{unread}"
    );
    assert_eq!(
        log.lock().unwrap().len(),
        1,
        "an unreadable IDRIS2X_OFFLINE sends nothing"
    );
    let nowhere = ok(&run(&t, &["doctor", "--offline"], &[("IDRIS2X_CACHE", "")]));
    assert!(nowhere.contains("\nproblem store: "), "{nowhere}");
    assert!(
        nowhere.contains("\nskip    capsule: not checked: the store cannot be found\n"),
        "{nowhere}"
    );

    fs::write(root.join("bin/idris2_app/idris2.so"), "changed").unwrap();
    let json = ok(&run(&t, &["doctor", "--json"], &[("IDRIS2X_OFFLINE", "1")]));
    let j: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(
        (
            j["problems"].as_u64(),
            j["changed"].as_bool(),
            j["network"].as_bool()
        ),
        (Some(1), Some(false), Some(false))
    );
    assert!(json.contains("-> E-HASH-MISMATCH"), "{json}");
    let left: Vec<_> = fs::read_dir(t.p("cache"))
        .unwrap()
        .flatten()
        .map(|e| e.file_name())
        .collect();
    assert!(
        left.iter()
            .all(|n| !n.to_string_lossy().starts_with(".doctor")),
        "{left:?}"
    );
}

#[test]
fn gc_lists_first_and_removes_only_what_it_wrote_under_each_lock() {
    let t = Tmp::new("gc");
    let day = |n: u64| SystemTime::now() - Duration::from_secs(n * 86_400);
    let mut digests = vec![];
    for (i, extra) in [b"1", b"2", b"3"].iter().enumerate() {
        let tgz = capsule(CHEZ, &[("extra", *extra)]);
        let root = installed(&t, &tgz, &[]);
        File::options()
            .write(true)
            .open(root.join(".complete"))
            .unwrap()
            .set_modified(day(3 - i as u64))
            .unwrap();
        digests.push(sha(&tgz));
    }
    let (newest, hex) = (digests[2].clone(), "a".repeat(64));
    fs::create_dir_all(t.p(&format!("cache/store/sha256-{hex}"))).unwrap();
    for (name, age) in [
        (format!("sha256-{hex}.part"), 2),
        (format!("sha256-{}.part", "b".repeat(64)), 0),
        ("notours".into(), 2),
    ] {
        let p = t.p(&format!("cache/staging/{name}"));
        File::create(&p).unwrap().set_modified(day(age)).unwrap();
    }

    let dry = ok(&run(&t, &["gc", "--keep-last", "1", "--dry-run"], &[]));
    assert!(
        dry.contains("idris2x: would remove an incomplete install "),
        "{dry}"
    );
    assert!(
        dry.contains("idris2x: would remove 2 capsules and free "),
        "{dry}"
    );
    assert!(dry.contains("idris2x: keeping 1 capsule:\n"), "{dry}");
    assert!(
        dry.contains("note: Programs you compiled with a removed capsule"),
        "{dry}"
    );
    assert!(dry.ends_with("Nothing was removed.\n"), "{dry}");
    assert_eq!(store(&t).len(), 4, "--dry-run removes nothing");

    let asked = ok(&run(
        &t,
        &["gc", "--keep-last", "1"],
        &[("IDRIS2X_ADVICE", "0")],
    ));
    assert!(
        asked.ends_with("Nothing was removed. Pass --yes to remove them.\n")
            && !asked.contains("note:")
    );
    let staging: Vec<_> = fs::read_dir(t.p("cache/staging"))
        .unwrap()
        .flatten()
        .map(|e| e.file_name())
        .collect();
    assert_eq!(
        staging.len(),
        2,
        "the day-old .part goes; a fresh one and a name idris2x never writes stay"
    );
    assert!(staging.iter().any(|n| n == "notours"));
    assert_eq!(
        store(&t).len(),
        3,
        "the incomplete install is gone; the capsules stay until --yes"
    );

    // An install holding a capsule's lock keeps that capsule.
    let held = File::create(t.p(&format!("cache/locks/sha256-{}.lock", digests[0]))).unwrap();
    held.lock().unwrap();
    let done = ok(&run(&t, &["gc", "--keep-last", "1", "--yes"], &[]));
    assert!(
        done.contains(&format!(
            "idris2x: kept sha256:{}…: an install holds its lock\n",
            &digests[0][..12]
        )),
        "{done}"
    );
    assert!(
        done.contains("idris2x: removed 1 capsule and freed "),
        "{done}"
    );
    drop(held);
    ok(&run(&t, &["gc", "--keep-last", "1", "--yes"], &[]));
    assert_eq!(store(&t), [format!("sha256-{newest}")]);
    assert!(ok(&run(&t, &["gc"], &[])).ends_with("idris2x: nothing to remove; keeping 1 capsule\n"));
    failed(
        &t,
        &run(&t, &["gc", "--keep-last", "x"], &[]),
        "E-USAGE",
        "missing-argument",
        2,
    );
}

#[test]
fn selftest_compiles_runs_and_moves_a_program_then_cleans_up() {
    let t = Tmp::new("selftest");
    installed(&t, &capsule(CHEZ, &[]), &[]);
    let out = ok(&run(&t, &["selftest"], &[]));
    assert!(
        out.ends_with("[OK] pure_eval version_match chez_codegen relocatable_artifact\n"),
        "{out}"
    );
    assert!(
        out.starts_with("[OK] refc_codegen\n")
            || out.starts_with("[skip] refc_codegen (no cc on PATH)\n"),
        "{out}"
    );
    let left = fs::read_dir(t.p("cache/staging")).unwrap().flatten();
    assert!(left
        .map(|e| e.file_name())
        .all(|n| !n.to_string_lossy().starts_with("selftest-")));

    // A compiled program that does not run is a codegen failure; with a space in the store path, it says so.
    let wrong = CHEZ.replace("echo chez_codegen ok", "echo wrong");
    let t2 = Tmp::new("selftest2");
    installed(&t2, &capsule(&wrong, &[]), &[]);
    failed(
        &t2,
        &run(&t2, &["selftest"], &[]),
        "E-PROBE-CODEGEN",
        "codegen-failed",
        17,
    );
    let spaced = [(
        "IDRIS2X_CACHE",
        t2.p("a cache").to_str().unwrap().to_owned(),
    )];
    let spaced = [(spaced[0].0, spaced[0].1.as_str())];
    installed(&t2, &capsule(&wrong, &[]), &spaced);
    failed(
        &t2,
        &run(&t2, &["selftest"], &spaced),
        "E-PROBE-CODEGEN",
        "path-has-spaces",
        17,
    );
}
