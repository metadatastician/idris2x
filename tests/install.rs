// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! install, verify and fetch, run as a user runs them, against a local HTTP server and a fake capsule whose Chez is a
//! shell script. Every failure is checked by the id and case in the error file, never by matching prose.

mod common;
use common::*;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

#[test]
fn install_downloads_checks_stores_once_and_verify_passes() {
    let t = Tmp::new("ok");
    let tgz = capsule(SCHEME, &[]);
    let (url, log) = serve(tgz.clone(), 200, None);
    let d = sha(&tgz);
    write_lock(&t, &d, tgz.len(), &[url]);
    // An inherited code search path must not reach the probes (ADR 0005).
    let leak = [
        ("IDRIS2_PACKAGE_PATH", "/elsewhere"),
        ("IDRIS2_PREFIX", "/elsewhere"),
    ];
    let out = ok(&run(&t, &["install", "--locked"], &leak));
    let dir = t.p(&format!("cache/store/sha256-{d}"));
    assert_eq!(out, format!("{}\n", dir.display()));
    assert!(fs::read_to_string(dir.join(".complete"))
        .unwrap()
        .starts_with(&format!("sha256:{d} 20")));
    assert_eq!(ok(&run(&t, &["install"], &[])), out);
    assert_eq!(
        log.lock().unwrap().len(),
        1,
        "a complete capsule is not downloaded again"
    );
    let v = run(&t, &["verify"], &[]);
    ok(&v);
    assert!(String::from_utf8_lossy(&v.stderr)
        .contains(&format!("OK sha256:{d} verified (idris2-test)")));
    assert!(fs::read_dir(t.p("cache/staging")).unwrap().all(|e| e
        .unwrap()
        .file_name()
        .to_string_lossy()
        != format!("stage-sha256-{d}")));
    // A changed file in the store is found, and verify says so.
    fs::write(dir.join("bin/idris2_app/idris2.so"), "changed").unwrap();
    failed(
        &t,
        &run(&t, &["verify"], &[]),
        "E-HASH-MISMATCH",
        "store-modified",
        11,
    );
}

#[test]
fn a_partial_download_resumes_with_a_range_request() {
    let t = Tmp::new("resume");
    let tgz = capsule(SCHEME, &[("big", &[7; 100_000])]);
    let (url, log) = serve(tgz.clone(), 200, None);
    let d = sha(&tgz);
    write_lock(&t, &d, tgz.len(), &[url]);
    fs::create_dir_all(t.p("cache/staging")).unwrap();
    fs::write(t.p(&format!("cache/staging/sha256-{d}.part")), &tgz[..1000]).unwrap();
    ok(&run(&t, &["install"], &[]));
    assert_eq!(*log.lock().unwrap(), ["206 Some(1000)"]);
    assert!(!t.p(&format!("cache/staging/sha256-{d}.part")).exists());
}

#[test]
fn a_transfer_cut_short_is_retried_and_then_reported() {
    let t = Tmp::new("cut");
    let tgz = capsule(SCHEME, &[]);
    let (url, log) = serve(tgz.clone(), 200, Some(100));
    write_lock(&t, &sha(&tgz), tgz.len(), &[url]);
    let json = failed(
        &t,
        &run(&t, &["install"], &[]),
        "E-NETWORK",
        "all-mirrors-failed",
        14,
    );
    assert!(log.lock().unwrap().len() >= 2, "{:?}", log.lock().unwrap());
    assert!(json.contains("fetch.log"));
    assert!(store(&t).is_empty());
}

#[test]
fn every_mirror_failing_names_each_one_and_plain_http_elsewhere_is_refused() {
    let t = Tmp::new("mirrors");
    let (url, _) = serve(vec![], 404, None);
    let d = sha(b"x");
    // A user part does not make a host local, and a local mirror may not redirect anywhere.
    let (moved, hops) = serve(vec![], 302, None);
    let sneaky = "http://localhost:80@example.org/c.tar.gz".to_string();
    write_lock(
        &t,
        &d,
        1,
        &[
            "http://example.org/c.tar.gz".into(),
            sneaky.clone(),
            moved.clone(),
            url.clone(),
        ],
    );
    let json = failed(
        &t,
        &run(&t, &["install"], &[]),
        "E-NETWORK",
        "all-mirrors-failed",
        14,
    );
    assert!(
        json.contains(
            "http://example.org/c.tar.gz: refused: plain http is allowed only to this machine"
        ),
        "{json}"
    );
    let refused = format!("{sneaky}: refused: plain http is allowed only to this machine");
    assert!(json.contains(&refused), "{json}");
    assert!(
        json.contains(&format!(
            "{moved}: refused: answer 302 Found is not the file"
        )),
        "{json}"
    );
    assert!(json.contains(&format!("{url}: ")), "{json}");
    assert_eq!(
        hops.lock().unwrap().len(),
        1,
        "the redirect was not followed"
    );
}

#[test]
fn a_download_with_the_wrong_digest_is_deleted() {
    let t = Tmp::new("digest");
    let tgz = capsule(SCHEME, &[]);
    let (url, _) = serve(tgz.clone(), 200, None);
    write_lock(&t, &sha(b"other"), tgz.len(), &[url]);
    failed(
        &t,
        &run(&t, &["install"], &[]),
        "E-HASH-MISMATCH",
        "download",
        11,
    );
    assert!(fs::read_dir(t.p("cache/staging")).unwrap().all(|e| !e
        .unwrap()
        .file_name()
        .to_string_lossy()
        .ends_with(".part")));
    assert!(store(&t).is_empty());
}

#[test]
fn fetch_writes_a_bundle_that_installs_offline() {
    let t = Tmp::new("bundle");
    let tgz = capsule(SCHEME, &[]);
    let (url, _) = serve(tgz.clone(), 200, None);
    write_lock(&t, &sha(&tgz), tgz.len(), &[url]);
    failed(
        &t,
        &run(&t, &["fetch"], &[]),
        "E-USAGE",
        "missing-argument",
        2,
    );
    ok(&run(&t, &["fetch", "-o", "c.tgz"], &[]));
    assert_eq!(fs::read(t.p("c.tgz")).unwrap(), tgz);
    failed(
        &t,
        &run(&t, &["install"], &[("IDRIS2X_OFFLINE", "1")]),
        "E-OFFLINE",
        "capsule-missing",
        20,
    );
    ok(&run(
        &t,
        &["install", "--from", "c.tgz"],
        &[("IDRIS2X_OFFLINE", "1")],
    ));
    assert!(t.p("c.tgz").is_file(), "a bundle is never deleted");
    // A bundle with other bytes is refused and kept.
    let t2 = Tmp::new("bundle2");
    write_lock(&t2, &sha(b"other"), tgz.len(), &[]);
    fs::write(t2.p("c.tgz"), &tgz).unwrap();
    failed(
        &t2,
        &run(&t2, &["install", "--from", "c.tgz"], &[]),
        "E-HASH-MISMATCH",
        "bundle",
        11,
    );
    assert!(t2.p("c.tgz").is_file());
    failed(
        &t2,
        &run(&t2, &["install", "--from", "nope.tgz"], &[]),
        "E-USAGE",
        "no-such-file",
        2,
    );
    failed(
        &t2,
        &run(&t2, &["install"], &[]),
        "E-PIN-NOT-FOUND",
        "no-urls",
        10,
    );
}

/// Install `tgz` from a bundle and expect this failure, with nothing in the store and nothing outside the tree.
fn refused(name: &str, tgz: Vec<u8>, id: &str, case: &str, exit: i32) {
    let t = Tmp::new(name);
    write_lock(&t, &sha(&tgz), tgz.len(), &[]);
    fs::write(t.p("c.tgz"), &tgz).unwrap();
    failed(
        &t,
        &run(&t, &["install", "--from", "c.tgz"], &[]),
        id,
        case,
        exit,
    );
    assert!(store(&t).is_empty(), "{name}: the store is untouched");
    assert_eq!(
        fs::read(t.p("c.tgz")).unwrap(),
        tgz,
        "{name}: the bundle is left where it was"
    );
    assert!(
        !t.p("cache/escaped").exists() && !t.p("escaped").exists(),
        "{name}: nothing was written outside"
    );
    assert_eq!(
        fs::read_dir(t.p("cache/staging")).unwrap().count(),
        0,
        "{name}: staging is clean"
    );
}

#[test]
fn hostile_archives_are_refused_before_anything_leaves_staging() {
    use tar::EntryType::{Block, Directory, Link, Regular, Symlink};
    let unsafe_ = |name: &str, f: &dyn Fn(Tgz) -> Tgz| {
        refused(
            name,
            f(Tgz::new().file("capsule.json", b"{}")).done(),
            "E-CAPSULE-INVALID",
            "unsafe-path",
            21,
        )
    };
    unsafe_("absolute", &|t| t.file("/tmp/escaped", b"x"));
    unsafe_("dotdot", &|t| t.file("../escaped", b"x"));
    unsafe_("dotdot-deep", &|t| t.file("a/../../escaped", b"x"));
    unsafe_("setuid", &|t| t.entry(Regular, "bin/su", 0o4755, "", b"x"));
    unsafe_("device", &|t| t.entry(Block, "dev", 0o644, "", b""));
    unsafe_("symlink-out", &|t| {
        t.entry(Symlink, "l", 0o777, "../..", b"")
    });
    unsafe_("symlink-abs", &|t| {
        t.entry(Symlink, "l", 0o777, "/etc", b"")
    });
    // Each link is harmless by its text alone; together they climb out.
    unsafe_("symlink-chain", &|t| {
        t.entry(Symlink, "a", 0o777, ".", b"")
            .entry(Symlink, "b", 0o777, "a/..", b"")
    });
    unsafe_("through-a-link", &|t| {
        t.entry(Symlink, "d", 0o777, ".", b"")
            .file("d/escaped", b"x")
    });
    unsafe_("over-a-file", &|t| t.file("f", b"1").file("f", b"2"));
    unsafe_("hardlink-out", &|t| {
        t.entry(Link, "h", 0o644, "../escaped", b"")
    });
    unsafe_("hardlink-dir", &|t| {
        t.entry(Directory, "d/", 0o755, "", b"")
            .entry(Link, "h", 0o644, "d", b"")
    });
    refused(
        "not-gzip",
        b"plain bytes".to_vec(),
        "E-CAPSULE-INVALID",
        "no-metadata",
        21,
    );
    refused(
        "no-metadata",
        Tgz::new().file("x", b"x").done(),
        "E-CAPSULE-INVALID",
        "no-metadata",
        21,
    );
    let tampered = Tgz::new().file("capsule.json", b"{}").file(
        "sha256sums.txt",
        format!("{}  capsule.json\n", sha(b"x")).as_bytes(),
    );
    refused(
        "tree-mismatch",
        tampered.done(),
        "E-CAPSULE-INVALID",
        "tree-mismatch",
        21,
    );
    let escaping = Tgz::new().file("capsule.json", b"{}").file(
        "sha256sums.txt",
        format!("{}  ../c.tgz\n", sha(b"x")).as_bytes(),
    );
    // The list must cover capsule.json, as the factory's does, so verify can trust it later.
    let uncovered = Tgz::new()
        .file("capsule.json", br#"{"name":"x","chez":"10.0.0"}"#)
        .file("sha256sums.txt", b"");
    refused(
        "uncovered",
        uncovered.done(),
        "E-CAPSULE-INVALID",
        "tree-mismatch",
        21,
    );
    refused(
        "sums-escape",
        escaping.done(),
        "E-CAPSULE-INVALID",
        "tree-mismatch",
        21,
    );
    // capsule.json must name the capsule and its Chez Scheme version, and give an Idris 2 version only as text.
    for (i, j) in [
        &b"[1]"[..],
        br#"{"name":"x"}"#,
        br#"{"name":"x","chez":"10.0.0","idris2":8}"#,
    ]
    .into_iter()
    .enumerate()
    {
        let sums = format!("{}  capsule.json\n", sha(j));
        let undescribed = Tgz::new()
            .file("capsule.json", j)
            .file("sha256sums.txt", sums.as_bytes());
        refused(
            &format!("bad-metadata-{i}"),
            undescribed.done(),
            "E-CAPSULE-INVALID",
            "bad-metadata",
            21,
        );
    }
    refused(
        "probe",
        capsule(&SCHEME.replace("printf 42", "printf 41"), &[]),
        "E-PROBE-CODEGEN",
        "chez-failed",
        17,
    );
    let wrong = SCHEME.replace("version 0.8.0", "version 0.7.0");
    refused(
        "version",
        capsule(&wrong, &[]),
        "E-PROBE-CODEGEN",
        "version-mismatch",
        17,
    );
    // Links that stay inside the tree are kept.
    let t = Tmp::new("inside-links");
    let tgz = capsule_tgz(SCHEME, &[]).entry(Symlink, "bin/idris2", 0o777, "scheme", b"");
    let tgz = tgz
        .entry(Link, "bin/again", 0o644, "capsule.json", b"")
        .done();
    write_lock(&t, &sha(&tgz), tgz.len(), &[]);
    fs::write(t.p("c.tgz"), &tgz).unwrap();
    let dir = PathBuf::from(ok(&run(&t, &["install", "--from", "c.tgz"], &[])).trim());
    assert_eq!(
        fs::read_link(dir.join("bin/idris2")).unwrap(),
        Path::new("scheme")
    );
    assert_eq!(
        fs::read(dir.join("bin/again")).unwrap(),
        fs::read(dir.join("capsule.json")).unwrap()
    );
}

#[test]
fn a_held_lock_times_out_naming_its_holder() {
    let t = Tmp::new("held");
    let tgz = capsule(SCHEME, &[]);
    let d = sha(&tgz);
    write_lock(&t, &d, tgz.len(), &[]);
    fs::create_dir_all(t.p("cache/locks")).unwrap();
    let f = fs::File::create(t.p(&format!("cache/locks/sha256-{d}.lock"))).unwrap();
    f.lock().unwrap();
    fs::write(
        t.p(&format!("cache/locks/sha256-{d}.holder")),
        format!("{}\n", std::process::id()),
    )
    .unwrap();
    let json = failed(
        &t,
        &run(&t, &["install"], &[("IDRIS2X_LOCK_TIMEOUT", "1")]),
        "E-LOCK-TIMEOUT",
        "held",
        15,
    );
    assert!(
        json.contains(&format!("process {} (still running)", std::process::id())),
        "{json}"
    );
    fs::write(t.p(&format!("cache/locks/sha256-{d}.holder")), "").unwrap();
    let json = failed(
        &t,
        &run(&t, &["install"], &[("IDRIS2X_LOCK_TIMEOUT", "1")]),
        "E-LOCK-TIMEOUT",
        "held",
        15,
    );
    assert!(
        json.contains("unknown (the holder left no record)"),
        "{json}"
    );
}

#[test]
fn settings_are_read_strictly() {
    let t = Tmp::new("settings");
    write_lock(&t, &sha(b"x"), 1, &[]);
    for (k, v) in [
        ("IDRIS2X_OFFLINE", "yes"),
        ("IDRIS2X_OFFLINE", "2"),
        ("IDRIS2X_LOCK_TIMEOUT", "ten"),
        ("IDRIS2X_LOCK_TIMEOUT", "-1"),
        ("IDRIS2X_NET_TIMEOUT", "0"),
        ("IDRIS2X_NET_TIMEOUT", "ten"),
    ] {
        let json = failed(
            &t,
            &run(&t, &["install"], &[(k, v)]),
            "E-USAGE",
            "bad-setting",
            2,
        );
        assert!(json.contains(k), "{json}");
    }
    failed(
        &t,
        &run(&t, &["verify", "--locked"], &[]),
        "E-USAGE",
        "unknown-flag",
        2,
    );
    failed(
        &t,
        &run(&t, &["install", "--from"], &[]),
        "E-USAGE",
        "missing-argument",
        2,
    );
    failed(
        &t,
        &run(&t, &["verify"], &[]),
        "E-PIN-NOT-FOUND",
        "not-installed",
        10,
    );
}

#[test]
fn a_bad_lock_is_named_and_nothing_is_downloaded() {
    let t = Tmp::new("locks");
    let case = |text: &str, id: &str, case: &str, exit: i32| {
        fs::write(t.p("idris2x.lock"), text).unwrap();
        failed(&t, &run(&t, &["install"], &[]), id, case, exit)
    };
    fs::remove_file(t.p("idris2x.lock")).ok();
    failed(
        &t,
        &run(&t, &["install"], &[]),
        "E-PIN-NOT-FOUND",
        "no-lock",
        10,
    );
    case("not json", "E-PIN-NOT-FOUND", "unreadable-lock", 10);
    case(r#"{"schema":2}"#, "E-CHANNEL-SCHEMA", "lock-newer", 18);
    for no_format in [
        r#"{}"#,
        r#"{"schema":"1"}"#,
        r#"{"schema":0}"#,
        r#"{"schema":1.5}"#,
    ] {
        case(no_format, "E-PIN-NOT-FOUND", "unreadable-lock", 10);
    }
    let json = case(
        r#"{"schema":1,"toolchain":{"idris2":"0.8.0"},"capsules":{"z80-none":{}}}"#,
        "E-PIN-NOT-FOUND",
        "no-target",
        10,
    );
    assert!(json.contains("z80-none"), "{json}");
    case(
        r#"{"schema":1,"toolchain":{"idris2":"0.8; rm -rf /"}}"#,
        "E-PIN-NOT-FOUND",
        "malformed-lock",
        10,
    );
    let tgt = target();
    let bad = |c: &str| {
        format!(r#"{{"schema":1,"toolchain":{{"idris2":"0.8.0"}},"capsules":{{"{tgt}":{c}}}}}"#)
    };
    case(
        &bad(r#"{"sha256":"ABC","size":1}"#),
        "E-PIN-NOT-FOUND",
        "malformed-lock",
        10,
    );
    case(
        &bad(&format!(r#"{{"sha256":"{}"}}"#, sha(b"x"))),
        "E-PIN-NOT-FOUND",
        "malformed-lock",
        10,
    );
    case(
        &bad(&format!(
            r#"{{"sha256":"{}","size":1,"urls":[1]}}"#,
            sha(b"x")
        )),
        "E-PIN-NOT-FOUND",
        "malformed-lock",
        10,
    );
    // A floor too large to compare is a fault in the lock, never a floor of 0.
    let huge = format!(
        r#"{{"sha256":"{}","size":1,"min_glibc":"18446744073709551616.0"}}"#,
        sha(b"x")
    );
    let json = case(&bad(&huge), "E-PIN-NOT-FOUND", "malformed-lock", 10);
    assert!(json.contains("glibc floor"), "{json}");
    let floor = format!(
        r#"{{"sha256":"{}","size":1,"min_glibc":"99.0"}}"#,
        sha(b"x")
    );
    // The launcher asks getconf on its own PATH, so the guard asks on the same one. Without getconf the floor is
    // refused as unknown, never skipped.
    if cfg!(target_os = "linux") {
        fs::write(t.p("idris2x.lock"), bad(&floor)).unwrap();
        let has = Command::new("getconf")
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .arg("GNU_LIBC_VERSION")
            .output()
            .is_ok_and(|o| o.status.success());
        if has {
            failed(
                &t,
                &run(&t, &["install"], &[]),
                "E-GLIBC-FLOOR",
                "too-old",
                16,
            );
        }
        let none = t.p("no-such-dir");
        let o = run(&t, &["install"], &[("PATH", none.to_str().unwrap())]);
        failed(&t, &o, "E-GLIBC-FLOOR", "unknown", 16);
    }
}

#[test]
fn settings_that_are_unset_or_not_text_are_refused_not_guessed() {
    use std::os::unix::ffi::OsStrExt;
    let t = Tmp::new("unset-settings");
    write_lock(&t, &sha(b"x"), 1, &["http://127.0.0.1:9/x".into()]);
    // With no IDRIS2X_CACHE, XDG_CACHE_HOME or HOME there is no store, and the working directory is not one.
    let o = run(&t, &["install"], &[("IDRIS2X_CACHE", "")]);
    failed(&t, &o, "E-STORE-IO", "no-cache-dir", 24);
    assert!(!t.p(".cache").exists());
    let not_text = std::ffi::OsStr::from_bytes(b"idris2x\xff.lock");
    for name in [
        "IDRIS2X_LOCK",
        "IDRIS2X_CACHE",
        "IDRIS2X_LOCK_TIMEOUT",
        "IDRIS2X_NET_TIMEOUT",
    ] {
        let mut c = Command::new(env!("CARGO_BIN_EXE_idris2x"));
        c.env_clear()
            .current_dir(&t.0)
            .arg("install")
            .env("PATH", "/usr/bin:/bin");
        c.env("IDRIS2X_CACHE", t.p("cache"))
            .env("IDRIS2X_ERROR_FILE", t.p("error.json"));
        let json = failed(
            &t,
            &c.env(name, not_text).output().unwrap(),
            "E-USAGE",
            "bad-setting",
            2,
        );
        assert!(json.contains(name), "{json}");
    }
}

#[test]
fn a_file_size_limit_is_reported_not_a_silent_death() {
    let t = Tmp::new("ulimit");
    let big: Vec<u8> = (0..1_000_000u32)
        .map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8)
        .collect();
    let tgz = capsule(SCHEME, &[("big", &big)]);
    let (url, _) = serve(tgz.clone(), 200, None);
    write_lock(&t, &sha(&tgz), tgz.len(), &[url]);
    let bin = env!("CARGO_BIN_EXE_idris2x");
    let mut c = Command::new("/bin/sh");
    c.env_clear()
        .current_dir(&t.0)
        .args(["-c", &format!("ulimit -f 100; exec '{bin}' install")]);
    c.env("PATH", "/usr/bin:/bin")
        .env("IDRIS2X_CACHE", t.p("cache"))
        .env("IDRIS2X_ERROR_FILE", t.p("error.json"));
    let o = c.output().unwrap();
    let json = failed(&t, &o, "E-STORE-IO", "write-failed", 24);
    assert!(json.contains("the file size limit was reached"), "{json}");
    assert!(store(&t).is_empty());
}

#[test]
fn archive_modes_keep_only_the_permission_bits() {
    let t = Tmp::new("modes");
    let tgz = capsule(SCHEME, &[]);
    write_lock(&t, &sha(&tgz), tgz.len(), &[]);
    fs::write(t.p("c.tgz"), &tgz).unwrap();
    let dir = ok(&run(&t, &["install", "--from", "c.tgz"], &[]));
    let mode = fs::metadata(Path::new(dir.trim()).join("bin/scheme"))
        .unwrap()
        .permissions()
        .mode();
    assert!(mode & 0o7000 == 0 && mode & 0o100 != 0, "{mode:o}");
}

#[test]
fn a_mirror_that_stops_sending_fails_over_to_the_next() {
    let t = Tmp::new("stall");
    let tgz = capsule(SCHEME, &[]);
    let (good, _) = serve(tgz.clone(), 200, None);
    let (quiet, mid) = (stall(false), stall(true));
    write_lock(&t, &sha(&tgz), tgz.len(), &[quiet.clone(), mid.clone()]);
    let slow = [("IDRIS2X_NET_TIMEOUT", "1")];
    let began = std::time::Instant::now();
    let json = failed(
        &t,
        &run(&t, &["install"], &slow),
        "E-NETWORK",
        "all-mirrors-failed",
        14,
    );
    assert!(began.elapsed().as_secs() < 30, "{:?}", began.elapsed());
    assert!(
        json.contains(&format!("{quiet}: ")) && json.contains(&format!("{mid}: ")),
        "{json}"
    );
    assert!(store(&t).is_empty());
    // With a mirror that answers after them, the install completes from it.
    write_lock(&t, &sha(&tgz), tgz.len(), &[quiet, mid, good]);
    ok(&run(&t, &["install"], &slow));
    assert_eq!(store(&t).len(), 1);
}

#[test]
fn a_capsule_of_another_idris2_is_refused_and_one_of_chez_only_installs() {
    let t = Tmp::new("pin-mismatch");
    let other = described(
        br#"{"name":"x","idris2":"0.7.0","chez":"10.0.0"}"#,
        SCHEME,
        &[],
    )
    .done();
    write_lock(&t, &sha(&other), other.len(), &[]);
    fs::write(t.p("c.tgz"), &other).unwrap();
    let o = run(&t, &["install", "--from", "c.tgz"], &[]);
    let json = failed(&t, &o, "E-CAPSULE-INVALID", "pin-mismatch", 21);
    assert!(json.contains("0.7.0") && json.contains("0.8.0"), "{json}");
    assert!(store(&t).is_empty());
    // Chez Scheme only: no other Idris 2 than the pinned one, so it installs (exec refuses it later).
    let chez = described(br#"{"name":"chez-only","chez":"10.0.0"}"#, SCHEME, &[]).done();
    write_lock(&t, &sha(&chez), chez.len(), &[]);
    fs::write(t.p("c.tgz"), &chez).unwrap();
    ok(&run(&t, &["install", "--from", "c.tgz"], &[]));
}

#[test]
fn verify_reads_capsule_json_again() {
    let t = Tmp::new("verify-meta");
    let tgz = capsule(SCHEME, &[]);
    write_lock(&t, &sha(&tgz), tgz.len(), &[]);
    fs::write(t.p("c.tgz"), &tgz).unwrap();
    let dir = PathBuf::from(ok(&run(&t, &["install", "--from", "c.tgz"], &[])).trim());
    let sums = fs::read_to_string(dir.join("sha256sums.txt")).unwrap();
    // Each change keeps the list true to the tree, so only the metadata checks can catch it.
    let entry = |json: Option<&[u8]>| {
        let mut list: String = sums
            .lines()
            .filter(|l| !l.ends_with("  capsule.json"))
            .map(|l| format!("{l}\n"))
            .collect();
        match json {
            Some(j) => {
                fs::write(dir.join("capsule.json"), j).unwrap();
                list += &format!("{}  capsule.json\n", sha(j));
            }
            None => fs::remove_file(dir.join("capsule.json")).unwrap(),
        }
        fs::write(dir.join("sha256sums.txt"), list).unwrap();
        failed(
            &t,
            &run(&t, &["verify"], &[]),
            "E-HASH-MISMATCH",
            "store-modified",
            11,
        );
    };
    entry(None);
    entry(Some(br#"{"chez":"10.0.0"}"#));
    entry(Some(br#"{"name":"x","idris2":"0.7.0","chez":"10.0.0"}"#));
}

#[test]
fn loader_libraries_are_not_inherited_by_the_probes() {
    let t = Tmp::new("preload");
    let tgz = capsule(SCHEME, &[]);
    write_lock(&t, &sha(&tgz), tgz.len(), &[]);
    fs::write(t.p("c.tgz"), &tgz).unwrap();
    let env = [
        ("LD_PRELOAD", "/nonexistent/p.so"),
        ("LD_AUDIT", "/nonexistent/a.so"),
    ];
    ok(&run(&t, &["install", "--from", "c.tgz"], &env));
    ok(&run(&t, &["verify"], &env));
}
