// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! `pin`, run as a user runs it, against a channel served on 127.0.0.1 and signed with a key made for the test
//! (ADR 0008): the lock it writes, and every way it refuses a channel.

mod common;
use common::*;
use ring::signature::{Ed25519KeyPair, KeyPair};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::process::Output;
use std::sync::{Arc, Mutex};

fn b64(b: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::new();
    for c in b.chunks(3) {
        let n = c
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, &x)| n | u32::from(x) << (16 - 8 * i));
        for i in 0..4 {
            s.push(if i <= c.len() {
                A[(n >> (18 - 6 * i) & 63) as usize] as char
            } else {
                '='
            });
        }
    }
    s
}

/// A signify key: "Ed", an 8-byte key id, then the key or the signature.
struct Key {
    pair: Ed25519KeyPair,
    id: [u8; 8],
}
impl Key {
    fn new(id: u8) -> Key {
        let doc = Ed25519KeyPair::generate_pkcs8(&ring::rand::SystemRandom::new()).unwrap();
        Key {
            pair: Ed25519KeyPair::from_pkcs8(doc.as_ref()).unwrap(),
            id: [id; 8],
        }
    }
    fn public(&self) -> String {
        b64(&[&b"Ed"[..], &self.id, self.pair.public_key().as_ref()].concat())
    }
    fn sig(&self, alg: &[u8], body: &[u8]) -> Vec<u8> {
        let s = b64(&[alg, &self.id, self.pair.sign(body).as_ref()].concat());
        format!("untrusted comment: signature from a test key\n{s}\n").into_bytes()
    }
    fn hex(&self) -> String {
        self.id.iter().map(|b| format!("{b:02x}")).collect()
    }
}

type Docs = Arc<Mutex<HashMap<String, Vec<u8>>>>;
/// A channel on 127.0.0.1: the documents it serves, the paths it was asked for, and a project directory that names it
/// in idris2x.toml.
struct Chan {
    t: Tmp,
    key: Key,
    url: String,
    docs: Docs,
    hits: Arc<Mutex<Vec<String>>>,
}
impl Chan {
    fn new(name: &str) -> Chan {
        let (docs, hits): (Docs, Arc<Mutex<Vec<String>>>) = Default::default();
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!(
            "http://127.0.0.1:{}/v1.json",
            l.local_addr().unwrap().port()
        );
        let (d, h) = (Arc::clone(&docs), Arc::clone(&hits));
        std::thread::spawn(move || {
            for s in l.incoming().flatten() {
                let mut r = BufReader::new(s.try_clone().unwrap());
                let mut first = String::new();
                _ = r.read_line(&mut first);
                let mut line = String::new();
                while r.read_line(&mut line).unwrap_or(0) > 0 && line != "\r\n" {
                    line.clear();
                }
                let path = first.split(' ').nth(1).unwrap_or_default().to_owned();
                h.lock().unwrap().push(path.clone());
                let body = d.lock().unwrap().get(&path).cloned();
                let (code, body) = body.map_or((404, b"no".to_vec()), |b| (200, b));
                let mut s = s;
                let head = format!(
                    "HTTP/1.1 {code} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                _ = s
                    .write_all(head.as_bytes())
                    .and_then(|()| s.write_all(&body));
            }
        });
        let c = Chan {
            t: Tmp::new(name),
            key: Key::new(1),
            url,
            docs,
            hits,
        };
        c.toml("0.8.0", &c.key.public());
        c
    }
    fn toml(&self, idris2: &str, key: &str) {
        let text = format!(
            "# a project\n[toolchain]\nidris2 = \"{idris2}\"\n\n[channel]  # where to pin from\nurl = \"{}\"\nkey = \"{key}\" # its signify key\n",
            self.url
        );
        fs::write(self.t.p("idris2x.toml"), text).unwrap();
    }
    /// Serve `m` and a signature of it with `alg` ("Ed", or a pre-hashed "ED") by `by`.
    fn publish_as(&self, m: &Value, by: &Key, alg: &[u8]) {
        let body = serde_json::to_vec(m).unwrap();
        let mut d = self.docs.lock().unwrap();
        d.insert("/v1.json.sig".into(), by.sig(alg, &body));
        d.insert("/v1.json".into(), body);
    }
    fn publish(&self, m: &Value) {
        self.publish_as(m, &self.key, b"Ed");
    }
    fn pin(&self, ver: &str, env: &[(&str, &str)]) -> Output {
        run(&self.t, &["pin", ver], env)
    }
    fn hits(&self) -> usize {
        self.hits.lock().unwrap().len()
    }
    fn lock(&self) -> Value {
        serde_json::from_slice(&fs::read(self.t.p("idris2x.lock")).unwrap()).unwrap()
    }
    /// The manifests kept in the cache.
    fn kept(&self) -> usize {
        fs::read_dir(self.t.p("cache/manifests")).map_or(0, |d| d.count())
    }
}

const DIGEST: &str = "0d7a4c1e9b52f6a83c07d1e45b9a2f6c8e13d7b0a5942c6f1e8d3b7a094c5e21";
fn manifest() -> Value {
    let mut m = json!({"schema": 1, "channel_version": 3, "expires": "2096-02-29T23:59:59Z", "deprecated": [],
        "compat": {"idris2@0.8.0": {"chez": "10.0.0", "platforms": [target()]}}});
    m["bundles"]["idris2@0.8.0"][target()] = json!({"sha256": DIGEST, "size": 10, "chez": "10.0.0",
        "urls": ["https://example.org/c.tgz"], "min_glibc": "2.17", "provenance": "https://example.org/p"});
    m
}
fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

#[test]
fn pin_writes_a_lock_that_the_executor_reads_and_pins_again_offline() {
    let c = Chan::new("pin-ok");
    c.publish(&manifest());
    let o = c.pin("0.8.0", &[]);
    ok(&o);
    let t = target();
    assert!(
        stderr(&o).contains(&format!(
            "pinned idris2 0.8.0 (channel v3) into idris2x.lock for: {t}"
        )),
        "{}",
        stderr(&o)
    );
    let lock = c.lock();
    assert_eq!(lock["schema"], 1);
    assert_eq!(
        lock["toolchain"],
        json!({"idris2": "0.8.0", "chez": "10.0.0"})
    );
    assert_eq!(
        lock["channel"],
        json!({"version": 3, "url": c.url, "key": c.key.hex()})
    );
    let want = json!({"sha256": DIGEST, "size": 10, "urls": ["https://example.org/c.tgz"], "min_glibc": "2.17"});
    let mut caps = json!({});
    caps[&t] = want;
    assert_eq!(
        lock["capsules"], caps,
        "only the fields the lock reader checks are copied"
    );
    // The executor reads that lock with no channel: verify gets as far as the store.
    failed(
        &c.t,
        &run(&c.t, &["verify"], &[]),
        "E-PIN-NOT-FOUND",
        "not-installed",
        10,
    );
    assert_eq!(
        c.kept(),
        1,
        "the manifest and its signature are kept, as one file, once they verify"
    );

    // Offline, the kept copy is used, verified again, and nothing is fetched.
    let before = c.hits();
    ok(&c.pin("0.8.0", &[("IDRIS2X_OFFLINE", "1")]));
    assert_eq!(c.hits(), before);
    let kept = fs::read_dir(c.t.p("cache/manifests")).unwrap().flatten();
    let body = kept
        .map(|e| e.path())
        .find(|p| p.extension().is_some_and(|e| e == "sig"))
        .unwrap();
    fs::OpenOptions::new()
        .append(true)
        .open(&body)
        .unwrap()
        .write_all(b" ")
        .unwrap();
    failed(
        &c.t,
        &c.pin("0.8.0", &[("IDRIS2X_OFFLINE", "1")]),
        "E-SIG-INVALID",
        "bad-signature",
        12,
    );
    // A channel never fetched has no kept copy.
    fs::write(
        c.t.p("idris2x.toml"),
        fs::read_to_string(c.t.p("idris2x.toml"))
            .unwrap()
            .replace("v1.json", "v2.json"),
    )
    .unwrap();
    failed(
        &c.t,
        &c.pin("0.8.0", &[("IDRIS2X_OFFLINE", "1")]),
        "E-OFFLINE",
        "no-manifest",
        20,
    );
    assert_eq!(c.hits(), before);
}

#[test]
fn nothing_unverified_is_kept_or_written() {
    let c = Chan::new("pin-sig");
    let other = Key::new(2);
    c.publish_as(&manifest(), &other, b"Ed");
    let j = failed(&c.t, &c.pin("0.8.0", &[]), "E-SIG-INVALID", "wrong-key", 12);
    assert!(
        j.contains(&format!(r#""signer":"key id {}""#, other.hex())),
        "{j}"
    );
    assert!(
        j.contains(&format!(r#""key":"key id {}""#, c.key.hex())),
        "{j}"
    );
    // Signed by a key with the same id: the signature itself fails.
    c.publish_as(&manifest(), &Key::new(1), b"Ed");
    failed(
        &c.t,
        &c.pin("0.8.0", &[]),
        "E-SIG-INVALID",
        "bad-signature",
        12,
    );
    // The body changed after signing.
    c.publish(&manifest());
    c.docs
        .lock()
        .unwrap()
        .get_mut("/v1.json")
        .unwrap()
        .push(b' ');
    failed(
        &c.t,
        &c.pin("0.8.0", &[]),
        "E-SIG-INVALID",
        "bad-signature",
        12,
    );
    // A pre-hashed signature is refused, not verified some other way.
    c.publish_as(&manifest(), &c.key, b"ED");
    failed(&c.t, &c.pin("0.8.0", &[]), "E-SIG-INVALID", "malformed", 12);
    c.docs
        .lock()
        .unwrap()
        .insert("/v1.json.sig".into(), b"one line only\n".to_vec());
    failed(&c.t, &c.pin("0.8.0", &[]), "E-SIG-INVALID", "malformed", 12);
    // A key in idris2x.toml that is not a signify Ed25519 public key.
    c.toml("0.8.0", "not a key");
    let j = failed(&c.t, &c.pin("0.8.0", &[]), "E-SIG-INVALID", "malformed", 12);
    assert!(j.contains("idris2x.toml"), "{j}");
    assert_eq!(c.kept(), 0);
    assert!(!c.t.p("idris2x.lock").exists());
}

#[test]
fn rollback_expiry_and_newer_formats_are_refused_and_leave_the_lock_alone() {
    let c = Chan::new("pin-gates");
    let old = format!(
        r#"{{"schema":1,"channel":{{"version":5,"url":"{}"}}}}"#,
        c.url
    );
    fs::write(c.t.p("idris2x.lock"), &old).unwrap();
    c.publish(&manifest());
    let j = failed(
        &c.t,
        &c.pin("0.8.0", &[]),
        "E-CHANNEL-ROLLBACK",
        "version-went-back",
        22,
    );
    assert!(
        j.contains(r#""seen":"5""#) && j.contains(r#""offered":"3""#),
        "{j}"
    );
    assert_eq!(fs::read_to_string(c.t.p("idris2x.lock")).unwrap(), old);
    // Versions of another channel do not compare.
    fs::write(
        c.t.p("idris2x.lock"),
        old.replace("v1.json", "elsewhere.json"),
    )
    .unwrap();
    ok(&c.pin("0.8.0", &[]));
    // A lock that cannot be read, or does not say what it saw, never starts the count again.
    let lf = c.t.p("idris2x.lock");
    // A missing or malformed address is not another channel, and another channel still records a version.
    let damaged = [
        old.replace(r#""version":5"#, r#""version":"5""#),
        old[..20].to_owned(),
        old.replace(&format!(r#","url":"{}""#, c.url), ""),
        old.replace(&format!(r#""{}""#, c.url), "7"),
        old.replace(r#""version":5,"#, "")
            .replace("v1.json", "elsewhere.json"),
        r#"{"schema":1}"#.into(),
        "null".into(),
    ];
    for text in damaged {
        fs::write(&lf, &text).unwrap();
        let (e, case) = ("E-CHANNEL-ROLLBACK", "seen-version-unknown");
        failed(&c.t, &c.pin("0.8.0", &[]), e, case, 22);
        assert_eq!(fs::read_to_string(&lf).unwrap(), text);
    }
    fs::remove_file(&lf).unwrap();
    fs::create_dir(&lf).unwrap();
    failed(
        &c.t,
        &c.pin("0.8.0", &[]),
        "E-CHANNEL-ROLLBACK",
        "seen-version-unknown",
        22,
    );
    fs::remove_dir(&lf).unwrap();

    let mut m = manifest();
    m["expires"] = json!("2001-01-01T00:00:00Z");
    c.publish(&m);
    failed(
        &c.t,
        &c.pin("0.8.0", &[]),
        "E-CHANNEL-EXPIRED",
        "expired",
        23,
    );
    let o = c.pin("0.8.0", &[("IDRIS2X_ALLOW_EXPIRED", "1")]);
    ok(&o);
    assert!(
        stderr(&o).contains("IDRIS2X_ALLOW_EXPIRED=1: using a channel manifest that has expired")
    );
    // A time before 1970 is a real time: it has expired, and the override still applies.
    for t in ["1969-12-31T23:59:59Z", "0000-01-01T00:00:00Z"] {
        m["expires"] = json!(t);
        c.publish(&m);
        let j = failed(
            &c.t,
            &c.pin("0.8.0", &[]),
            "E-CHANNEL-EXPIRED",
            "expired",
            23,
        );
        assert!(j.contains(&format!(r#""expires":"{t}""#)), "{j}");
        ok(&c.pin("0.8.0", &[("IDRIS2X_ALLOW_EXPIRED", "1")]));
    }
    failed(
        &c.t,
        &c.pin("0.8.0", &[("IDRIS2X_ALLOW_EXPIRED", "yes")]),
        "E-USAGE",
        "bad-setting",
        2,
    );
    // The lock's path and the store are read as strictly: no guessed lock, no store in the working directory.
    use std::os::unix::ffi::OsStrExt;
    let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_idris2x"));
    cmd.env_clear()
        .current_dir(&c.t.0)
        .args(["pin", "0.8.0"])
        .env("PATH", "/usr/bin:/bin");
    cmd.env("IDRIS2X_CACHE", c.t.p("cache"))
        .env("IDRIS2X_ERROR_FILE", c.t.p("error.json"));
    let not_text = std::ffi::OsStr::from_bytes(b"idris2x\xff.lock");
    let o = cmd.env("IDRIS2X_LOCK", not_text).output().unwrap();
    failed(&c.t, &o, "E-USAGE", "bad-setting", 2);
    let nowhere = c.pin("0.8.0", &[("IDRIS2X_CACHE", "")]);
    failed(&c.t, &nowhere, "E-STORE-IO", "no-cache-dir", 24);
    assert!(!c.t.p(".cache").exists());

    let mut m = manifest();
    m["schema"] = json!(2);
    c.publish(&m);
    failed(
        &c.t,
        &c.pin("0.8.0", &[]),
        "E-CHANNEL-SCHEMA",
        "channel-newer",
        18,
    );
    let mut m = manifest();
    m["min_launcher"] = json!("99.0.0");
    c.publish(&m);
    let j = failed(
        &c.t,
        &c.pin("0.8.0", &[]),
        "E-CHANNEL-SCHEMA",
        "needs-newer-launcher",
        18,
    );
    assert!(j.contains(r#""needs":"99.0.0""#), "{j}");
    m["min_launcher"] = json!("0.0.1");
    c.publish(&m);
    ok(&c.pin("0.8.0", &[]));
}

#[test]
fn a_refused_manifest_never_replaces_the_copy_kept_for_offline_pins() {
    let c = Chan::new("pin-keep");
    let mut m = manifest();
    m["channel_version"] = json!(5);
    c.publish(&m);
    ok(&c.pin("0.8.0", &[]));
    // An older manifest, then an expired one: each verifies, each is refused, and neither is kept.
    c.publish(&manifest());
    let (e, case) = ("E-CHANNEL-ROLLBACK", "version-went-back");
    failed(&c.t, &c.pin("0.8.0", &[]), e, case, 22);
    m["channel_version"] = json!(6);
    m["expires"] = json!("2001-01-01T00:00:00Z");
    c.publish(&m);
    let (e, case) = ("E-CHANNEL-EXPIRED", "expired");
    failed(&c.t, &c.pin("0.8.0", &[]), e, case, 23);
    // Offline, pin still reads the version 5 that made the lock.
    ok(&c.pin("0.8.0", &[("IDRIS2X_OFFLINE", "1")]));
    assert_eq!(c.lock()["channel"]["version"], 5);
}

#[test]
fn a_pin_that_waited_writes_nothing_if_idris2x_toml_changed_its_channel() {
    let c = Chan::new("pin-moved");
    c.publish(&manifest());
    let f = fs::File::open(fs::canonicalize(c.t.p("")).unwrap()).unwrap();
    f.lock().unwrap();
    let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_idris2x"));
    cmd.env_clear()
        .current_dir(c.t.p(""))
        .args(["pin", "0.8.0"]);
    cmd.env("PATH", "/usr/bin:/bin")
        .env("IDRIS2X_CACHE", c.t.p("cache"))
        .env("IDRIS2X_ERROR_FILE", c.t.p("error.json"));
    let child = cmd.stderr(std::process::Stdio::piped()).spawn().unwrap();
    // The pin has the manifest and its signature, and waits for its turn; then the project names another key.
    let start = std::time::Instant::now();
    while c.hits() < 2 && start.elapsed().as_secs() < 30 {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let other = Key::new(2).public();
    c.toml("0.8.0", &other);
    drop(f);
    let o = child.wait_with_output().unwrap();
    let j = failed(&c.t, &o, "E-PIN-DRIFT", "channel-changed", 19);
    assert!(j.contains(&other) && j.contains(&c.key.public()), "{j}");
    assert!(!c.t.p("idris2x.lock").exists());
    assert_eq!(c.kept(), 0);
}

#[test]
fn a_malformed_manifest_is_refused_by_field() {
    let c = Chan::new("pin-malformed");
    let cases: [(&str, Value, &str); 15] = [
        ("/expires", json!("2099-01-01"), "expires"),
        // Not a real time: refused, never read as the far future.
        ("/expires", json!("2099-99-99T99:99:99Z"), "expires"),
        ("/expires", json!("2099-02-29T00:00:00Z"), "expires"),
        ("/expires", json!("+099-01-01T00:00:00Z"), "expires"),
        ("/expires", json!("-001-01-01T00:00:00Z"), "expires"),
        ("/channel_version", json!(-1), "channel_version"),
        ("/min_launcher", json!(5), "min_launcher"),
        // A version too large to compare is refused, never read as 0.
        (
            "/min_launcher",
            json!("18446744073709551616.0"),
            "min_launcher",
        ),
        (
            "/bundles/idris2@0.8.0/T/min_glibc",
            json!("2.18446744073709551616"),
            "capsule entry",
        ),
        ("/deprecated", json!("idris2@0.8.0"), "deprecated"),
        (
            "/compat/idris2@0.8.0/chez",
            json!("10.0.0; rm -rf ~"),
            "chez version",
        ),
        (
            "/bundles/idris2@0.8.0/T/sha256",
            json!("ab"),
            "capsule entry",
        ),
        (
            "/bundles/idris2@0.8.0/T/urls",
            json!(["https://a", 7]),
            "capsule entry",
        ),
        // A capsule with nowhere to fetch it from could never install.
        ("/bundles/idris2@0.8.0/T/urls", json!([]), "capsule entry"),
        (
            "/bundles/idris2@0.8.0/T/min_glibc",
            json!("new"),
            "capsule entry",
        ),
    ];
    for (at, v, field) in cases {
        let mut m = manifest();
        match m.pointer_mut(&at.replace("/T/", &format!("/{}/", target()))) {
            Some(x) => *x = v,
            None => m[&at[1..]] = v,
        }
        c.publish(&m);
        let j = failed(
            &c.t,
            &c.pin("0.8.0", &[]),
            "E-CHANNEL-SCHEMA",
            "malformed-manifest",
            18,
        );
        assert!(j.contains(&format!(r#""field":"{field}""#)), "{at}: {j}");
    }
    let mut d = c.docs.lock().unwrap();
    let body = b"not json".to_vec();
    d.insert("/v1.json.sig".into(), c.key.sig(b"Ed", &body));
    d.insert("/v1.json".into(), body);
    drop(d);
    let j = failed(
        &c.t,
        &c.pin("0.8.0", &[]),
        "E-CHANNEL-SCHEMA",
        "malformed-manifest",
        18,
    );
    assert!(j.contains(r#""field":"body (it is not JSON)""#), "{j}");
    assert!(!c.t.p("idris2x.lock").exists());
}

#[test]
fn a_missing_version_lists_the_others_and_a_deprecated_one_pins_with_a_note() {
    let c = Chan::new("pin-versions");
    let mut m = manifest();
    m["deprecated"] = json!([
        "idris2@0.7.0",
        "idris2@0.8.0: \u{1b}[31mmoved, see https://evil.example"
    ]);
    c.publish(&m);
    let j = failed(
        &c.t,
        &c.pin("0.9.9", &[]),
        "E-PIN-NOT-FOUND",
        "no-version",
        10,
    );
    assert!(j.contains(r#""available":"0.8.0""#), "{j}");
    let o = c.pin("0.8.0", &[]);
    ok(&o);
    let err = stderr(&o);
    assert!(
        err.contains("idris2 0.8.0 is deprecated in this channel."),
        "{err}"
    );
    assert!(
        !err.contains("evil") && !err.contains("moved"),
        "the channel's words are not shown: {err}"
    );
    assert_eq!(c.lock()["toolchain"]["idris2"], "0.8.0");
}

#[test]
fn idris2x_toml_is_read_strictly_and_a_lock_it_no_longer_matches_is_refused() {
    let c = Chan::new("pin-toml");
    c.publish(&manifest());
    ok(&c.pin("0.8.0", &[]));
    // I1: idris2x.toml moved on and the lock did not, so the executor refuses the lock.
    c.toml("0.7.0", &c.key.public());
    let j = failed(
        &c.t,
        &run(&c.t, &["verify"], &[]),
        "E-PIN-DRIFT",
        "toml-vs-lock",
        19,
    );
    assert!(
        j.contains(r#""toml":"0.7.0""#) && j.contains(r#""locked":"0.8.0""#),
        "{j}"
    );
    failed(
        &c.t,
        &run(&c.t, &["install", "--locked"], &[]),
        "E-PIN-DRIFT",
        "toml-vs-lock",
        19,
    );

    let bad = [
        (
            "[toolchain]\nidris2 = \"0.8.0\"\ncolour = \"red\"\n",
            "line 3",
        ),
        (
            "[toolchain]\nidris2 = \"0.8.0\"\nidris2 = \"0.8.0\"\n",
            "line 3",
        ),
        ("[toolchain]\nidris2 = 0.8.0\n", "line 2"),
        ("[toolchain]\nidris2 = \"0.8.0\\\"\"\n", "line 2"),
        ("[tool\nidris2 = \"0.8.0\"\n", "line 1"),
        ("[]\n[toolchain]\nidris2 = \"0.8.0\"\n", "line 1"),
        ("[toolchain]\nidris2 = \"0.8.0\"\n[foo]\n", "line 3"),
        // The same table twice, even with other keys: TOML refuses it, so idris2x does too.
        (
            "[toolchain]\nidris2 = \"0.8.0\"\n[channel]\nurl = \"http://127.0.0.1:1/v1.json\"\n[channel]\nkey = \"k\"\n",
            "line 5",
        ),
        ("[toolchain]\nidris2 = \"latest\"\n", "the end of the file"),
        (
            "[channel]\nurl = \"http://127.0.0.1:1/v1.json\"\n[toolchain]\nidris2 = \"0.8.0\"\n",
            "the end of the file",
        ),
    ];
    for (text, at) in bad {
        fs::write(c.t.p("idris2x.toml"), text).unwrap();
        let j = failed(&c.t, &c.pin("0.8.0", &[]), "E-PIN-DRIFT", "bad-toml", 19);
        assert!(j.contains(&format!(r#""at":"{at}""#)), "{text:?}: {j}");
    }
    fs::write(c.t.p("idris2x.toml"), "[toolchain]\nidris2 = \"0.8.0\"\n").unwrap();
    failed(&c.t, &c.pin("0.8.0", &[]), "E-USAGE", "no-channel", 2);
    fs::remove_file(c.t.p("idris2x.toml")).unwrap();
    failed(&c.t, &c.pin("0.8.0", &[]), "E-USAGE", "no-channel", 2);
    failed(
        &c.t,
        &run(&c.t, &["pin"], &[]),
        "E-USAGE",
        "missing-argument",
        2,
    );
    failed(
        &c.t,
        &run(&c.t, &["pin", "0.8.0", "--force"], &[]),
        "E-USAGE",
        "unknown-flag",
        2,
    );
}

#[test]
fn an_unreachable_or_plain_http_channel_is_e_network() {
    let c = Chan::new("pin-net");
    for url in ["http://127.0.0.1:1/v1.json", "http://example.org/v1.json"] {
        let text = format!(
            "[toolchain]\nidris2 = \"0.8.0\"\n[channel]\nurl = \"{url}\"\nkey = \"{}\"\n",
            c.key.public()
        );
        fs::write(c.t.p("idris2x.toml"), text).unwrap();
        let j = failed(
            &c.t,
            &c.pin("0.8.0", &[]),
            "E-NETWORK",
            "manifest-unreachable",
            14,
        );
        assert!(j.contains(&format!(r#""url":"{url}""#)), "{j}");
    }
    let log = fs::read_to_string(c.t.p("cache/staging/fetch.log")).unwrap();
    assert!(log.contains("http://example.org/v1.json"), "{log}");
    // A local channel may not redirect: the answer is refused, never followed.
    let (moved, hits) = serve(vec![], 302, None);
    let text = format!(
        "[toolchain]\nidris2 = \"0.8.0\"\n[channel]\nurl = \"{moved}\"\nkey = \"{}\"\n",
        c.key.public()
    );
    fs::write(c.t.p("idris2x.toml"), text).unwrap();
    let j = failed(
        &c.t,
        &c.pin("0.8.0", &[]),
        "E-NETWORK",
        "manifest-unreachable",
        14,
    );
    assert!(
        j.contains("refused: answer 302 Found is not the document"),
        "{j}"
    );
    assert_eq!(hits.lock().unwrap().len(), 1);
}

#[test]
fn pins_of_one_lock_take_turns_and_a_held_turn_times_out() {
    let c = Chan::new("pin-turn");
    c.publish(&manifest());
    // The turn is the lock file's real directory, held as another pin holds it, so a pin waits for it whichever cache
    // it uses and however the path is spelled.
    let f = fs::File::open(fs::canonicalize(c.t.p("")).unwrap()).unwrap();
    f.lock().unwrap();
    fs::create_dir(c.t.p("sub")).unwrap();
    let other = c.t.p("other-cache");
    let spelled = c.t.p("sub/../idris2x.lock");
    for env in [
        vec![],
        vec![("IDRIS2X_CACHE", other.to_str().unwrap())],
        vec![("IDRIS2X_LOCK", spelled.to_str().unwrap())],
    ] {
        let o = c.pin(
            "0.8.0",
            &[env, vec![("IDRIS2X_LOCK_TIMEOUT", "1")]].concat(),
        );
        let j = failed(&c.t, &o, "E-LOCK-TIMEOUT", "pin-held", 15);
        assert!(
            j.contains(r#""holder":"unknown (the holder left no record)""#),
            "{j}"
        );
        assert!(!c.t.p("idris2x.lock").exists());
    }
    drop(f);
    ok(&c.pin("0.8.0", &[("IDRIS2X_CACHE", other.to_str().unwrap())]));
    ok(&c.pin("0.8.0", &[]));
    // Nothing is left in the project but the lock itself.
    let mut left: Vec<_> = fs::read_dir(c.t.p(""))
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    left.sort();
    assert!(
        left.iter().all(|n| [
            "cache",
            "other-cache",
            "sub",
            "idris2x.lock",
            "idris2x.toml",
            "error.json"
        ]
        .contains(&n.to_str().unwrap())),
        "{left:?}"
    );
}
