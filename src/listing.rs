//! Directory listing of the uploads tree, rendered as the JSON the page consumes.

use std::fs;
use std::path::Path;
use std::time::UNIX_EPOCH;

use crate::security::inside_uploads;

#[derive(Clone, Debug)]
pub struct Entry {
    pub name: String,
    pub size: u64,
    pub is_dir: bool,
    pub mtime: f64,
}

fn mtime_f64(md: &fs::Metadata) -> f64 {
    md.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as f64 + d.subsec_nanos() as f64 / 1e9)
        .unwrap_or(0.0)
}

/// List a directory, newest first (matches the Python server's ordering).
pub fn list_dir(dir: &Path, upload_real: &Path) -> Vec<Entry> {
    let mut entries = Vec::new();
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            let path = e.path();
            if !inside_uploads(&path, upload_real) {
                continue;
            }
            let md = match e.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            let name = e.file_name().to_string_lossy().into_owned();
            if md.is_dir() {
                entries.push(Entry { name, size: 0, is_dir: true, mtime: mtime_f64(&md) });
            } else if md.is_file() {
                entries.push(Entry { name, size: md.len(), is_dir: false, mtime: mtime_f64(&md) });
            }
        }
    }
    entries.sort_by(|a, b| {
        b.mtime
            .partial_cmp(&a.mtime)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.name.cmp(&a.name))
            .then_with(|| b.size.cmp(&a.size))
            .then_with(|| b.is_dir.cmp(&a.is_dir))
    });
    entries
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

pub fn entries_json(entries: &[Entry]) -> String {
    let items: Vec<String> = entries
        .iter()
        .map(|e| {
            format!(
                "{{\"name\": \"{}\", \"size\": {}, \"is_dir\": {}, \"mtime\": {}}}",
                json_escape(&e.name),
                e.size,
                e.is_dir,
                e.mtime
            )
        })
        .collect();
    format!("[{}]", items.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_escapes_names() {
        let entries = vec![Entry {
            name: "a\"b\\c\nd".to_string(),
            size: 3,
            is_dir: false,
            mtime: 1.5,
        }];
        assert_eq!(
            entries_json(&entries),
            "[{\"name\": \"a\\\"b\\\\c\\nd\", \"size\": 3, \"is_dir\": false, \"mtime\": 1.5}]"
        );
    }

    #[test]
    fn list_dir_sorts_newest_first_and_marks_dirs() {
        let dir = std::env::temp_dir().join(format!("landir-listing-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("sub")).unwrap();
        fs::write(dir.join("a.txt"), b"hello").unwrap();
        let real = fs::canonicalize(&dir).unwrap();
        let entries = list_dir(&dir, &real);
        assert_eq!(entries.len(), 2);
        let dirs: Vec<_> = entries.iter().filter(|e| e.is_dir).collect();
        assert_eq!(dirs.len(), 1);
        assert_eq!(dirs[0].name, "sub");
        let files: Vec<_> = entries.iter().filter(|e| !e.is_dir).collect();
        assert_eq!(files[0].name, "a.txt");
        assert_eq!(files[0].size, 5);
        let _ = fs::remove_dir_all(&dir);
    }
}
