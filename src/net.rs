// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! Downloads. https only, or plain http to this machine. TLS is rustls on ring, with the system's trust store.
//! A digest-addressed file resumes with a Range request. The channel manifest, which can change, is never resumed.

use crate::msg::note;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;
use std::time::Duration;

/// A failed copy: reading the source, or writing the destination.
pub enum Io {
    Read(io::Error),
    Write(io::Error),
}
/// A failed download: the disk (fix the disk), or every address (with each one's reason).
pub enum Lost {
    Disk(io::Error),
    Net(String),
}

/// Copy `r` to `w`, keeping a failure to read apart from a failure to write.
pub fn pump(r: &mut impl Read, w: &mut impl Write) -> Result<(), Io> {
    let mut b = vec![0; 1 << 16];
    loop {
        match r.read(&mut b) {
            Ok(0) => return Ok(()),
            Ok(n) => w.write_all(&b[..n]).map_err(Io::Write)?,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(Io::Read(e)),
        }
    }
}

/// https to any host, or plain http to this machine only. The host is the one the request goes to, and an address
/// with a user part (`user@host`) is refused, so `http://localhost:80@example.org/` is not local.
fn allowed(u: &str) -> bool {
    let Ok(u) = u.parse::<ureq::http::Uri>() else {
        return false;
    };
    let Some(a) = u.authority().filter(|a| !a.as_str().contains('@')) else {
        return false;
    };
    match u.scheme_str() {
        Some("https") => true,
        Some("http") => matches!(a.host(), "127.0.0.1" | "localhost" | "[::1]"),
        _ => false,
    }
}

/// A GET whose every hop obeys `allowed`: an https address may redirect only to https, and a local http one may not
/// redirect at all.
fn hop(agent: &ureq::Agent, u: &str) -> ureq::RequestBuilder<ureq::typestate::WithoutBody> {
    // The scheme as `allowed` reads it, so HTTPS://… is the same address as https://….
    let https = u.parse::<ureq::http::Uri>().is_ok_and(|u| u.scheme_str() == Some("https"));
    agent.get(u).config().https_only(https).max_redirects(if https { 10 } else { 0 }).build()
}
/// One GET into `out`, resuming what is there. The body may not exceed what the lock says the file holds.
fn get(agent: &ureq::Agent, out: &Path, u: &str, size: u64) -> Result<(), Io> {
    let have = fs::metadata(out).map_or(0, |m| m.len());
    let mut req = hop(agent, u);
    if have > 0 {
        req = req.header("Range", format!("bytes={have}-"));
    }
    let r = req.call().map_err(|e| Io::Read(io::Error::other(e)))?;
    if !matches!(r.status().as_u16(), 200 | 206) {
        let e = format!("refused: answer {} is not the file", r.status());
        return Err(Io::Read(io::Error::other(e)));
    }
    let more = r.status() == 206;
    let open = OpenOptions::new().create(true).write(true).append(more).truncate(!more).open(out);
    let mut f = open.map_err(Io::Write)?;
    let left = if more { size.saturating_sub(have) } else { size };
    pump(&mut r.into_body().into_with_config().limit(left).reader(), &mut f)?;
    f.sync_all().map_err(Io::Write)
}

const REFUSED: &str = "refused: plain http is allowed only to this machine";
/// The HTTP client: rustls on ring and the system's trust store. `secs` to connect, and for the whole request if
/// `whole`. A read or a write that waits `stall` for data fails, before the answer or in the middle of the body.
fn agent(secs: u64, whole: bool, stall: Duration) -> ureq::Agent {
    use std::sync::Arc;
    use ureq::tls::{RootCerts, TlsConfig};
    let tls = TlsConfig::builder().root_certs(RootCerts::PlatformVerifier);
    let tls =
        tls.unversioned_rustls_crypto_provider(Arc::new(rustls::crypto::ring::default_provider()));
    let t = Some(Duration::from_secs(secs));
    let config = ureq::Agent::config_builder().tls_config(tls.build());
    config
        .timeout_connect(t)
        .timeout_global(t.filter(|_| whole))
        .timeout_per_read(Some(stall))
        .timeout_per_write(Some(stall))
        .build()
        .into()
}
/// doctor's mirror check: one HEAD request, nothing downloaded. The milliseconds it took, or why it failed.
pub fn head(u: &str) -> Result<u128, String> {
    let t0 = std::time::Instant::now();
    if !allowed(u) {
        return Err(REFUSED.into());
    }
    let r = agent(5, true, Duration::from_secs(5)).head(u).call();
    r.map(|_| t0.elapsed().as_millis()).map_err(|e| e.to_string())
}

/// Download to `out` from the first address that works; return that address. Each failure goes to `log`. A mirror
/// that sends nothing for `stall`, before its answer or in the middle of the file, has failed like any other.
pub fn fetch(
    out: &Path,
    urls: &[String],
    size: u64,
    log: &Path,
    stall: Duration,
) -> Result<String, Lost> {
    let (agent, mut tried) = (agent(10, false, stall), vec![]);
    for u in urls {
        let once = || {
            if allowed(u) {
                get(&agent, out, u, size)
            } else {
                Err(Io::Read(io::Error::other(REFUSED)))
            }
        };
        // A resume or a transfer that broke off is tried once more from the start.
        let got = once().or_else(|e| match e {
            Io::Read(_) if out.exists() => {
                fs::remove_file(out).map_err(Io::Write).and_then(|()| once())
            }
            e => Err(e),
        });
        match got {
            Ok(()) => return Ok(u.clone()),
            Err(Io::Write(e)) => return Err(Lost::Disk(e)),
            Err(Io::Read(e)) => {
                let line = format!("{u}: {e}");
                logged(log, &line);
                note(&format!("fetch failed from {u} (trying next mirror)"));
                tried.push(line);
                // The next mirror starts clean: bytes from one that failed are never resumed from another.
                if out.exists() {
                    fs::remove_file(out).map_err(Lost::Disk)?;
                }
            }
        }
    }
    Err(Lost::Net(tried.join("; ")))
}
/// Add a line to the fetch log. The log is a help for people, so a failure to write it is not reported.
pub fn logged(log: &Path, line: &str) {
    let f = OpenOptions::new().create(true).append(true).open(log);
    _ = f.and_then(|mut f| writeln!(f, "{line}"));
}
/// One GET of a document that can change, such as the channel manifest: never resumed, at most 4 MiB, 30 seconds,
/// and redirected only as `hop` allows.
pub fn doc(u: &str) -> Result<Vec<u8>, String> {
    let e = |e: ureq::Error| format!("{u}: {e}");
    if !allowed(u) {
        return Err(format!("{u}: {REFUSED}"));
    }
    let r = hop(&agent(30, true, Duration::from_secs(30)), u).call().map_err(e)?;
    if r.status() != 200 {
        return Err(format!("{u}: refused: answer {} is not the document", r.status()));
    }
    r.into_body().with_config().limit(1 << 22).read_to_vec().map_err(e)
}
