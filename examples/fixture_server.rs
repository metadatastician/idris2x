// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// fixture_server — static file server for the chaos drills (std only, no crates).
// Honours `Range: bytes=a-b` with 206 so the resume drill takes the same path GitHub
// Releases and R2 take. One line per request on stdout: "<status> <path>".
// Usage: cargo run --quiet --example fixture_server -- <root-dir> <port>
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Component, Path, PathBuf};
use std::{env, thread};

fn resolve(root: &Path, url: &str) -> Option<PathBuf> {
    let path = url.split('?').next()?.trim_start_matches('/');
    let rel = Path::new(path);
    if rel.components().any(|c| !matches!(c, Component::Normal(_))) {
        return None; // no '..', no absolute paths
    }
    Some(root.join(rel))
}

fn parse_range(h: &str, size: u64) -> Option<(u64, u64)> {
    let spec = h.trim().strip_prefix("bytes=")?;
    let (a, b) = spec.split_once('-')?;
    match (a.is_empty(), b.is_empty()) {
        (false, true) => Some((a.parse().ok()?, size.checked_sub(1)?)),
        (false, false) => Some((
            a.parse().ok()?,
            b.parse::<u64>().ok()?.min(size.checked_sub(1)?),
        )),
        (true, false) => {
            let n: u64 = b.parse().ok()?;
            Some((size.saturating_sub(n), size.checked_sub(1)?))
        }
        (true, true) => None,
    }
}

fn serve(mut s: TcpStream, root: PathBuf) -> std::io::Result<()> {
    let mut rd = BufReader::new(s.try_clone()?);
    let mut line = String::new();
    rd.read_line(&mut line)?;
    let mut parts = line.split_whitespace();
    let (method, url) = (
        parts.next().unwrap_or(""),
        parts.next().unwrap_or("/").to_string(),
    );
    let mut range = None;
    loop {
        let mut h = String::new();
        if rd.read_line(&mut h)? == 0 || h == "\r\n" || h == "\n" {
            break;
        }
        if let Some((k, v)) = h.split_once(':') {
            if k.eq_ignore_ascii_case("range") {
                range = Some(v.trim().to_string());
            }
        }
    }
    let reply = |s: &mut TcpStream, code: &str| -> std::io::Result<()> {
        println!("{} {}", &code[..3], url);
        write!(
            s,
            "HTTP/1.1 {code}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
    };
    let Some(path) = resolve(&root, &url) else {
        return reply(&mut s, "403 Forbidden");
    };
    let Ok(mut f) = File::open(&path) else {
        return reply(&mut s, "404 Not Found");
    };
    let size = f.metadata()?.len();
    if !f.metadata()?.is_file() {
        return reply(&mut s, "404 Not Found");
    }
    let (status, start, end) = match range.as_deref().map(|r| parse_range(r, size)) {
        Some(Some((a, b))) if a <= b && a < size => ("206 Partial Content", a, b),
        Some(_) if size > 0 => {
            println!("416 {url}");
            return write!(s, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{size}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        }
        _ => ("200 OK", 0, size.saturating_sub(1)),
    };
    let len = if size == 0 { 0 } else { end - start + 1 };
    println!("{} {}", &status[..3], url);
    write!(s, "HTTP/1.1 {status}\r\nContent-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\nContent-Length: {len}\r\n")?;
    if status.starts_with("206") {
        write!(s, "Content-Range: bytes {start}-{end}/{size}\r\n")?;
    }
    write!(s, "Connection: close\r\n\r\n")?;
    if method != "HEAD" {
        f.seek(SeekFrom::Start(start))?;
        std::io::copy(&mut f.take(len), &mut s)?;
    }
    s.flush()
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let root = PathBuf::from(args.get(1).map(String::as_str).unwrap_or("."));
    let port = args.get(2).map(String::as_str).unwrap_or("8099");
    let l = TcpListener::bind(format!("127.0.0.1:{port}")).expect("bind");
    println!("listening 127.0.0.1 {port}");
    for s in l.incoming().flatten() {
        let r = root.clone();
        thread::spawn(move || {
            let _ = serve(s, r);
        });
    }
}
