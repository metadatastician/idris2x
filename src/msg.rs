// SPDX-License-Identifier: MPL-2.0 AND CC-BY-SA-4.0
// This file is MPL-2.0 code. It holds no wording: the words are CC-BY-SA-4.0, in src/errors/errors.toml.
//! Messages. Every word comes from `src/errors/errors.toml`, through the table that
//! `scripts/gen-errors-rs.sh` generates. The renderer reproduces `scripts/proto/render.jq`
//! byte for byte; `docs/dx/ERROR-CATALOGUE-RENDERED.adoc` is the contract.
//!
//! Context text is typed by provenance (ADR 0012). A value reaches a slot only through a
//! `From` impl that the policy table below allows, and rendered output can only be printed.
//!
//! Raw lock text cannot fill a fix slot, and neither lock nor checked text can fill prose:
//! ```compile_fail,E0277
//! let _: idris2x::msg::Fix = idris2x::msg::lock("0.8.0").into();
//! ```
//! ```compile_fail,E0277
//! let _: idris2x::msg::Prose = idris2x::msg::lock("0.8.0").into();
//! ```
//! ```compile_fail,E0277
//! use idris2x::msg::{check_version, lock, Prose};
//! let _: Prose = check_version(&lock("0.8.0")).unwrap().into();
//! ```
//! A label cannot be forged, rendered output cannot be read back, and embedded text is `'static`:
//! ```compile_fail,E0603
//! let _ = idris2x::msg::Txt::<idris2x::msg::Checked>(String::new(), std::marker::PhantomData);
//! ```
//! ```compile_fail,E0616
//! fn relabel(r: idris2x::msg::Rendered) -> idris2x::msg::Txt<idris2x::msg::Host> { idris2x::msg::host(r.0) }
//! ```
//! ```compile_fail,E0597
//! let s = String::from("rm -rf /");
//! let _ = idris2x::msg::embedded(&s);
//! ```
//! A checked lock value may fill a fix slot, and host text may fill any slot:
//! ```
//! use idris2x::msg::{check_digest, check_version, host, lock, Fact, Fix, Prose};
//! let _: Fix = check_version(&lock("0.8.0")).unwrap().into();
//! let _: Fact = check_digest(&lock("0d7a4c1e9b52f6a83c07d1e45b9a2f6c8e13d7b0a5942c6f1e8d3b7a094c5e21")).unwrap().into();
//! let _: Prose = host("/home/ada/proofs").into();
//! assert!(check_version(&lock("0.8.0; curl x | sh")).is_none());
//! ```

use std::io::{IsTerminal, Write};
use std::marker::PhantomData;

pub enum Embedded {}
pub enum Host {}
pub enum Lock {}
pub enum Checked {}

/// Text that remembers where it came from. The fields are private, so outside this module a
/// `Txt` comes only from the entry points below.
pub struct Txt<P>(String, PhantomData<P>);
fn txt<P>(s: impl Into<String>) -> Txt<P> {
    Txt(s.into(), PhantomData)
}
/// Launcher constants. Only text compiled into the binary is `'static`.
pub fn embedded(s: &'static str) -> Txt<Embedded> {
    txt(s)
}
/// This machine: argv, paths, the environment, the clock.
pub fn host(s: impl Into<String>) -> Txt<Host> {
    txt(s)
}
/// idris2x.lock, a local file that an attacker may have written.
pub fn lock(s: impl Into<String>) -> Txt<Lock> {
    txt(s)
}
/// A digest of 64 characters from 0-9a-f. Trusted by inspection to admit no shell syntax.
pub fn check_digest(t: &Txt<Lock>) -> Option<Txt<Checked>> {
    let hex = |b: u8| matches!(b, b'0'..=b'9' | b'a'..=b'f');
    (t.0.len() == 64 && t.0.bytes().all(hex)).then(|| txt(&*t.0))
}
/// A version of two to four runs of decimal digits separated by dots. Trusted by inspection.
pub fn check_version(t: &Txt<Lock>) -> Option<Txt<Checked>> {
    let runs: Vec<&str> = t.0.split('.').collect();
    let digits = |r: &&str| !r.is_empty() && r.bytes().all(|b| b.is_ascii_digit());
    ((2..=4).contains(&runs.len()) && runs.iter().all(digits)).then(|| txt(&*t.0))
}

/// The policy table of ADR 0012: which provenance may fill which slot. The module is private,
/// so no other part of the launcher can add a row.
mod policy {
    use super::{Checked, Embedded, Host, Lock};
    pub trait InProse {}
    pub trait InFix {}
    pub trait InFact {}
    impl InProse for Embedded {}
    impl InProse for Host {}
    impl InFix for Embedded {}
    impl InFix for Host {}
    impl InFix for Checked {}
    impl InFact for Embedded {}
    impl InFact for Host {}
    impl InFact for Lock {}
    impl InFact for Checked {}
}
macro_rules! slot {
    ($(#[$d:meta])* $name:ident: $rule:ident) => {
        $(#[$d])*
        pub struct $name(Box<str>);
        impl<P: policy::$rule> From<Txt<P>> for $name {
            fn from(t: Txt<P>) -> Self {
                $name(t.0.into())
            }
        }
    };
}
slot!(/// A value for prose: summary, story, state, why, fix lead, note.
    Prose: InProse);
slot!(/// A value for the fix command.
    Fix: InFix);
slot!(/// A value shown only as a labelled fact.
    Fact: InFact);
include!("errors_gen.rs");

pub type R<T> = Result<T, Fail>;
#[derive(Clone, Copy, PartialEq)]
pub enum Form {
    Tty,
    Plain,
    Json,
}
/// A rendered message. It can be printed, and nothing else: it never becomes text again.
pub struct Rendered(String);
impl Rendered {
    pub fn print(&self, w: &mut dyn Write) -> std::io::Result<()> {
        writeln!(w, "{}", self.0)
    }
}

fn var(k: &str) -> String {
    std::env::var(k).unwrap_or_default()
}
/// `IDRIS2X_JSON=1` wins; colour needs a terminal on stderr, and is off for NO_COLOR or TERM=dumb.
pub fn form() -> Form {
    let (color, json) = (var("IDRIS2X_COLOR"), var("IDRIS2X_JSON") == "1");
    let off = color == "never" || !var("NO_COLOR").is_empty() || var("TERM") == "dumb";
    match () {
        _ if json => Form::Json,
        _ if color == "always" || !off && std::io::stderr().is_terminal() => Form::Tty,
        _ => Form::Plain,
    }
}
fn runbook() -> String {
    Some(var("IDRIS2X_RUNBOOK"))
        .filter(|r| !r.is_empty())
        .unwrap_or_else(|| {
            "https://github.com/metadatastician/idris2x/blob/main/docs/runbooks".into()
        })
}
fn width() -> usize {
    let c = std::env::var("COLUMNS")
        .ok()
        .and_then(|c| c.parse::<i64>().ok());
    c.unwrap_or(80).clamp(40, 80) as usize
}

/// The shell quoting of render.jq: safe words stay bare, anything else is single-quoted.
fn shq(s: &str) -> String {
    let safe = |c: char| c.is_ascii_alphanumeric() || "_./:@%+=,-".contains(c);
    match !s.is_empty() && s.chars().all(safe) {
        true => s.into(),
        false => format!("'{}'", s.replace('\'', "'\\''")),
    }
}
fn is_key(k: &&str) -> bool {
    !k.is_empty() && k.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
}
/// The `{placeholder}` names in a template.
fn keys_in(s: &str) -> impl Iterator<Item = &str> {
    s.split('{')
        .skip(1)
        .filter_map(|p| Some(p.split_once('}')?.0).filter(is_key))
}
/// One pass over the template: an inserted value is never scanned again, so it cannot pull in
/// another key's value (which could carry lock text into prose).
fn fill(s: &str, ctx: &[(&str, &str)], quote: bool) -> String {
    let (mut o, mut rest) = (String::new(), s);
    while let Some(i) = rest.find('{') {
        o.push_str(&rest[..i]);
        rest = &rest[i..];
        let key = rest[1..].split_once('}').map(|p| p.0).filter(is_key);
        let Some((k, v)) = key.and_then(|k| ctx.iter().find(|p| p.0 == k)) else {
            o.push('{');
            rest = &rest[1..];
            continue;
        };
        o.push_str(&if quote { shq(v) } else { (*v).into() });
        rest = &rest[k.len() + 2..];
    }
    o + rest
}
/// Greedy word wrap at `w` characters, splitting on spaces only.
fn wrap(s: &str, w: usize) -> String {
    let (mut o, mut n) = (String::new(), 0);
    for word in s.split(' ').filter(|x| !x.is_empty()) {
        let l = word.chars().count();
        if n > 0 && n + 1 + l <= w {
            o.push(' ');
            n += 1;
        } else if n > 0 {
            o.push('\n');
            n = 0;
        }
        o.push_str(word);
        n += l;
    }
    o
}
fn paint(on: bool, code: &str, s: &str) -> String {
    if on {
        format!("\x1b[{code}m{s}\x1b[0m")
    } else {
        s.into()
    }
}
/// A JSON string as jq 1.7 writes it.
fn js(s: &str) -> String {
    let esc = |c: char| match c {
        '"' | '\\' => format!("\\{c}"),
        '\n' => "\\n".into(),
        '\t' => "\\t".into(),
        '\r' => "\\r".into(),
        '\u{8}' => "\\b".into(),
        '\u{c}' => "\\f".into(),
        c if (c as u32) < 0x20 || c == '\u{7f}' => format!("\\u{:04x}", c as u32),
        c => c.into(),
    };
    format!("\"{}\"", s.chars().map(esc).collect::<String>())
}

/// The first value case `k` uses that `ctx` lacks. A `Fail` never lacks one: the generator gives each
/// variant every key its case uses. Only the `__render` hook, fed from the command line, can.
fn missing(k: usize, ctx: &[(&str, &str)]) -> Option<&'static str> {
    let c = &CASES[k];
    let all = [
        c.summary, c.story, c.state, c.why, c.fix_lead, c.fix_cmd, c.fix_note,
    ];
    let mut keys = all
        .into_iter()
        .flat_map(keys_in)
        .chain(c.facts.iter().map(|f| f.1));
    keys.find(|key| !ctx.iter().any(|p| p.0 == *key))
}
/// Render case `k` with its context values. A value it lacks stays as its placeholder in text and is empty on a
/// fact line: see `missing`.
fn render(k: usize, ctx: &[(&str, &str)], form: Form, a: bool, w: usize) -> Rendered {
    let (c, tty) = (&CASES[k], form == Form::Tty);
    let e = &ERRORS[c.error];
    let get = |key: &str| ctx.iter().find(|p| p.0 == key).map_or("", |p| p.1);
    let [summary, story, state, why, lead, note, auto] = [
        c.summary, c.story, c.state, c.why, c.fix_lead, c.fix_note, c.auto,
    ]
    .map(|t| fill(t, ctx, false));
    let (cmd, docs) = (
        fill(c.fix_cmd, ctx, true),
        format!("{}/{}.adoc", runbook(), e.id),
    );
    let explain = format!("idris2x explain {}", e.id);
    let out = if form == Form::Json {
        fn kv(pairs: &[(&str, &str)]) -> String {
            let p: Vec<_> = pairs
                .iter()
                .map(|(k, v)| format!("{}:{}", js(k), js(v)))
                .collect();
            p.join(",")
        }
        let (head, mid) = (
            kv(&[("id", e.id), ("case", c.case)]),
            kv(&[("title", e.title), ("summary", &summary)]),
        );
        let obj = |pairs: &[(&str, &str)]| format!("{{{}}}", kv(pairs));
        let (cx, tail) = (obj(ctx), kv(&[("state", &state), ("why", &why)]));
        let fix = obj(&[("command", &cmd), ("note", &note), ("auto", &auto)]);
        let end = kv(&[("explain", &explain), ("docs", &docs)]);
        let x = e.exit;
        format!("{{\"schema\":1,\"tool\":\"idris2x\",\"level\":\"error\",{head},\"exit\":{x},{mid},\"context\":{cx},{tail},\"fix\":{fix},{end}}}")
    } else if a {
        let h = format!("-- {} (exit {}) ", e.id, e.exit);
        let rule = "-".repeat((w as isize - h.chars().count() as isize - 8).max(2) as usize);
        let head = match tty {
            true => paint(true, "36", &format!("{h}{rule} idris2x")),
            false => format!("idris2x: {} (exit {})", e.id, e.exit),
        };
        let m = c
            .facts
            .iter()
            .map(|f| f.0.chars().count())
            .max()
            .unwrap_or(0);
        let pad = |l: &str| " ".repeat(m - l.chars().count() + 2);
        let facts: Vec<String> = c
            .facts
            .iter()
            .map(|(l, k)| format!("    {l}{}{}", pad(l), get(k)))
            .collect();
        let para = |s: &str| (!s.is_empty()).then(|| wrap(s, w));
        let fix = (!cmd.is_empty())
            .then(|| [para(&lead), Some(format!("    {}", paint(tty, "1", &cmd)))]);
        let mut p = vec![
            Some(head),
            Some(wrap(&story, w)),
            (!facts.is_empty()).then(|| facts.join("\n")),
        ];
        p.extend(
            [para(&state), para(&why)]
                .into_iter()
                .chain(fix.into_iter().flatten()),
        );
        p.extend([para(&note), Some(format!("More: {explain}\n{docs}"))]);
        p.into_iter().flatten().collect::<Vec<_>>().join("\n\n")
    } else {
        let b = |s: &str| paint(tty, "1", s);
        let mut l = vec![format!(
            "idris2x: {}: {summary}",
            paint(tty, "1;31", &format!("error[{}]", e.id))
        )];
        l.extend(
            c.facts
                .iter()
                .map(|(lab, k)| format!("    {lab}: {}", get(k))),
        );
        l.extend([
            format!("  {}: {state}", b("state")),
            format!("  {}: {why}", b("why")),
        ]);
        l.extend((!cmd.is_empty()).then(|| format!("  {}: {}", b("fix"), b(&cmd))));
        let nl = if cmd.is_empty() { "fix" } else { "note" };
        l.extend((!note.is_empty()).then(|| format!("  {}: {note}", b(nl))));
        l.extend([
            format!("  {}: {explain}", b("see")),
            format!("  {}: {docs}", b("see")),
        ]);
        l.join("\n")
    };
    Rendered(out)
}
fn render_env(k: usize, ctx: &[(&str, &str)], form: Form) -> Rendered {
    render(k, ctx, form, var("IDRIS2X_STYLE") == "a", width())
}

/// Print `f` on stderr, leave its JSON in IDRIS2X_ERROR_FILE, and exit with its code.
pub fn fail(f: Fail) -> ! {
    let (k, ctx) = f.parts();
    let r = |form| render_env(k, &ctx, form);
    _ = r(form()).print(&mut std::io::stderr());
    if let Some(p) = std::env::var_os("IDRIS2X_ERROR_FILE").filter(|p| !p.is_empty()) {
        if let Err(e) = std::fs::File::create(&p).and_then(|mut f| r(Form::Json).print(&mut f)) {
            note(&format!(
                "could not write IDRIS2X_ERROR_FILE {}: {e}",
                p.to_string_lossy()
            ));
        }
    }
    std::process::exit(ERRORS[CASES[k].error].exit.into())
}
pub fn note(s: &str) {
    if var("IDRIS2X_QUIET") != "1" {
        eprintln!("idris2x: {s}");
    }
}
/// Write `s` to stdout. A failed write is E-OUTPUT: never a panic, and never silence.
pub fn out(s: &str) -> R<()> {
    let mut o = std::io::stdout().lock();
    let r = o.write_all(s.as_bytes()).and_then(|()| o.flush());
    r.map_err(|e| Fail::OutputWriteFailed {
        detail: host(e.to_string()).into(),
    })
}
/// A note that is not an error, unless IDRIS2X_ADVICE=0 or its own variable is 0.
pub fn advise(a: Advice) -> R<()> {
    let (k, ctx) = a.parts();
    let d = &ADVICE[k];
    if var("IDRIS2X_ADVICE") == "0" || var(d.silence) == "0" {
        return Ok(());
    }
    let text = fill(d.text, &ctx, false);
    out(&format!(
        "note: {text}\nnote: silence this note with {}=0\n",
        d.silence
    ))
}
fn bug(detail: String) -> Fail {
    let version = embedded(env!("CARGO_PKG_VERSION")).into();
    Fail::InternalBug {
        detail: host(detail).into(),
        version,
    }
}
/// The hidden test hook `__render FORM ID CASE key=value...` that dx-golden.sh drives.
pub fn render_hook(args: &[String]) -> R<()> {
    let [form, id, case, kv @ ..] = args else {
        return Err(bug("__render needs FORM ID CASE".into()));
    };
    let mut ctx: Vec<(&str, &str)> = vec![];
    for (k, v) in kv
        .iter()
        .map(|a| a.split_once('=').filter(|p| !p.0.is_empty()).ok_or(a))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|a| bug(format!("__render: not key=value: {a}")))?
    {
        match ctx.iter_mut().find(|p| p.0 == k) {
            Some(p) => p.1 = v,
            None => ctx.push((k, v)),
        }
    }
    let form = match form.as_str() {
        "json" => Form::Json,
        "tty" => Form::Tty,
        _ => Form::Plain,
    };
    let found = CASES
        .iter()
        .position(|c| ERRORS[c.error].id == id && c.case == case);
    let k = found.ok_or_else(|| bug(format!("no message data for {id}/{case}")))?;
    if let Some(key) = missing(k, &ctx) {
        return Err(bug(format!("missing context value: {key}")));
    }
    let r = render_env(k, &ctx, form);
    out(&format!("{}\n", r.0))
}
/// `explain` lists every error; `explain ID` gives its long form, offline, from the same table.
pub fn explain(id: Option<&str>) -> R<()> {
    let Some(id) = id else {
        return out(EXPLAIN_ALL);
    };
    let e = ERRORS
        .iter()
        .find(|e| e.id == id)
        .ok_or_else(|| Fail::UsageNoSuchId {
            word: host(id).into(),
        })?;
    out(&format!("{}Runbook: {}/{id}.adoc\n", e.explain, runbook()))
}
