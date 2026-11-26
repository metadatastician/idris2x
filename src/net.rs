// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// MPL-2.0 (code) and CC-BY-SA-4.0 (prose). Error wording is not here: it is in src/errors/errors.toml.
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (metadatastician) <j.d.a.jewell@open.ac.uk>
//! Downloads. https only, or plain http to this machine. TLS is rustls on ring, with the system's trust store.
//! Only digest-addressed files come through here, so a partial file resumes with a Range request.

use crate::msg::note;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;

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

fn allowed(u: &str) -> bool {
    let local = ["http://127.0.0.1", "http://localhost", "http://[::1]"].iter();
    let local = local
        .filter_map(|h| u.strip_prefix(h))
        .any(|r| r.is_empty() || r.starts_with([':', '/']));
    u.starts_with("https://") || local
}

/// One GET into `out`, resuming what is there. The body may not exceed what the lock says the file holds.
fn get(agent: &ureq::Agent, out: &Path, u: &str, size: u64) -> Result<(), Io> {
    let have = fs::metadata(out).map_or(0, |m| m.len());
    let mut req = agent.get(u);
    if have > 0 {
        req = req.header("Range", format!("bytes={have}-"));
    }
    let r = req.call().map_err(|e| Io::Read(io::Error::other(e)))?;
    let more = r.status() == 206;
    let open = OpenOptions::new()
        .create(true)
        .write(true)
        .append(more)
        .truncate(!more)
        .open(out);
    let mut f = open.map_err(Io::Write)?;
    let left = if more {
        size.saturating_sub(have)
    } else {
        size
    };
    pump(
        &mut r.into_body().into_with_config().limit(left).reader(),
        &mut f,
    )?;
    f.sync_all().map_err(Io::Write)
}

/// Download to `out` from the first address that works; return that address. Each failure goes to `log`.
pub fn fetch(out: &Path, urls: &[String], size: u64, log: &Path) -> Result<String, Lost> {
    use std::sync::Arc;
    use ureq::tls::{RootCerts, TlsConfig};
    let tls = TlsConfig::builder().root_certs(RootCerts::PlatformVerifier);
    let tls =
        tls.unversioned_rustls_crypto_provider(Arc::new(rustls::crypto::ring::default_provider()));
    let ten = Some(std::time::Duration::from_secs(10));
    let agent = ureq::Agent::config_builder()
        .tls_config(tls.build())
        .timeout_connect(ten)
        .build()
        .into();
    let mut tried = vec![];
    for u in urls {
        let refused = || {
            Io::Read(io::Error::other(
                "refused: plain http is allowed only to this machine",
            ))
        };
        let once = || {
            if allowed(u) {
                get(&agent, out, u, size)
            } else {
                Err(refused())
            }
        };
        // A resume or a transfer that broke off is tried once more from the start.
        let got = once().or_else(|e| match e {
            Io::Read(_) if out.exists() => fs::remove_file(out)
                .map_err(Io::Write)
                .and_then(|()| once()),
            e => Err(e),
        });
        match got {
            Ok(()) => return Ok(u.clone()),
            Err(Io::Write(e)) => return Err(Lost::Disk(e)),
            Err(Io::Read(e)) => {
                let line = format!("{u}: {e}");
                _ = OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(log)
                    .and_then(|mut f| writeln!(f, "{line}"));
                note(&format!("fetch failed from {u} (trying next mirror)"));
                tried.push(line);
            }
        }
    }
    Err(Lost::Net(tried.join("; ")))
}
