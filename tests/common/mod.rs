// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! Shared by the integration tests: a scratch directory, a fake capsule whose Chez is a shell script, a lock for it,
//! a local HTTP server, and the launcher run as a user runs it. Each test file uses only some of these.
#![allow(dead_code)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::{Arc, Mutex};

pub const SCHEME: &str = "#!/bin/sh
# A stand-in for Chez: the reset environment must hold, or the probe sees a wrong answer.
[ \"$IDRIS2_PREFIX\" = \"$IDRIS2X_CAPSULE\" ] || { echo prefix leaked; exit 1; }
[ -z \"$IDRIS2_PACKAGE_PATH\" ] || { echo package path leaked; exit 1; }
[ -z \"$LD_PRELOAD$LD_AUDIT\" ] || { echo loader library leaked; exit 1; }
case \"$1\" in
  -q) cat >/dev/null; printf 42 ;;
  --program) echo 'Idris 2, version 0.8.0' ;;
  *) exit 1 ;;
esac
";

pub fn sha(b: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, b)
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// A scratch directory per test, removed when the test passes.
pub struct Tmp(pub PathBuf);
impl Tmp {
    pub fn new(name: &str) -> Tmp {
        let d = std::env::temp_dir().join(format!("idris2x-install-{name}-{}", std::process::id()));
        _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        Tmp(d)
    }
    pub fn p(&self, rel: &str) -> PathBuf {
        self.0.join(rel)
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            _ = fs::remove_dir_all(&self.0);
        }
    }
}

/// A tar.gz built from raw headers, so a test can write names and modes that tar::Builder would refuse.
pub struct Tgz(tar::Builder<flate2::write::GzEncoder<Vec<u8>>>);
impl Tgz {
    pub fn new() -> Tgz {
        Tgz(tar::Builder::new(flate2::write::GzEncoder::new(
            vec![],
            flate2::Compression::fast(),
        )))
    }
    pub fn entry(
        mut self,
        kind: tar::EntryType,
        name: &str,
        mode: u32,
        link: &str,
        data: &[u8],
    ) -> Tgz {
        let mut h = tar::Header::new_gnu();
        h.as_gnu_mut().unwrap().name[..name.len()].copy_from_slice(name.as_bytes());
        h.as_gnu_mut().unwrap().linkname[..link.len()].copy_from_slice(link.as_bytes());
        h.set_entry_type(kind);
        h.set_mode(mode);
        h.set_size(data.len() as u64);
        h.set_cksum();
        self.0.append(&h, data).unwrap();
        self
    }
    pub fn file(self, name: &str, data: &[u8]) -> Tgz {
        self.entry(tar::EntryType::Regular, name, 0o644, "", data)
    }
    pub fn done(self) -> Vec<u8> {
        self.0.into_inner().unwrap().finish().unwrap()
    }
}

/// A capsule whose probes pass, with `extra` files listed in sha256sums.txt.
pub fn capsule(scheme: &str, extra: &[(&str, &[u8])]) -> Vec<u8> {
    capsule_tgz(scheme, extra).done()
}
pub fn capsule_tgz(scheme: &str, extra: &[(&str, &[u8])]) -> Tgz {
    described(
        br#"{"name":"idris2-test","idris2":"0.8.0","chez":"10.0.0","exec":{"chez":["bin/scheme"],"idris2":["bin/scheme","--program","bin/idris2_app/idris2.so"]}}"#,
        scheme,
        extra,
    )
}
/// The same capsule with another capsule.json, listed in sha256sums.txt like every file.
pub fn described(json: &[u8], scheme: &str, extra: &[(&str, &[u8])]) -> Tgz {
    let mut files: Vec<(&str, &[u8])> =
        vec![("capsule.json", json), ("bin/idris2_app/idris2.so", b"so")];
    files.extend_from_slice(extra);
    let sums: String = files
        .iter()
        .map(|(n, b)| format!("{}  {n}\n", sha(b)))
        .collect();
    let sums = format!("{sums}{}  bin/scheme\n", sha(scheme.as_bytes()));
    let mut t = Tgz::new().entry(tar::EntryType::Directory, "bin/", 0o755, "", b"");
    t = t.entry(
        tar::EntryType::Regular,
        "bin/scheme",
        0o755,
        "",
        scheme.as_bytes(),
    );
    for (n, b) in files {
        t = t.file(n, b);
    }
    t.file("sha256sums.txt", sums.as_bytes())
}

pub fn target() -> String {
    idris2x::lock::target()
        .ok()
        .expect("this test runs on a supported target")
}
pub fn write_lock(t: &Tmp, digest: &str, size: usize, urls: &[String]) {
    let urls = serde_json::to_string(urls).unwrap();
    let c = format!(r#"{{"sha256":"{digest}","size":{size},"urls":{urls}}}"#);
    let lock = format!(
        r#"{{"schema":1,"toolchain":{{"idris2":"0.8.0"}},"capsules":{{"{}":{c}}}}}"#,
        target()
    );
    fs::write(t.p("idris2x.lock"), lock).unwrap();
}

/// An HTTP/1.1 server on 127.0.0.1 that serves `body` at every path, honours Range, and logs "<status> <range>".
/// With `cut`, it sends only that many bytes of a full response and then closes the connection.
pub fn serve(body: Vec<u8>, status: u16, cut: Option<usize>) -> (String, Arc<Mutex<Vec<String>>>) {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let (url, log) = (
        format!(
            "http://127.0.0.1:{}/capsule.tar.gz",
            l.local_addr().unwrap().port()
        ),
        Arc::default(),
    );
    let seen: Arc<Mutex<Vec<String>>> = Arc::clone(&log);
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut from = None;
            loop {
                let mut line = String::new();
                if r.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                    break;
                }
                if let Some(v) = line.to_ascii_lowercase().strip_prefix("range: bytes=") {
                    from = v.trim().trim_end_matches('-').parse::<usize>().ok();
                }
            }
            let mut s = s;
            let (code, part) = match from {
                _ if status != 200 => (status, &b"no"[..]),
                Some(f) => (206, &body[f.min(body.len())..]),
                None => (200, &body[..cut.unwrap_or(body.len())]),
            };
            seen.lock().unwrap().push(format!("{code} {from:?}"));
            let len = if cut.is_some() && from.is_none() {
                body.len()
            } else {
                part.len()
            };
            // A redirect points back here, so a hop that was followed shows in the log.
            let to = if (300..400).contains(&code) {
                "Location: /moved\r\n"
            } else {
                ""
            };
            _ = write!(
                s,
                "HTTP/1.1 {code} X\r\n{to}Content-Length: {len}\r\nConnection: close\r\n\r\n"
            );
            _ = s.write_all(part);
        }
    });
    (url, log)
}
/// An HTTP server on 127.0.0.1 that answers nothing (`head` false) or sends headers and 10 bytes of a longer file
/// (`head` true), then holds the connection open without sending more.
pub fn stall(head: bool) -> String {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!(
        "http://127.0.0.1:{}/c.tar.gz",
        l.local_addr().unwrap().port()
    );
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            std::thread::spawn(move || {
                let mut r = BufReader::new(s.try_clone().unwrap());
                let mut line = String::new();
                while r.read_line(&mut line).unwrap_or(0) > 0 && line != "\r\n" {
                    line.clear();
                }
                let mut s = s;
                if head {
                    _ = write!(
                        s,
                        "HTTP/1.1 200 X\r\nContent-Length: 100000\r\n\r\n0123456789"
                    );
                    _ = s.flush();
                }
                std::thread::sleep(std::time::Duration::from_secs(120));
            });
        }
    });
    url
}

pub fn run(t: &Tmp, args: &[&str], env: &[(&str, &str)]) -> Output {
    let mut c = Command::new(env!("CARGO_BIN_EXE_idris2x"));
    c.env_clear().current_dir(&t.0).args(args);
    c.env("PATH", "/usr/bin:/bin")
        .env("IDRIS2X_CACHE", t.p("cache"))
        .env("IDRIS2X_ERROR_FILE", t.p("error.json"));
    c.envs(env.iter().copied()).output().unwrap()
}
/// The launcher failed with this error id and case, and its exit code.
pub fn failed(t: &Tmp, o: &Output, id: &str, case: &str, exit: i32) -> String {
    let json = fs::read_to_string(t.p("error.json")).unwrap_or_default();
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(
        json.contains(&format!(r#""id":"{id}","case":"{case}""#)),
        "want {id} {case}, got {json}\n{err}"
    );
    assert_eq!(o.status.code(), Some(exit), "{err}");
    fs::remove_file(t.p("error.json")).unwrap();
    json
}
pub fn ok(o: &Output) -> String {
    assert_eq!(
        o.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8(o.stdout.clone()).unwrap()
}
pub fn store(t: &Tmp) -> Vec<String> {
    let d = fs::read_dir(t.p("cache/store"))
        .map(|d| d.flatten().map(|e| e.file_name().into_string().unwrap()));
    d.map(Iterator::collect).unwrap_or_default()
}
