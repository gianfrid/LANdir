//! Name sanitizing and path containment — the security core of the server.
//!
//! Rules (mirror landir.py, do not regress — see SPEC.md):
//! - every uploaded filename goes through `safe_name`: URL-decode, backslash
//!   normalization, basename, control-char strip, leading-dot strip, character
//!   whitelist, then a canonicalized containment check against the uploads dir
//! - every client-requested download name goes through `download_lookup` with
//!   the same whitelist and containment, resolving only regular files inside
//!   the uploads dir
//! - names that resolve to an existing file get a timestamp suffix

use std::fs;
use std::path::{Path, PathBuf};

fn is_ctrl(c: char) -> bool {
    ('\u{0}'..='\u{1f}').contains(&c) || c == '\u{7f}'
}

fn is_whitelisted(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ' ' | '(' | ')' | '[' | ']' | '-')
}

fn basename(s: &str) -> &str {
    s.rsplit('/').next().unwrap_or("")
}

fn decode(s: &str) -> String {
    percent_encoding::percent_decode_str(s)
        .decode_utf8_lossy()
        .into_owned()
}

/// "YYYYMMDD_HHMMSS" local time, for collision suffixes.
fn timestamp_now() -> String {
    chrono::Local::now().format("%Y%m%d_%H%M%S").to_string()
}

/// "YYYYMMDD_HHMMSS_ffffff" (microseconds) local time, for generated names.
fn timestamp_now_micros() -> String {
    let now = chrono::Local::now();
    format!("{}_{:06}", now.format("%Y%m%d_%H%M%S"), now.timestamp_subsec_micros())
}

/// Reduce a client-supplied filename to a safe bare name inside the uploads
/// dir. Returns None if the resolved path would escape the uploads dir.
/// Existing names get a timestamp suffix instead of being overwritten.
pub fn safe_name(raw: &str, upload_real: &Path) -> Option<String> {
    let name = decode(raw).replace('\\', "/");
    let name = basename(&name);
    let name: String = name.chars().filter(|c| !is_ctrl(*c)).collect();
    let name = name.trim();
    let name = name.trim_start_matches('.');
    let name: String = name
        .chars()
        .map(|c| if is_whitelisted(c) { c } else { '_' })
        .collect();
    let name = if name.is_empty() || name.trim_matches('.').is_empty() {
        format!("file_{}", timestamp_now_micros())
    } else {
        name
    };
    // Defense in depth: resolved path MUST stay inside the uploads dir
    let candidate = upload_real.join(&name);
    let resolved = if candidate.exists() {
        fs::canonicalize(&candidate).unwrap_or_else(|_| candidate.clone())
    } else {
        // broken symlink or dangling name: reject anything that is a symlink
        if fs::symlink_metadata(&candidate)
            .map(|m| m.file_type().is_symlink())
            .unwrap_or(false)
        {
            return None;
        }
        candidate.clone()
    };
    if !resolved.starts_with(upload_real) {
        return None;
    }
    // Avoid overwriting: if the name exists, add a timestamp suffix and keep
    // bumping a counter until the candidate does not exist yet (the timestamp
    // alone has 1-second resolution, so it can collide on rapid re-uploads).
    if candidate.exists() {
        let (stem, ext) = split_ext(&name);
        let ts = timestamp_now();
        let mut suffixed = format!("{stem}_{ts}{ext}");
        let mut n = 1;
        while upload_real.join(&suffixed).exists() {
            n += 1;
            suffixed = format!("{stem}_{ts}_{n}{ext}");
        }
        return Some(suffixed);
    }
    Some(name)
}

/// Split into (stem, ext) at the last dot, unless the dot is leading.
fn split_ext(name: &str) -> (&str, &str) {
    match name.rfind('.').filter(|&i| i > 0) {
        Some(i) => (&name[..i], &name[i..]),
        None => (name, ""),
    }
}

/// Next candidate name when `name` was claimed by a concurrent upload:
/// re-suffix with a microsecond timestamp so the retry is unique.
pub fn collision_bump(name: &str) -> String {
    let (stem, ext) = split_ext(name);
    format!("{stem}_{}{ext}", timestamp_now_micros())
}

/// Write an upload body to a unique hidden staging file inside the uploads
/// dir. Staging in the same directory (same filesystem) keeps the atomic
/// publish below possible; the dot prefix keeps in-flight uploads out of
/// the listings, which filter hidden names.
fn stage_temp(upload_dir: &Path, data: &[u8]) -> std::io::Result<PathBuf> {
    loop {
        let tmp = upload_dir.join(format!(
            ".landir_tmp_{}_{}",
            timestamp_now_micros(),
            std::process::id()
        ));
        match fs::OpenOptions::new().write(true).create_new(true).open(&tmp) {
            Ok(mut f) => {
                std::io::Write::write_all(&mut f, data)?;
                return Ok(tmp);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                continue // same-microsecond collision: re-roll the name
            }
            Err(e) => return Err(e),
        }
    }
}

/// Atomically publish a staged file under its final name; false if the
/// name is already taken. `hard_link` is the atomic publication step: it
/// fails with AlreadyExists instead of overwriting (SPEC rule 4), so a
/// concurrent same-name upload can never clobber an existing file.
fn publish(tmp: &Path, target: &Path) -> bool {
    match fs::hard_link(tmp, target) {
        Ok(()) => true,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => false,
        Err(_) => {
            // Filesystem without hardlink support (e.g. vfat/exfat): fall
            // back to a checked rename. The exists() race window is
            // microscopic and the suffix re-roll in save_unique still
            // guarantees uniqueness.
            if target.exists() {
                false
            } else {
                fs::rename(tmp, target).is_ok()
            }
        }
    }
}

/// Write data to a not-yet-existing file in the uploads dir, never
/// overwriting. The body is staged in a hidden temp file and only becomes
/// visible under its final name once fully written (atomic link), so
/// concurrent listings and downloads never see a partial file. If another
/// upload claimed the name in the meantime, retries with a fresh
/// microsecond-timestamp suffix. Ok(None) means no free name could be
/// claimed; Err is a server-side IO failure (disk full, dir gone, …).
pub fn save_unique(
    name: &str,
    data: &[u8],
    upload_dir: &Path,
) -> std::io::Result<Option<String>> {
    let mut name = name.to_string();
    for _ in 0..100 {
        let tmp = stage_temp(upload_dir, data)?;
        if publish(&tmp, &upload_dir.join(&name)) {
            // drop the staging name; the data lives under the published one
            let _ = fs::remove_file(&tmp);
            return Ok(Some(name));
        }
        let _ = fs::remove_file(&tmp); // consumed by rename, or restaged
        name = collision_bump(&name);
    }
    Ok(None)
}

pub fn inside_uploads(path: &Path, upload_real: &Path) -> bool {
    match fs::canonicalize(path) {
        Ok(p) => p.starts_with(upload_real),
        Err(_) => false,
    }
}

/// Sanitize a single path component (filename or directory name).
/// Returns None if invalid.
pub fn safe_path_component(raw: &str) -> Option<String> {
    component_impl(raw, true)
}

/// Same, but the name is taken verbatim (no percent-decoding) — the sealed
/// endpoints carry the path inside the encrypted envelope, not URL-encoded
/// on the wire, so a real folder named "100%20off" must not be mangled.
pub fn safe_path_component_raw(raw: &str) -> Option<String> {
    component_impl(raw, false)
}

fn component_impl(raw: &str, decode_url: bool) -> Option<String> {
    let name = if decode_url { decode(raw) } else { raw.to_string() };
    let name = name.replace('\\', "/");
    let name = basename(&name);
    let name: String = name.chars().filter(|c| !is_ctrl(*c)).collect();
    let name = name.trim();
    if name.is_empty() || name.starts_with('.') {
        return None;
    }
    if !name.chars().all(is_whitelisted) {
        return None;
    }
    Some(name.to_string())
}

/// Resolve a client-requested file name to a path inside the uploads dir.
/// Returns None if the name is rejected. Supports subdirectory paths.
pub fn download_lookup(raw: &str, upload_dir: &Path, upload_real: &Path) -> Option<PathBuf> {
    download_lookup_impl(raw, upload_dir, upload_real, true)
}

/// Same, but the path is taken verbatim (no percent-decoding) — the sealed
/// download endpoint carries the path inside the encrypted envelope.
pub fn download_lookup_raw(raw: &str, upload_dir: &Path, upload_real: &Path) -> Option<PathBuf> {
    download_lookup_impl(raw, upload_dir, upload_real, false)
}

fn download_lookup_impl(
    raw: &str,
    upload_dir: &Path,
    upload_real: &Path,
    decode_url: bool,
) -> Option<PathBuf> {
    let raw = if decode_url { decode(raw) } else { raw.to_string() };
    let mut parts = Vec::new();
    for part in raw.split('/') {
        parts.push(component_impl(part, decode_url)?);
    }
    if parts.is_empty() {
        return None;
    }
    let mut path = upload_dir.to_path_buf();
    for p in &parts {
        path.push(p);
    }
    if !inside_uploads(&path, upload_real) {
        return None;
    }
    if !path.is_file() {
        return None;
    }
    Some(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_uploads(tag: &str) -> (PathBuf, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "landir-security-test-{}-{}-{}",
            tag,
            std::process::id(),
            timestamp_now_micros()
        ));
        fs::create_dir_all(&dir).unwrap();
        let real = fs::canonicalize(&dir).unwrap();
        (dir, real)
    }

    #[test]
    fn plain_names_kept() {
        let (_d, real) = tmp_uploads("plain");
        for raw in ["f.txt", "pwn", "photo (1).jpg", "weird [a-b].tar.gz"] {
            assert_eq!(safe_name(raw, &real).unwrap(), raw, "raw={raw}");
        }
    }

    #[test]
    fn traversal_collapsed_to_basename() {
        let (_d, real) = tmp_uploads("trav");
        for (raw, expected) in [
            ("../../pwn", "pwn"),
            ("../../../etc/pwn", "pwn"),
            ("..\\..\\pwn", "pwn"),
            ("../pwn", "pwn"),
            ("/etc/passwd", "passwd"),
            ("C:\\temp\\pwn", "pwn"),
            ("%2e%2e%2fpwn", "pwn"),
            ("%2e%2e%5cpwn", "pwn"),
        ] {
            assert_eq!(safe_name(raw, &real).unwrap(), expected, "raw={raw}");
        }
    }

    #[test]
    fn hidden_and_dot_names() {
        let (_d, real) = tmp_uploads("dots");
        assert_eq!(safe_name(".bashrc", &real).unwrap(), "bashrc");
        for raw in [".", "..", "...", ""] {
            let n = safe_name(raw, &real).unwrap();
            assert!(n.starts_with("file_"), "raw={raw:?} -> {n}");
        }
    }

    #[test]
    fn control_and_unsafe_chars() {
        let (_d, real) = tmp_uploads("chars");
        assert_eq!(safe_name("na\u{0}me\u{7}.txt", &real).unwrap(), "name.txt");
        assert_eq!(safe_name("run\r\nsh", &real).unwrap(), "runsh");
        assert_eq!(safe_name("héü&$;ls.txt", &real).unwrap(), "h_____ls.txt");
        assert_eq!(safe_name("it's;rm -rf", &real).unwrap(), "it_s_rm -rf");
    }

    #[test]
    fn existing_file_gets_timestamp_suffix() {
        let (d, real) = tmp_uploads("exists");
        fs::write(d.join("exists.txt"), b"").unwrap();
        let n = safe_name("exists.txt", &real).unwrap();
        assert!(n.starts_with("exists_") && n.ends_with(".txt"), "got {n}");
        assert_ne!(n, "exists.txt");
        assert!(d.join("exists.txt").exists());
    }

    #[test]
    fn taken_timestamp_suffix_gets_unique_name() {
        // two same-name uploads within the same second must not collide:
        // occupy both the plain name and the first timestamped candidate
        let (d, real) = tmp_uploads("exists2");
        fs::write(d.join("exists.txt"), b"").unwrap();
        let first = safe_name("exists.txt", &real).unwrap();
        fs::write(d.join(&first), b"").unwrap();
        let second = safe_name("exists.txt", &real).unwrap();
        assert_ne!(first, second);
        assert!(second.starts_with("exists_") && second.ends_with(".txt"), "got {second}");
        // the returned name must be free, and the earlier files untouched
        assert!(!d.join(&second).exists());
        assert!(d.join("exists.txt").exists());
        assert!(d.join(&first).exists());
    }

    #[cfg(unix)]
    #[test]
    fn symlink_escape_rejected() {
        // defense in depth (SPEC rule 1): a symlink planted inside the
        // uploads dir must not make safe_name/download_lookup resolve
        // outside it — this is the containment branch's whole purpose
        let (d, real) = tmp_uploads("symlink");
        std::os::unix::fs::symlink("/etc/passwd", d.join("evil")).unwrap();
        assert!(safe_name("evil", &real).is_none());
        assert!(download_lookup("evil", &d, &real).is_none());
        // a dangling symlink is rejected too (never written through)
        std::os::unix::fs::symlink("/nonexistent-target-xyz", d.join("dangling")).unwrap();
        assert!(safe_name("dangling", &real).is_none());
    }

    #[test]
    fn raw_variants_skip_percent_decoding() {
        // sealed endpoints carry the path verbatim inside the envelope:
        // "100%20off" must NOT be decoded to "100 off" (plaintext routes do)
        assert_eq!(safe_path_component("100%20off").as_deref(), Some("100 off"));
        assert!(safe_path_component_raw("100%20off").is_none()); // '%' not whitelisted
        assert_eq!(safe_path_component_raw("plain dir").as_deref(), Some("plain dir"));
        let (d, real) = tmp_uploads("raw");
        fs::write(d.join("100%20off.txt"), b"").unwrap();
        assert!(download_lookup("100%20off.txt", &d, &real).is_none()); // decodes to "100 off.txt"
        assert!(download_lookup_raw("100%20off.txt", &d, &real).is_none()); // '%' rejected verbatim
        fs::write(d.join("plain.txt"), b"").unwrap();
        assert!(download_lookup_raw("plain.txt", &d, &real).is_some());
        assert!(download_lookup_raw("../plain.txt", &d, &real).is_none());
    }

    #[test]
    fn download_lookup_cases() {
        let (d, real) = tmp_uploads("lookup");
        fs::write(d.join("good file (1) [x].txt"), b"").unwrap();
        fs::create_dir(d.join("sub")).unwrap();
        let found = download_lookup("good%20file%20(1)%20%5Bx%5D.txt", &d, &real).unwrap();
        assert_eq!(
            found.file_name().unwrap().to_string_lossy(),
            "good file (1) [x].txt"
        );
        for raw in [
            "sub",
            "sub/",
            ".bashrc",
            "..",
            "../../etc/passwd",
            "%2e%2e/etc/passwd",
            "nope.txt",
            "",
            "a/b.txt",
            "na\u{0}me.txt",
        ] {
            assert!(download_lookup(raw, &d, &real).is_none(), "raw={raw:?}");
        }
    }
}
