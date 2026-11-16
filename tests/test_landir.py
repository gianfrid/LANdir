#!/usr/bin/env python3
"""Test suite for landir.py. Stdlib unittest only, no dependencies.

Run from the repo root:
    python3 -m unittest discover -s tests -v

Covers:
- the QR encoder: a spec-based decoder reads the matrix back (format info
  BCH-checked in both copies, mask read from the matrix, Reed-Solomon
  syndromes verified with independently implemented GF(256) arithmetic,
  byte-mode round trip), plus structural and terminal-rendering checks
- safe_name: sanitizing, traversal rejection, collision handling
- the HTTP server: secret (default) and --insecure token routing, upload handling
- a startup smoke test (renders a QR for the launch URL)
"""

import http.client
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer

SERVER = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "..", "landir.py")


def load_server(argv_extra=()):
    """Load a fresh module instance (it parses sys.argv at import time)."""
    name = "fds_" + ("plain" if "--insecure" in argv_extra else "secret")
    old_argv = sys.argv
    sys.argv = ["landir.py", *argv_extra]
    try:
        spec = importlib.util.spec_from_file_location(name, SERVER)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        sys.argv = old_argv


def multipart(filename, content):
    boundary = "testboundary42"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode() + content + f"\r\n--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


# --------------------------------------------------------------------------
# Spec-based QR decoder used to verify the encoder's output (independent of
# the encoder's internals: reads the mask from the matrix, checks the format
# BCH code and the Reed-Solomon syndromes, then decodes byte mode).

QR_BLOCKS = {1: (10, [16]), 2: (16, [28]), 3: (26, [44]),
             4: (18, [32, 32]), 5: (24, [43, 43]), 6: (16, [27, 27, 27, 27])}


def gmul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        b >>= 1
        a <<= 1
        if a & 0x100:
            a ^= 0x11D
    return r & 0xFF


def bch_ok(code15):
    rem = 0
    for i in range(14, -1, -1):
        rem = (rem << 1) | ((code15 >> i) & 1)
        if rem & 0x400:
            rem ^= 0x537
    return rem == 0


def mask_bit(mask, r, c):
    return (
        (r + c) % 2 == 0 if mask == 0 else
        r % 2 == 0 if mask == 1 else
        c % 3 == 0 if mask == 2 else
        (r + c) % 3 == 0 if mask == 3 else
        (r // 2 + c // 3) % 2 == 0 if mask == 4 else
        (r * c) % 2 + (r * c) % 3 == 0 if mask == 5 else
        ((r * c) % 2 + (r * c) % 3) % 2 == 0 if mask == 6 else
        ((r + c) % 2 + (r * c) % 3) % 2 == 0
    )


def decode_qr(m):
    """Decode a matrix produced by qr_matrix; returns (text, mask)."""
    n = len(m)
    version = (n - 17) // 4
    assert 1 <= version <= 6, f"bad version {version}"

    def bit(r, c):
        return 1 if m[r][c] else 0

    pos1 = ([(i, 8) for i in range(6)] + [(7, 8), (8, 8), (8, 7)] +
            [(8, 14 - i) for i in range(9, 15)])
    pos2 = ([(8, n - 1 - i) for i in range(8)] +
            [(n - 15 + i, 8) for i in range(8, 15)])
    f1 = f2 = 0
    for idx, (r, c) in enumerate(pos1):
        f1 |= bit(r, c) << idx
    for idx, (r, c) in enumerate(pos2):
        f2 |= bit(r, c) << idx
    assert f1 == f2, "format info copies disagree"
    code = f1 ^ 0x5412
    assert bch_ok(code), f"format info BCH invalid: {code:015b}"
    ec_level = (code >> 13) & 3
    mask = (code >> 10) & 7
    assert ec_level == 0, f"expected EC level M, got {ec_level:#b}"

    reserved = [[False] * n for _ in range(n)]
    for r0, c0 in ((0, 0), (0, n - 7), (n - 7, 0)):
        for dr in range(-1, 8):
            for dc in range(-1, 8):
                r, c = r0 + dr, c0 + dc
                if 0 <= r < n and 0 <= c < n:
                    reserved[r][c] = True
    if version >= 2:
        for dr in range(-2, 3):
            for dc in range(-2, 3):
                reserved[n - 7 + dr][n - 7 + dc] = True
    for i in range(8, n - 8):
        reserved[6][i] = reserved[i][6] = True
    reserved[n - 8][8] = True
    for r, c in pos1 + pos2:
        reserved[r][c] = True

    # structural spot checks: finders, timing, dark module
    assert m[n - 8][8], "dark module missing"
    for r in range(7):
        for c in range(7):
            expect = max(abs(r - 3), abs(c - 3)) != 2
            assert m[r][c] == expect, f"finder module wrong at {(r, c)}"
            assert m[n - 1 - r][c] == expect and m[r][n - 1 - c] == expect
    for i in range(8, n - 8):
        assert m[6][i] == (i % 2 == 0) and m[i][6] == (i % 2 == 0), \
            "timing pattern wrong"
    if version >= 2:
        for dr in range(-2, 3):
            for dc in range(-2, 3):
                assert m[n - 7 + dr][n - 7 + dc] == (max(abs(dr), abs(dc)) != 1), \
                    "alignment pattern wrong"

    bits = []
    right = n - 1
    while right >= 1:
        upward = ((right + 1) & 2) == 0
        for vert in range(n):
            r = (n - 1 - vert) if upward else vert
            for dc in range(2):
                c = right - dc
                if not reserved[r][c]:
                    bits.append(int(m[r][c]) ^ int(mask_bit(mask, r, c)))
        right = 5 if right == 8 else right - 2

    ec_count, blocks = QR_BLOCKS[version]
    dcw_count = sum(blocks)
    cw = [0] * ((len(bits) + 7) // 8)
    for i, b in enumerate(bits):
        cw[i // 8] = (cw[i // 8] << 1) | b

    data_blocks = [[] for _ in blocks]
    i = 0
    for k in range(max(blocks)):
        for bi, blk in enumerate(data_blocks):
            if k < blocks[bi]:
                blk.append(cw[i])
                i += 1
    ec_blocks = [[] for _ in blocks]
    for k in range(ec_count):
        for blk in ec_blocks:
            blk.append(cw[i])
            i += 1
    for blk, eblk in zip(data_blocks, ec_blocks):
        poly = blk + eblk
        for i in range(ec_count):  # syndrome i: evaluate the poly at alpha^i
            acc = 0
            x = 1
            for _ in range(i):
                x = gmul(x, 2)
            for c in poly:
                acc = gmul(acc, x) ^ c
            assert acc == 0, f"RS syndrome {i} nonzero in block {blk[:4]}"

    stream = "".join(format(cwv, "08b") for blk in data_blocks for cwv in blk)
    assert stream[0:4] == "0100", f"expected byte mode, got {stream[0:4]}"
    count = int(stream[4:12], 2)
    assert 1 <= count <= (dcw_count * 8 - 12) // 8, "bad char count"
    data = bytes(int(stream[12 + 8 * j:20 + 8 * j], 2) for j in range(count))
    return data.decode("utf-8"), mask


# --------------------------------------------------------------------------

class QRTests(unittest.TestCase):
    """Verify the QR encoder output decodes back to its input."""

    strings = [
        "http://192.168.1.4:8000/",
        "http://192.168.1.4:8000/Ab3CdEfGhIjKlMnOpQrSt/",
        "http://255.255.255.255:65535/0123456789abcdef0123456789abcdef/",
        # capacity boundaries of versions 1-6 (EC level M, byte mode)
        "A" * 14, "B" * 26, "C" * 42, "D" * 62, "E" * 84, "F" * 106,
        "x", "scan-me://a=b&c=d#frag,id=", "Mees Kees Stuur",
    ]

    @classmethod
    def setUpClass(cls):
        cls.fds = load_server()

    def test_round_trip(self):
        for text in self.strings:
            with self.subTest(text=text[:40]):
                m = self.fds.qr_matrix(text)
                out, _ = decode_qr(m)
                self.assertEqual(out, text)
                self.assertEqual(len(m), len(m[0]))  # square

    def test_versions_and_capacity(self):
        caps = {1: 14, 2: 26, 3: 42, 4: 62, 5: 84, 6: 106}
        for version, cap in caps.items():
            with self.subTest(version=version):
                n = 17 + 4 * version
                m = self.fds.qr_matrix("z" * (cap - 1))
                self.assertEqual(len(m), n)
                m2 = self.fds.qr_matrix("z" * cap)
                self.assertEqual(len(m2), n)  # still this version at capacity
                if version < 6:  # v6 is the last supported version
                    m3 = self.fds.qr_matrix("z" * (cap + 1))
                    self.assertEqual(len(m3), n + 4)  # spills to next version
        with self.assertRaises(ValueError):
            self.fds.qr_matrix("z" * 107)  # beyond v6 capacity

    def test_too_long_raises(self):
        with self.assertRaises(ValueError):
            self.fds.qr_matrix("Z" * 107)

    def test_matrices_are_deterministic(self):
        m1 = self.fds.qr_matrix("http://10.0.0.1:8000/")
        m2 = self.fds.qr_matrix("http://10.0.0.1:8000/")
        self.assertEqual(m1, m2)

    def test_pad_codewords_alternate_from_ec(self):
        # regression: pad codewords must alternate EC,11 starting with EC,
        # regardless of how many bytes the message itself occupied.
        # (length, message codewords consumed incl. mode/count/terminator)
        for length, msg_cw in ((3, 5), (4, 6), (14, 16)):
            with self.subTest(length=length):
                version, cw = self.fds._qr_codewords(bytes([0x41] * length))
                self.assertEqual(version, 1)  # single block: cw[:16] = data
                dcw = sum(self.fds.QR_BLOCKS[version][1])
                data = cw[:dcw]
                message, pads = data[:msg_cw], data[msg_cw:]
                self.assertNotIn(0xEC, message)
                expected = [0xEC, 0x11] * (len(pads) // 2)
                expected += [0xEC] if len(pads) % 2 else []
                self.assertEqual(pads, expected)

    def test_terminal_rendering(self):
        m = self.fds.qr_matrix("http://192.168.1.4:8000/")
        out = self.fds.qr_terminal(m)
        lines = out.split("\n")
        w = len(m) + 8  # 4-module quiet zone on each side
        self.assertEqual(len(lines), (w + 1) // 2)  # 2 rows per line
        for line in lines:
            bare = re.sub(r"\x1b\[[0-9;]*m", "", line)
            self.assertEqual(len(bare), w)
            self.assertTrue(line.startswith("\x1b[30;107m"))
            self.assertTrue(line.endswith("\x1b[0m"))
        self.assertEqual(set(re.sub(r"\x1b\[[0-9;]*m", "", lines[0])), {" "})
        self.assertEqual(set(re.sub(r"\x1b\[[0-9;]*m", "", lines[-1])), {" "})
        self.assertIn("▀", out)  # actually renders QR modules

    def test_decodes_with_every_mask_valid(self):
        # build with each of the 8 masks and check the decoder recovers it
        text = "http://192.168.1.4:8000/token-abc/"
        version, codewords = self.fds._qr_codewords(text.encode())
        for mask in range(8):
            with self.subTest(mask=mask):
                grid, reserved = self.fds._qr_function_patterns(version)
                self.fds._place_data(grid, reserved, codewords)
                n = len(grid)
                for r in range(n):
                    for c in range(n):
                        if not reserved[r][c] and self.fds._mask_bit(mask, r, c):
                            grid[r][c] = not grid[r][c]
                self.fds._draw_format(grid, mask)
                out, read_mask = decode_qr(grid)
                self.assertEqual(out, text)
                self.assertEqual(read_mask, mask)


class SafeNameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fds = load_server(["--dir", "/tmp"])
        cls.tmp = tempfile.TemporaryDirectory()
        cls.fds.UPLOAD_DIR = cls.tmp.name

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_plain_names_kept(self):
        for raw in ("f.txt", "pwn", "photo (1).jpg", "weird [a-b].tar.gz"):
            with self.subTest(raw=raw):
                self.assertEqual(self.fds.safe_name(raw), raw)

    def test_traversal_collapsed_to_basename(self):
        for raw, expected in (("../../pwn", "pwn"),
                               ("../../../etc/pwn", "pwn"),
                               ("..\\..\\pwn", "pwn"),
                               ("../pwn", "pwn"),
                               ("/etc/passwd", "passwd"),
                               ("C:\\temp\\pwn", "pwn"),
                               ("%2e%2e%2fpwn", "pwn"),
                               ("%2e%2e%5cpwn", "pwn")):
            with self.subTest(raw=raw):
                self.assertEqual(self.fds.safe_name(raw), expected)

    def test_hidden_and_dot_names_rejected(self):
        # leading dots are stripped: ".bashrc" is saved as "bashrc"
        self.assertEqual(self.fds.safe_name(".bashrc"), "bashrc")
        for raw in (".", "..", "...", ""):
            with self.subTest(raw=raw):
                self.assertRegex(self.fds.safe_name(raw),
                                 r"^file_\d{8}_\d{6}_\d+$")

    def test_control_chars_stripped(self):
        self.assertEqual(self.fds.safe_name("na\x00me\x07.txt"), "name.txt")
        self.assertEqual(self.fds.safe_name("run\r\nsh"), "runsh")

    def test_unsafe_characters_replaced(self):
        self.assertEqual(self.fds.safe_name("héü&$;ls.txt"), "h_____ls.txt")
        self.assertEqual(self.fds.safe_name("it's;rm -rf"), "it_s_rm -rf")

    def test_existing_file_gets_timestamp_suffix(self):
        orig = os.path.join(self.tmp.name, "exists.txt")
        open(orig, "w").close()
        name = self.fds.safe_name("exists.txt")
        self.assertRegex(name, r"^exists_\d{8}_\d{6}\.txt$")
        self.assertNotEqual(name, "exists.txt")  # won't overwrite the original
        self.assertTrue(os.path.exists(orig))

    def test_download_lookup(self):
        good = os.path.join(self.tmp.name, "good file (1) [x].txt")
        open(good, "w").close()
        sub = os.path.join(self.tmp.name, "sub")
        os.mkdir(sub)
        # resolves an uploaded-style name to its path
        found = self.fds.download_lookup("good%20file%20(1)%20%5Bx%5D.txt")
        self.assertEqual(os.path.basename(found), "good file (1) [x].txt")
        # directories, hidden, traversal and unknown names are rejected
        for raw in ("sub", "sub/", ".bashrc", "..", "../../etc/passwd",
                    "%2e%2e/etc/passwd", "nope.txt", "", "a/b.txt",
                    "na\x00me.txt"):
            with self.subTest(raw=raw):
                self.assertIsNone(self.fds.download_lookup(raw))


class ServerTestBase(unittest.TestCase):
    """Boots the real server on 127.0.0.1 with an ephemeral port."""

    secret = ()

    @classmethod
    def setUpClass(cls):
        cls.upload_dir = tempfile.TemporaryDirectory()
        cls.fds = load_server(["--dir", cls.upload_dir.name, *cls.secret])
        cls.fds.Handler.log_message = lambda *a, **k: None  # quiet logs
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), cls.fds.Handler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.upload_dir.cleanup()

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            return conn.getresponse()
        finally:
            conn.close()

    def get(self, path):
        return self.request("GET", path)

    def post_upload(self, path, body, ctype):
        return self.request("POST", path, body, {"Content-Type": ctype})

    def saved_files(self):
        return sorted(os.listdir(self.upload_dir.name))

    def read_saved(self, name):
        with open(os.path.join(self.upload_dir.name, name), "rb") as fh:
            return fh.read()

    def upload_ok(self, path, filename, content):
        body, ctype = multipart(filename, content)
        resp = self.post_upload(path, body, ctype)
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.read(), b"OK")


class PlainServerTests(ServerTestBase):
    secret = ("--insecure",)

    def test_get_index(self):
        for path in ("/", "/index.html"):
            with self.subTest(path=path):
                resp = self.get(path)
                self.assertEqual(resp.status, 200)
                page = resp.read().decode()
                self.assertIn("Drop files here", page)
                self.assertIn("fetch('upload'", page)  # relative upload path
                self.assertIn("Saved files", page)
                self.assertIn("fetch('files'", page)   # relative listing path
                self.assertIn("fl/", page)             # relative download path

    def test_get_unknown_404(self):
        self.assertEqual(self.get("/nonsense").status, 404)
        self.assertEqual(self.get("/files/").status, 404)

    def test_files_listing_json(self):
        self.upload_ok("/upload", "zz.txt", b"z" * 10)
        self.upload_ok("/upload", "aa.txt", b"a" * 3)
        resp = self.get("/files")
        self.assertEqual(resp.status, 200)
        self.assertIn("application/json", resp.getheader("Content-Type"))
        items = json.loads(resp.read())
        names = [it["name"] for it in items]
        self.assertIn("aa.txt", names)
        self.assertIn("zz.txt", names)
        sizes = {it["name"]: it["size"] for it in items}
        self.assertEqual(sizes["aa.txt"], 3)
        self.assertEqual(sizes["zz.txt"], 10)

    def test_download_file(self):
        self.upload_ok("/upload", "dl.bin", b"\x00\x01payload")
        resp = self.get("/fl/dl.bin")
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.read(), b"\x00\x01payload")
        self.assertEqual(resp.getheader("Content-Type"),
                         "application/octet-stream")
        self.assertIn('attachment; filename="dl.bin"',
                      resp.getheader("Content-Disposition"))
        self.assertEqual(int(resp.getheader("Content-Length")), 9)

    def test_download_traversal_rejected(self):
        self.upload_ok("/upload", "guard.bin", b"contained")
        for frag in ("..%2flandir.py", "sub/../../landir.py",
                    "%2e%2e%2flandir.py",
                    "..%2f..%2fetc%2fpasswd",
                    "fl%2f..%2flandir.py"):
            with self.subTest(frag=frag):
                resp = self.get("/fl/" + frag)
                self.assertEqual(resp.status, 404)
        # a name that exists only outside the uploads dir never resolves
        self.assertEqual(self.get("/fl/landir.py").status, 404)

    def test_download_hidden_or_unknown_404(self):
        for name in (".bashrc", "nope.txt", "sub/zz.txt"):
            with self.subTest(name=name):
                self.assertEqual(self.get("/fl/" + name).status, 404)

    def test_upload_saves_content(self):
        self.upload_ok("/upload", "hello.txt", b"hello world")
        self.assertIn("hello.txt", self.saved_files())
        self.assertEqual(self.read_saved("hello.txt"), b"hello world")

    def test_upload_traversal_lands_inside(self):
        self.upload_ok("/upload", "../../pwn", b"pwned")
        self.assertIn("pwn", self.saved_files())
        self.assertEqual(self.read_saved("pwn"), b"pwned")
        self.assertEqual(self.saved_files().count("pwn"), 1)

    def test_upload_without_file_400(self):
        _, ctype = multipart("nosuchfile", b"x")
        body = b"--testboundary42--\r\n"  # no file part at all
        resp = self.post_upload("/upload", body, ctype)
        self.assertEqual(resp.status, 400)

    def test_post_unknown_404(self):
        self.assertEqual(
            self.request("POST", "/other", b"x", {}).status, 404)

    def test_malformed_content_type_400(self):
        resp = self.request("POST", "/upload", b"junk",
                            {"Content-Type": "text/plain"})
        self.assertEqual(resp.status, 400)

    def test_bad_content_length_400(self):
        # negative or non-numeric Content-Length must 400, not crash
        for value in ("-5", "twelve"):
            with self.subTest(cl=value):
                resp = self.request(
                    "POST", "/upload", b"",
                    {"Content-Type": "multipart/form-data; boundary=B",
                     "Content-Length": value})
                self.assertEqual(resp.status, 400)

    def test_content_length_missing_400(self):
        # chunked-style posts without Content-Length get no data -> 400
        resp = self.request(
            "POST", "/upload", b"",
            {"Content-Type": "multipart/form-data; boundary=B"})
        self.assertEqual(resp.status, 400)

    def test_directory_listing_includes_folders(self):
        # Create a directory structure
        folder_path = os.path.join(self.upload_dir.name, "testfolder")
        os.makedirs(folder_path)
        with open(os.path.join(folder_path, "inner.txt"), "wb") as f:
            f.write(b"inner content")
        with open(os.path.join(self.upload_dir.name, "root.txt"), "wb") as f:
            f.write(b"root content")
        
        # List root directory - should include both files and directories
        resp = self.get("/files")
        self.assertEqual(resp.status, 200)
        items = json.loads(resp.read())
        names = [it["name"] for it in items]
        self.assertIn("root.txt", names)
        self.assertIn("testfolder", names)
        
        # Check that directories have is_dir=True
        dir_item = next(it for it in items if it["name"] == "testfolder")
        self.assertTrue(dir_item["is_dir"])
        self.assertEqual(dir_item["size"], 0)
        
        # Check that files have is_dir=False
        file_item = next(it for it in items if it["name"] == "root.txt")
        self.assertFalse(file_item["is_dir"])
        self.assertEqual(file_item["size"], 12)

    def test_directory_listing_with_path(self):
        # Create a directory structure
        folder_path = os.path.join(self.upload_dir.name, "testfolder2")
        os.makedirs(folder_path, exist_ok=True)
        with open(os.path.join(folder_path, "inner.txt"), "wb") as f:
            f.write(b"inner content")
        
        # List the subdirectory
        resp = self.get("/ls/testfolder2")
        self.assertEqual(resp.status, 200)
        items = json.loads(resp.read())
        names = [it["name"] for it in items]
        self.assertIn("inner.txt", names)
        
        # Check that the file has correct properties
        file_item = next(it for it in items if it["name"] == "inner.txt")
        self.assertFalse(file_item["is_dir"])
        self.assertEqual(file_item["size"], 13)

    def test_download_file_from_subdirectory(self):
        # Create a directory structure
        folder_path = os.path.join(self.upload_dir.name, "testfolder3")
        os.makedirs(folder_path, exist_ok=True)
        with open(os.path.join(folder_path, "inner.txt"), "wb") as f:
            f.write(b"inner content")
        
        # Download file from subdirectory
        resp = self.get("/fl/testfolder3/inner.txt")
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.read(), b"inner content")
        self.assertEqual(resp.getheader("Content-Type"), "application/octet-stream")
        self.assertIn('attachment; filename="inner.txt"',
                      resp.getheader("Content-Disposition"))

    def test_directory_traversal_rejected_in_download(self):
        # Create a directory structure
        folder_path = os.path.join(self.upload_dir.name, "testfolder4")
        os.makedirs(folder_path, exist_ok=True)
        with open(os.path.join(folder_path, "inner.txt"), "wb") as f:
            f.write(b"inner content")
        
        # Try to access file with traversal
        resp = self.get("/fl/testfolder/../root.txt")
        self.assertEqual(resp.status, 404)
        
        # Try to access with absolute path
        resp = self.get("/fl//etc/passwd")
        self.assertEqual(resp.status, 404)

    def test_directory_listing_traversal_rejected(self):
        # Create a directory structure
        folder_path = os.path.join(self.upload_dir.name, "testfolder5")
        os.makedirs(folder_path, exist_ok=True)
        
        # Try to list with traversal
        resp = self.get("/ls/../")
        self.assertEqual(resp.status, 404)
        
        # Try to list non-existent directory
        resp = self.get("/ls/nonexistent")
        self.assertEqual(resp.status, 404)


class SecretServerTests(ServerTestBase):
    secret = ()  # secret mode is the default

    def test_token_shape(self):
        self.fds.SECRET_TOKEN  # must exist by default (secret mode)
        self.assertRegex(self.fds.SECRET_TOKEN, r"^[A-Za-z0-9_-]{22}$")
        self.assertEqual(self.fds.PAGE_PATH, f"/{self.fds.SECRET_TOKEN}/")
        self.assertEqual(self.fds.UPLOAD_PATH,
                         f"/{self.fds.SECRET_TOKEN}/upload")

    def test_root_and_upload_are_hidden(self):
        self.assertEqual(self.get("/").status, 404)
        body, ctype = multipart("x.txt", b"x")
        self.assertEqual(self.post_upload("/upload", body, ctype).status, 404)
        self.assertEqual(self.get("/index.html").status, 404)

    def test_bare_token_redirects(self):
        resp = self.get("/" + self.fds.SECRET_TOKEN)
        self.assertEqual(resp.status, 302)
        self.assertEqual(resp.getheader("Location"),
                         f"/{self.fds.SECRET_TOKEN}/")

    def test_token_page_served(self):
        resp = self.get("/" + self.fds.SECRET_TOKEN + "/")
        self.assertEqual(resp.status, 200)
        self.assertIn("Drop files here", resp.read().decode())

    def test_upload_through_token(self):
        self.upload_ok("/" + self.fds.SECRET_TOKEN + "/upload",
                       "secret.txt", b"via token")
        self.assertIn("secret.txt", self.saved_files())
        self.assertEqual(self.read_saved("secret.txt"), b"via token")

    def test_wrong_token_404(self):
        other = "x" * 22
        self.assertNotEqual(other, self.fds.SECRET_TOKEN)
        self.assertEqual(self.get(f"/{other}/").status, 404)
        body, ctype = multipart("x.txt", b"x")
        self.assertEqual(self.post_upload(f"/{other}/upload", body,
                                          ctype).status, 404)

    def test_token_prefix_mismatch_404(self):
        # a prefix of the token is not the token
        partial = self.fds.SECRET_TOKEN[:-1]
        self.assertEqual(self.get(f"/{partial}/").status, 404)

    def test_listing_and_download_under_token(self):
        tok = "/" + self.fds.SECRET_TOKEN
        self.upload_ok(tok + "/upload", "s.txt", b"secret bytes")
        self.assertEqual(self.get("/files").status, 404)  # hidden at root
        self.assertEqual(self.get("/fl/s.txt").status, 404)
        resp = self.get(tok + "/files")
        self.assertEqual(resp.status, 200)
        self.assertIn("s.txt", [it["name"] for it in json.loads(resp.read())])
        dl = self.get(tok + "/fl/s.txt")
        self.assertEqual(dl.status, 200)
        self.assertEqual(dl.read(), b"secret bytes")
        other = "y" * 22
        self.assertEqual(self.get(f"/{other}/files").status, 404)
        self.assertEqual(self.get(f"/{other}/fl/s.txt").status, 404)


class StartupSmokeTest(unittest.TestCase):
    def test_startup_prints_url_with_qr(self):
        # grab a free port, then launch the real script
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        with tempfile.TemporaryDirectory() as updir:
            proc = subprocess.Popen(
                [sys.executable, SERVER, "--port", str(port),
                 "--dir", updir],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                deadline = time.time() + 10
                out = b""
                while time.time() < deadline:
                    line = proc.stdout.readline()
                    if not line:
                        break
                    out += line
                    text = out.decode()
                    # stop once the QR (rendered after the Open URL line)
                    # is fully printed or explicitly skipped
                    if ("(no QR" in line.decode()
                            or ("▀" in text and len(out) > 2000)):
                        break
                text = out.decode()
                self.assertIn("▀", text)  # QR rendered
                self.assertIn("Ctrl+C", text)
                # the printed URL points at this port and carries a token
                m = re.search(rf"Open http://[\d.]+:{port}/([A-Za-z0-9_-]+)/",
                              text)
                self.assertTrue(m, f"no token URL in output: {text[:200]!r}")
                self.assertRegex(m.group(1), r"^[A-Za-z0-9_-]{22}$")
            finally:
                proc.stdout.close()
                proc.terminate()
                proc.wait(timeout=5)


class ActivityTrackingTests(ServerTestBase):
    secret = ("--insecure",)

    def _events(self):
        return [t for _, t in self.fds.ACTIVITY.events()]

    def _wait_for_event(self, needle):
        # events are emitted from handler threads; poll briefly
        deadline = time.time() + 2
        while time.time() < deadline:
            if any(needle in e for e in self._events()):
                return
            time.sleep(0.02)
        self.fail(f"event {needle!r} not recorded: {self._events()}")

    def test_events_and_presence(self):
        self.upload_ok("/upload", "a.txt", b"abc")
        os.mkdir(os.path.join(self.upload_dir.name, "sub"))
        self.get("/files")
        self.get("/ls/sub")
        self.get("/")
        resp = self.get("/fl/a.txt")
        self.assertEqual(resp.status, 200)
        resp.read()
        self._wait_for_event("downloaded a.txt")
        events = self._events()
        self.assertTrue(any("127.0.0.1 uploaded a.txt (3 B)" in e
                            for e in events), events)
        self.assertTrue(any("127.0.0.1 downloaded a.txt (3 B)" in e
                            for e in events), events)
        # listing polls and page loads produce no log lines
        self.assertFalse(any("/files" in e or "/ls/" in e or '"GET' in e
                             for e in events), events)
        # every request (including the quiet ones) refreshed presence
        self.assertIn("127.0.0.1", self.fds.ACTIVITY.online())
        # errors are logged with the client IP
        resp = self.get("/fl/nope.txt")
        self.assertEqual(resp.status, 404)
        resp.read()
        self._wait_for_event("-> 404")
        events = self._events()
        self.assertTrue(any("127.0.0.1" in e and "-> 404" in e for e in events),
                        events)


class ClassifyRequestTests(unittest.TestCase):
    def setUp(self):
        self.m = load_server()

    def test_upload_is_event(self):
        self.assertEqual(self.m.classify_request("POST", self.m.UPLOAD_PATH),
                         "upload")

    def test_download_is_event(self):
        self.assertEqual(
            self.m.classify_request("GET", self.m.FILE_DOWNLOAD_PREFIX + "a.txt"),
            "download")

    def test_listing_and_page_are_quiet(self):
        self.assertIsNone(self.m.classify_request("GET", self.m.FILES_PATH))
        self.assertIsNone(
            self.m.classify_request("GET", self.m.FILES_LIST_PREFIX + "sub"))
        self.assertIsNone(self.m.classify_request("GET", self.m.PAGE_PATH))

    def test_query_string_ignored(self):
        self.assertEqual(
            self.m.classify_request("GET",
                                   self.m.FILE_DOWNLOAD_PREFIX + "a.txt?x=1"),
            "download")


class ActivityLogTests(unittest.TestCase):
    def setUp(self):
        self.m = load_server()

    def test_online_within_ttl(self):
        log = self.m.ActivityLog(ttl=10.0)
        log.touch("1.2.3.4")
        self.assertEqual(log.online(), ["1.2.3.4"])

    def test_expires_after_ttl(self):
        log = self.m.ActivityLog(ttl=10.0)
        log.touch("1.2.3.4")
        now = time.monotonic()
        self.assertEqual(log.online(now=now + 9.9), ["1.2.3.4"])
        # a poll every 2s keeps the client visible; 10s after the last one
        # it is shown offline
        self.assertEqual(log.online(now=now + 10.1), [])

    def test_any_request_refreshes_presence(self):
        log = self.m.ActivityLog(ttl=10.0)
        now = time.monotonic()
        log._last_seen["1.2.3.4"] = now - 8
        log.touch("1.2.3.4")
        self.assertEqual(log.online(now=now + 9.9), ["1.2.3.4"])

    def test_events_recorded_and_capped(self):
        log = self.m.ActivityLog(max_events=5)
        for i in range(10):
            log.add_event(f"e{i}")
        self.assertEqual([t for _, t in log.events()],
                         ["e5", "e6", "e7", "e8", "e9"])

    def test_presence_ttl_default_is_10s(self):
        self.assertEqual(self.m.PRESENCE_TTL, 10.0)


if __name__ == "__main__":
    unittest.main()
