#!/usr/bin/env python3
"""Export golden test vectors from landir.py (the reference implementation).

Generates JSON fixtures in app/test/fixtures/ that the Dart core tests
consume. Regenerate when the adversarial corpus changes:

    python3 scripts/export_golden.py
"""

import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# landir.py parses CLI args at import time; give it a temp upload dir.
TMP = tempfile.mkdtemp(prefix="landir_golden_")
sys.argv = ["landir.py", "--dir", TMP, "--insecure"]

import landir  # noqa: E402

FIXTURES = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "app", "test", "fixtures")
os.makedirs(FIXTURES, exist_ok=True)

# ---------------------------------------------------------------- safe_name
SAFE_NAME_CORPUS = [
    "../../etc/passwd",
    "..\\..\\windows\\system32\\evil.dll",
    "/etc/passwd",
    "....//....//etc/passwd",
    ".bashrc",
    "..",
    ".",
    "...",
    "....",
    "normal.txt",
    "with space.txt",
    "with[bracket].txt",
    "with(paren).txt",
    "dash-file.txt",
    "under_score.txt",
    "UPPER.TXT",
    "unicode_é_ñ_日本語.txt",
    "semi;colon.txt",
    'quote"file.txt',
    "new\nline.txt",
    "null\x00byte.txt",
    "tab\there.txt",
    "%2e%2e%2f%2e%2e%2fetc%2fpasswd",
    "%2Fetc%2Fpasswd",
    "%2e%2e%5c%2e%2e%5cwindows",
    "con",
    "a" * 300,
    "file.with.many.dots.txt",
    "trailing.dot.",
    " leading space.txt",
    "trailing space .txt",
    "emoji_\U0001f600.txt",
    "back\\slash.txt",
    "slash/inside.txt",
    "double//slash.txt",
    "",
    "   ",
    "\x00",
    "café.txt",
    "file.tar.gz",
    "no_extension",
    ".hidden",
    "..hidden",
    # M4 hardening additions: CRLF injection, more traversal, edge cases
    "crlf\r\ninjection.txt",
    "header: injection.txt",
    'quote"injection.txt',
    "..%2F..%2F..%2Froot%2Fpasswd",
    "%252e%252e%252f double-encoded",
    "....//....//....//etc/passwd",
    "..;/..;/etc/passwd",
    "con.txt",
    "aux",
    "a" * 255,
    "file\x7f.txt",
    "semi;colon;pipe|.txt",
    "<script>alert(1)</script>.txt",
    "{{template}}.txt",
    "<%=code%>.txt",
    "%00null.txt",
    "trailing\\",
    "/",
    "//",
    "\\",
    "....",
]


def export_safe_name():
    """Run safe_name over the corpus in a clean dir (no collisions).
    Outputs with timestamps are marked as patterns."""
    vectors = []
    for raw in SAFE_NAME_CORPUS:
        try:
            result = landir.safe_name(raw)
            # Timestamp fallback / collision produces non-deterministic output
            if re.match(r"^file_\d{8}_\d{6}_\d{6}$", result):
                vectors.append({"input": raw, "kind": "pattern",
                                "pattern": r"^file_\d{8}_\d{6}_\d{6}$"})
            else:
                vectors.append({"input": raw, "kind": "exact", "output": result})
        except ValueError as e:
            vectors.append({"input": raw, "kind": "error", "error": str(e)})
    path = os.path.join(FIXTURES, "safe_name.json")
    with open(path, "w") as f:
        json.dump(vectors, f, indent=2, ensure_ascii=False)
    print(f"  safe_name.json: {len(vectors)} vectors")


def export_safe_name_collision():
    """Pre-create a file, then safe_name the same name: expect timestamp suffix."""
    name = "collision.txt"
    with open(os.path.join(TMP, name), "w") as f:
        f.write("existing")
    result = landir.safe_name(name)
    pattern = r"^collision_\d{8}_\d{6}\.txt$"
    assert re.match(pattern, result), f"unexpected collision result: {result}"
    path = os.path.join(FIXTURES, "safe_name_collision.json")
    with open(path, "w") as f:
        json.dump({"input": name, "pattern": pattern, "output": result}, f, indent=2)
    print(f"  safe_name_collision.json: 1 vector (pattern match)")


# ----------------------------------------------------------- download_lookup
DOWNLOAD_CORPUS = [
    "normal.txt",
    "../etc/passwd",
    "..\\..\\windows",
    "%2e%2e%2f%2e%2e%2fetc%2fpasswd",
    "folder/file.txt",
    "folder/sub/file.txt",
    "%2Fetc%2Fpasswd",
    ".hidden",
    "..",
    ".",
    "nonexistent.txt",
    "folder",
    "",
    "normal.txt/extra",
    "semi;colon.txt",
    "with space.txt",
    "unicode_é.txt",
    "..%2F..%2Fescape",
    "folder/../normal.txt",
    # M4 hardening additions
    "folder/../../etc/passwd",
    "%2e%2e%2f%2e%2e%2f%2e%2e%2fetc%2fpasswd",
    "....//....//etc/passwd",
    "folder//file.txt",
    "folder/%2e%2e/file.txt",
    "semi%3Bcolon.txt",
    "with%20space.txt",
    "unicode_%C3%A9.txt",
    "normal.txt%00.pdf",
    ".%2e/normal.txt",
]


def export_download_lookup():
    # Set up the upload dir with known content
    os.makedirs(os.path.join(TMP, "folder", "sub"), exist_ok=True)
    for rel in ["normal.txt", "folder/file.txt", "folder/sub/file.txt",
                "with space.txt", "semi;colon.txt", "unicode_é.txt"]:
        p = os.path.join(TMP, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write("content of " + rel)
    with open(os.path.join(TMP, ".hidden"), "w") as f:
        f.write("secret")

    vectors = []
    for raw in DOWNLOAD_CORPUS:
        result = landir.download_lookup(raw)
        if result is None:
            vectors.append({"input": raw, "found": False})
        else:
            # Record relative path inside TMP for portability
            rel = os.path.relpath(result, TMP)
            vectors.append({"input": raw, "found": True, "rel": rel})
    path = os.path.join(FIXTURES, "download_lookup.json")
    with open(path, "w") as f:
        json.dump(vectors, f, indent=2, ensure_ascii=False)
    print(f"  download_lookup.json: {len(vectors)} vectors")


# ---------------------------------------------------------------- multipart
MULTIPART_BODIES = [
    # Simple single file
    ("simple", "BOUNDARY", (
        b"--BOUNDARY\r\n"
        b'Content-Disposition: form-data; name="file"; filename="hello.txt"\r\n'
        b"Content-Type: text/plain\r\n"
        b"\r\n"
        b"Hello, World!\r\n"
        b"--BOUNDARY--\r\n"
    )),
    # Binary content with CRLF inside
    ("binary_with_crlf", "BND", (
        b"--BND\r\n"
        b'Content-Disposition: form-data; name="file"; filename="bin.dat"\r\n'
        b"\r\n"
        b"line1\r\nline2\r\n\r\nline3\r\n"
        b"--BND--\r\n"
    )),
    # Multiple files in one body
    ("multi", "XYZ", (
        b"--XYZ\r\n"
        b'Content-Disposition: form-data; name="file"; filename="a.txt"\r\n'
        b"\r\n"
        b"AAA\r\n"
        b"--XYZ\r\n"
        b'Content-Disposition: form-data; name="file"; filename="b.txt"\r\n'
        b"\r\n"
        b"BBB\r\n"
        b"--XYZ--\r\n"
    )),
    # Filename with traversal attempt
    ("traversal_filename", "T", (
        b"--T\r\n"
        b'Content-Disposition: form-data; name="file"; filename="../../evil.txt"\r\n'
        b"\r\n"
        b"evil content\r\n"
        b"--T--\r\n"
    )),
    # Quoted boundary in content-type is handled by caller; unquoted here.
    # Empty file
    ("empty_file", "E", (
        b"--E\r\n"
        b'Content-Disposition: form-data; name="file"; filename="empty.txt"\r\n'
        b"\r\n"
        b"\r\n"
        b"--E--\r\n"
    )),
    # No filename field (should be skipped)
    ("no_filename", "N", (
        b"--N\r\n"
        b'Content-Disposition: form-data; name="field"\r\n'
        b"\r\n"
        b"value\r\n"
        b"--N--\r\n"
    )),
    # UTF-8 filename
    ("utf8_filename", "U", (
        b"--U\r\n"
        b'Content-Disposition: form-data; name="file"; filename="caf\xc3\xa9.txt"\r\n'
        b"\r\n"
        b"coffee\r\n"
        b"--U--\r\n"
    )),
]


def export_multipart():
    vectors = []
    for name, boundary, body in MULTIPART_BODIES:
        parts = body.split(b"--" + boundary.encode())
        files = []
        for part in parts:
            if b"filename=" not in part:
                continue
            try:
                header_blob, _, filedata = part.partition(b"\r\n\r\n")
                filedata = filedata.rsplit(b"\r\n", 1)[0]
                nm = re.search(rb'filename="([^"]*)"', header_blob).group(1)
                files.append({
                    "filename": nm.decode("utf-8", "replace"),
                    "data_hex": filedata.hex(),
                })
            except Exception:
                continue
        vectors.append({
            "name": name,
            "boundary": boundary,
            "body_hex": body.hex(),
            "expected": files,
        })
    path = os.path.join(FIXTURES, "multipart.json")
    with open(path, "w") as f:
        json.dump(vectors, f, indent=2)
    print(f"  multipart.json: {len(vectors)} vectors")


def main():
    print("Exporting golden vectors from landir.py ...")
    export_safe_name()
    export_safe_name_collision()
    export_download_lookup()
    export_multipart()
    print("Done. Fixtures written to app/test/fixtures/")


if __name__ == "__main__":
    main()
