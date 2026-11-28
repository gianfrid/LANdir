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
            # no color codes at all: modules inherit the terminal's fg/bg
            self.assertNotIn("\x1b", line)
        self.assertEqual(set(re.sub(r"\x1b\[[0-9;]*m", "", lines[0])), {" "})
        self.assertEqual(set(re.sub(r"\x1b\[[0-9;]*m", "", lines[-1])), {" "})
        self.assertIn("▀", out)  # actually renders QR modules

    def test_qr_terminal_no_color_codes(self):
        """Output contains no ANSI escapes: modules render in the terminal's
        default fg on its default bg, readable in light and dark terminals."""
        m = self.fds.qr_matrix("http://10.0.0.1:8000/")
        out = self.fds.qr_terminal(m)
        self.assertNotIn("\x1b", out)
        self.assertIn("▀", out)

    def test_qr_terminal_quiet_zone_blank(self):
        """First and last rendered lines are pure quiet zone (spaces)."""
        m = self.fds.qr_matrix("hi")
        out = self.fds.qr_terminal(m, quiet=2)
        bare = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in out.split("\n")]
        self.assertTrue(all(c == " " for c in bare[0]))
        self.assertTrue(all(c == " " for c in bare[-1]))

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


class _FakeCurses:
    """Just enough of the curses module to exercise the default-colors init."""

    class error(Exception):
        pass

    def __init__(self, supported=True):
        self.supported = supported
        self.use_default_colors_calls = 0

    def use_default_colors(self):
        if not self.supported:
            raise self.error("use_default_colors not supported")
        self.use_default_colors_calls += 1


class CursesDefaultColorsTests(unittest.TestCase):
    """The curses UI must drop ncurses' white-on-black screen assumption.

    On a color-capable terminal ncurses initializes the screen with explicit
    SGR 37/40 (white on black) and erases with it, whatever the user's actual
    theme — so a light terminal gets a dark UI and an inverted QR. The fix is
    use_default_colors(), which makes pair 0 mean "terminal defaults".
    """

    @classmethod
    def setUpClass(cls):
        cls.fds = load_server()

    def test_drops_white_on_black_assumption(self):
        fake = _FakeCurses(supported=True)
        self.assertTrue(self.fds._use_terminal_default_colors(fake))
        self.assertEqual(fake.use_default_colors_calls, 1)

    def test_tolerates_missing_extension(self):
        # some curses builds lack the extension; the UI must still start
        fake = _FakeCurses(supported=False)
        self.assertFalse(self.fds._use_terminal_default_colors(fake))


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

    def test_taken_timestamp_suffix_gets_unique_name(self):
        # two same-name uploads within the same second must not collide:
        # occupy both the plain name and the first timestamped candidate
        open(os.path.join(self.tmp.name, "exists.txt"), "w").close()
        first = self.fds.safe_name("exists.txt")
        open(os.path.join(self.tmp.name, first), "w").close()
        second = self.fds.safe_name("exists.txt")
        self.assertNotEqual(first, second)
        self.assertTrue(second.startswith("exists_"))
        self.assertTrue(second.endswith(".txt"))
        # the returned name must be free, and the earlier files untouched
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, second)))
        self.assertTrue(os.path.exists(os.path.join(self.tmp.name, "exists.txt")))
        self.assertTrue(os.path.exists(os.path.join(self.tmp.name, first)))

    def test_symlink_escape_rejected(self):
        # defense in depth (SPEC rule 1): a symlink planted inside the
        # uploads dir must not make safe_name/download_lookup resolve
        # outside it — this is the containment branch's whole purpose
        try:
            os.symlink("/etc/passwd", os.path.join(self.tmp.name, "evil"))
        except OSError:  # pragma: no cover - no symlink support (e.g. vfat)
            self.skipTest("symlinks not supported here")
        with self.assertRaises(ValueError):
            self.fds.safe_name("evil")
        self.assertIsNone(self.fds.download_lookup("evil"))
        # a dangling symlink is rejected too (never written through)
        os.symlink("/nonexistent-target-xyz",
                   os.path.join(self.tmp.name, "dangling"))
        with self.assertRaises(ValueError):
            self.fds.safe_name("dangling")

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

    def test_upload_leaves_no_staging_files(self):
        # the body is staged in a hidden temp file and published atomically:
        # nothing lingers besides the final name
        self.upload_ok("/upload", "atomic.txt", b"fully written")
        files = self.saved_files()
        self.assertIn("atomic.txt", files)
        self.assertFalse([f for f in files if f.startswith(".landir_tmp")],
                         "staging files must not linger after publish")
        self.assertEqual(self.read_saved("atomic.txt"), b"fully written")

    def test_listing_hides_hidden_names(self):
        # dot-prefixed files (incl. any in-flight staging temps) never
        # appear in the /files or /ls/ listings, and are not downloadable
        with open(os.path.join(self.upload_dir.name, ".hidden.txt"), "wb") as f:
            f.write(b"secret")
        os.makedirs(os.path.join(self.upload_dir.name, "hidsub"), exist_ok=True)
        with open(os.path.join(self.upload_dir.name, "hidsub", ".in.txt"),
                  "wb") as f:
            f.write(b"inner secret")
        self.upload_ok("/upload", "shown.txt", b"data")
        names = [it["name"] for it in json.loads(self.get("/files").read())]
        self.assertIn("shown.txt", names)
        self.assertNotIn(".hidden.txt", names)
        sub = [it["name"] for it in json.loads(self.get("/ls/hidsub").read())]
        self.assertEqual(sub, [])  # only the hidden file is in there
        self.assertEqual(self.get("/fl/.hidden.txt").status, 404)

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

    def test_symlink_escape_endpoints_404(self):
        # endpoints must not serve (or even list) a symlink that resolves
        # outside the uploads dir
        try:
            os.symlink("/etc/hostname",
                       os.path.join(self.upload_dir.name, "evil.txt"))
            os.symlink("/etc", os.path.join(self.upload_dir.name, "etcdir"))
        except OSError:  # pragma: no cover - no symlink support (e.g. vfat)
            self.skipTest("symlinks not supported here")
        self.assertEqual(self.get("/fl/evil.txt").status, 404)
        self.assertEqual(self.get("/ls/etcdir").status, 404)
        self.assertEqual(self.get("/fl/etcdir/passwd").status, 404)
        names = [it["name"] for it in json.loads(self.get("/files").read())]
        self.assertNotIn("evil.txt", names)
        self.assertNotIn("etcdir", names)

    def test_download_hidden_or_unknown_404(self):
        for name in (".bashrc", "nope.txt", "sub/zz.txt"):
            with self.subTest(name=name):
                self.assertEqual(self.get("/fl/" + name).status, 404)

    def test_upload_saves_content(self):
        self.upload_ok("/upload", "hello.txt", b"hello world")
        self.assertIn("hello.txt", self.saved_files())
        self.assertEqual(self.read_saved("hello.txt"), b"hello world")

    def test_upload_same_name_twice_keeps_both(self):
        # rapid re-upload of the same name (same second) must not overwrite
        # or lose either version
        self.upload_ok("/upload", "doc.bin", b"version-1")
        self.upload_ok("/upload", "doc.bin", b"version-2")
        files = [f for f in self.saved_files() if f.startswith("doc")]
        self.assertEqual(len(files), 2)
        contents = sorted(self.read_saved(f) for f in files)
        self.assertEqual(contents, [b"version-1", b"version-2"])

    def test_concurrent_same_name_uploads_never_collide(self):
        # SPEC rule 4: exclusive creation + suffix re-roll means N threads
        # uploading the same name must yield N distinct files, each content
        # preserved exactly once — no overwrite, no interleaving
        n = 8
        contents = [f"payload-{i}".encode() for i in range(n)]
        errors = []

        def worker(i):
            try:
                body, ctype = multipart("race.bin", contents[i])
                resp = self.post_upload("/upload", body, ctype)
                if resp.status != 200:
                    errors.append(f"worker {i}: status {resp.status}")
                resp.read()
            except Exception as e:  # pragma: no cover - failure detail
                errors.append(f"worker {i}: {e!r}")

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)
        self.assertEqual(errors, [])
        files = [f for f in self.saved_files() if f.startswith("race")]
        self.assertEqual(len(files), n, files)
        got = sorted(self.read_saved(f) for f in files)
        self.assertEqual(got, sorted(contents))

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
                            or "▀" in text):
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
        # the ACTIVITY log is shared across this class's tests: only events
        # recorded during THIS test are asserted on
        baseline = set(self._events())

        def fresh():
            return [e for e in self._events() if e not in baseline]

        self.upload_ok("/upload", "a.txt", b"abc")
        os.mkdir(os.path.join(self.upload_dir.name, "sub"))
        self.get("/files")
        self.get("/ls/sub")
        self.get("/")
        resp = self.get("/fl/a.txt")
        self.assertEqual(resp.status, 200)
        resp.read()
        self._wait_for_event("downloaded a.txt")
        events = fresh()
        self.assertTrue(any("127.0.0.1 uploaded a.txt (3 B)" in e
                            for e in events), events)
        self.assertTrue(any("127.0.0.1 downloaded a.txt (3 B)" in e
                            for e in events), events)
        # listing polls and page loads produce no log lines
        self.assertFalse(any("/files" in e or "/ls/" in e for e in events),
                         events)
        # error events have the shape "IP GET /path -> code"; none yet
        self.assertFalse(
            any(re.search(r"\bGET .* -> [45]\d\d", e) for e in events),
            events)
        # every request (including the quiet ones) refreshed presence
        self.assertIn("127.0.0.1", self.fds.ACTIVITY.online())
        # errors are logged with the client IP
        resp = self.get("/fl/nope.txt")
        self.assertEqual(resp.status, 404)
        resp.read()
        self._wait_for_event("GET /fl/nope.txt -> 404")
        events = fresh()
        self.assertTrue(any("127.0.0.1" in e and "-> 404" in e for e in events),
                        events)

    def test_event_control_chars_stripped(self):
        # event text embeds client-supplied paths/names: raw control bytes
        # (terminal escape sequences) must never reach a log or the UI pane
        self.fds.emit_event("x\x1b]52;c;oops\x07 y\x00z")
        self.assertTrue(any(e == "x]52;c;oops yz" for e in self._events()),
                        self._events())

    def test_stalled_upload_connection_closed(self):
        # a client that promises a body then stalls must not pin the
        # handler thread forever: the socket timeout closes the connection
        self.fds.Handler.timeout = 2
        try:
            s = socket.create_connection(("127.0.0.1", self.port), timeout=10)
            s.sendall(b"POST /upload HTTP/1.1\r\nHost: x\r\n"
                      b"Content-Type: multipart/form-data; boundary=B\r\n"
                      b"Content-Length: 100\r\n\r\n"
                      b"partial")
            deadline = time.time() + 8
            closed = False
            while time.time() < deadline:
                if not s.recv(1):  # server closed the connection
                    closed = True
                    break
            s.close()
            self.assertTrue(closed, "connection was not closed on stall")
        finally:
            self.fds.Handler.timeout = 60

    def test_download_vanished_file_is_clean_404(self):
        # a file that vanishes between lookup and open must answer a clean
        # 404 — not an unhandled OSError and a reset connection
        orig = self.fds.download_lookup
        self.fds.download_lookup = lambda raw: os.path.join(
            self.upload_dir.name, "gone.txt")
        try:
            resp = self.get("/fl/gone.txt")
            self.assertEqual(resp.status, 404)
            resp.read()
        finally:
            self.fds.download_lookup = orig

    def test_upload_save_failure_is_500_with_event(self):
        # a server-side save failure (disk full, uploads dir gone) must
        # surface as a 500 with an event — not as a client-error 400
        orig = self.fds.save_unique
        def boom(name, data):
            raise OSError(28, "No space left on device")
        self.fds.save_unique = boom
        try:
            body, ctype = multipart("fail.txt", b"x")
            resp = self.post_upload("/upload", body, ctype)
            self.assertEqual(resp.status, 500)
            resp.read()
        finally:
            self.fds.save_unique = orig
        self._wait_for_event("save failed for 'fail.txt'")
        # the client is not misreported: no "No file saved" 400 was sent
        self.assertFalse(any("No file saved" in e for e in self._events()),
                         self._events())


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


# --------------------------------------------------------------------------
# Port selection: _find_available_port (occupied fallback, --port 0 semantics)

class FindAvailablePortTest(unittest.TestCase):
    def setUp(self):
        self.m = load_server()

    def test_free_port_is_returned_unchanged(self):
        probe = socket.socket()
        probe.bind(("0.0.0.0", 0))
        free = probe.getsockname()[1]
        probe.close()
        self.assertEqual(self.m._find_available_port(free), free)

    def test_occupied_port_falls_back_to_random_high_port(self):
        blocker = socket.socket()
        blocker.bind(("0.0.0.0", 0))
        blocker.listen(1)  # an active listener makes the probe bind fail
        try:
            busy = blocker.getsockname()[1]
            picked = self.m._find_available_port(busy)
        finally:
            blocker.close()
        self.assertNotEqual(picked, busy)
        self.assertGreaterEqual(picked, 32768)
        self.assertLessEqual(picked, 60999)

    def test_port_zero_picks_random_high_port(self):
        # 0 delegates the choice; the dynamic/private range is documented
        # behavior (README), so every draw must land inside it.
        for _ in range(20):
            picked = self.m._find_available_port(0)
            self.assertGreaterEqual(picked, 32768)
            self.assertLessEqual(picked, 60999)


# --------------------------------------------------------------------------
# Sealed (encrypted) mode: pure-stdlib crypto vectors + the sealed endpoints.
#
# The golden fixture below is generated from landir.py itself with fixed
# seeds/nonces (deterministic), so the Rust implementation asserts the very
# same bytes — cross-implementation interop for the sealed wire format. Every
# input (seeds, nonces, plaintexts) is listed in the fixture, so it is
# self-describing: test_golden_envelopes regenerates the envelope bytes from
# those inputs and compares.

GOLDEN = {
    "host_seed": "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
    "eph_seed": "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f",
    "req_nonce": "404142434445464748494a4b",
    "resp_nonce": "4c4d4e4f5051525354555657",
    "host_pub": "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f",
    "eph_pub": "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254",
    "plain_request": "474554202f7366696c6573207365616c65642d7265717565737420706c61696e74657874200001ff",
    "plain_response": "4f4b",
    "request_envelope": "4c358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254404142434445464748494a4ba50700f235613b0e9c31b428bdf931d3d8a49e1e61723c0b8953c0c93316a6bf92ff590ec93e4bc79ddde75311595449ee97ab76dc314ec3",
    "response_envelope": "4c4c4d4e4f5051525354555657dd7a15c1f47c7d5f327d68b3c00a4190078e",
}


def _unhex(s):
    return bytes.fromhex(s)


class CryptoVectorTests(unittest.TestCase):
    """RFC test vectors for the sealed-mode primitives (X25519 RFC 7748,
    HKDF RFC 5869, ChaCha20-Poly1305 RFC 8439) plus the golden envelopes."""

    @classmethod
    def setUpClass(cls):
        cls.key_dir = tempfile.TemporaryDirectory()
        os.environ["LANDIR_KEY_DIR"] = cls.key_dir.name
        cls.fds = load_server(["--dir", tempfile.mkdtemp(), "--encrypt"])

    @classmethod
    def tearDownClass(cls):
        del os.environ["LANDIR_KEY_DIR"]
        cls.key_dir.cleanup()

    def test_x25519_rfc7748_vectors(self):
        fds = self.fds
        cases = [
            ("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
             "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
             "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"),
            ("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d",
             "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493",
             "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"),
        ]
        for scalar, u, expected in cases:
            with self.subTest(scalar=scalar[:12]):
                self.assertEqual(fds._x25519(_unhex(scalar), _unhex(u)).hex(),
                                 expected)
        # base-point multiplication
        self.assertEqual(
            fds._x25519_base(_unhex(
                "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
            )).hex(),
            "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")

    def test_x25519_low_order_point_rejected(self):
        # An all-zero result (low-order point, RFC 7748 §6.1) yields a known
        # shared secret and must be rejected. u = 0, u = 1 and u = p-1 are
        # genuine low-order points; a wrong-length key never reaches the
        # ladder at all.
        p_minus_1 = (2**255 - 20).to_bytes(32, "little")
        for u in (bytes(32), (1).to_bytes(32, "little"), p_minus_1):
            with self.subTest(u=u.hex()[:10]):
                self.assertIsNone(self.fds._shared_secret(b"\x01" * 32, u))
        # malformed input lengths are rejected before the ladder
        self.assertIsNone(self.fds._shared_secret(b"\x01" * 32, b"\x05"))
        self.assertIsNone(self.fds._shared_secret(b"\x01" * 32, b"\x05" * 33))

    def test_hkdf_sha256_rfc5869_test_case_3(self):
        # RFC 5869 A.3: SHA-256, zero-length salt and info — exactly the path
        # the sealed envelopes use (empty salt = HashLen zero bytes). Both
        # constants are the RFC's published values, so this anchors extract
        # AND expand against an external reference.
        import hashlib
        import hmac as hmac_mod
        fds = self.fds
        ikm = b"\x0b" * 22
        prk = hmac_mod.new(b"\x00" * 32, ikm, hashlib.sha256).digest()
        self.assertEqual(prk.hex(),
                         "19ef24a32c717b167f33a91d6f648bdf"
                         "96596776afdb6377ac434c1c293ccb04")
        self.assertEqual(fds._hkdf_sha256(ikm, b"", 42).hex(),
                         "8da4e775a563c18f715f802a063c5a31"
                         "b8a11f5c5ee1879ec3454e5f3c738d2d"
                         "9d201395faa4b61a96c8")
        # distinct info strings derive distinct keys (request vs response)
        self.assertNotEqual(fds._hkdf_sha256(ikm, fds.HKDF_INFO_REQUEST),
                            fds._hkdf_sha256(ikm, fds.HKDF_INFO_RESPONSE))

    def test_chacha20_poly1305_rfc8439_vector(self):
        fds = self.fds
        key = bytes.fromhex(
            "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        nonce = bytes.fromhex("070000004041424344454647")
        aad = bytes.fromhex("50515253c0c1c2c3c4c5c6c7")
        pt = (b"Ladies and Gentlemen of the class of '99: If I could offer "
              b"you only one tip for the future, sunscreen would be it.")
        ct, mac = fds._aead_encrypt(key, nonce, pt, aad)
        self.assertEqual(ct.hex(),
                         "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"
                         "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3"
                         "692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7"
                         "bc3ff4def08e4b7a9de576d26586cec64b6116")
        self.assertEqual(mac.hex(), "1ae10b594f09e26a7e902ecbd0600691")
        self.assertEqual(fds._aead_decrypt(key, nonce, ct, mac, aad), pt)
        # a flipped mac bit must fail authentication
        bad_mac = mac[:-1] + bytes([mac[-1] ^ 1])
        self.assertIsNone(fds._aead_decrypt(key, nonce, ct, bad_mac, aad))

    def test_golden_envelopes(self):
        # fixed seeds/nonces -> byte-identical envelopes across
        # implementations (the Rust suite asserts the same hex)
        fds = self.fds
        host_seed = _unhex(GOLDEN["host_seed"])
        eph_seed = _unhex(GOLDEN["eph_seed"])
        host_pub = fds._x25519_base(host_seed)
        self.assertEqual(host_pub.hex(), GOLDEN["host_pub"])
        eph_pub = fds._x25519_base(eph_seed)
        self.assertEqual(eph_pub.hex(), GOLDEN["eph_pub"])
        env, used_eph = fds.seal_request(_unhex(GOLDEN["plain_request"]), host_pub,
                                        eph_priv=eph_seed,
                                        nonce=_unhex(GOLDEN["req_nonce"]))
        self.assertEqual(used_eph, eph_seed)
        self.assertEqual(env.hex(), GOLDEN["request_envelope"])
        resp = fds.seal_response(_unhex(GOLDEN["plain_response"]), eph_pub,
                                 host_seed, nonce=_unhex(GOLDEN["resp_nonce"]))
        self.assertEqual(resp.hex(), GOLDEN["response_envelope"])
        # and they open back
        self.assertEqual(fds.open_request(_unhex(GOLDEN["request_envelope"]),
                                         host_seed),
                         _unhex(GOLDEN["plain_request"]))
        self.assertEqual(fds.open_response(_unhex(GOLDEN["response_envelope"]),
                                          eph_seed, host_pub),
                         _unhex(GOLDEN["plain_response"]))

    def test_envelope_round_trip_and_tamper(self):
        fds = self.fds
        host_seed = fds.HOST_KEY
        host_pub = fds.host_public_key()
        env, eph = fds.seal_request(b"round trip \x00\xff", host_pub)
        self.assertEqual(fds.open_request(env, host_seed), b"round trip \x00\xff")
        resp = fds.seal_response(b"pong", fds.eph_public_key_of(env), host_seed)
        self.assertEqual(fds.open_response(resp, eph, host_pub), b"pong")
        # tampered ciphertext / mac / header all fail
        for pos in (0, 10, len(env) - 1):
            bad = bytearray(env)
            bad[pos] ^= 1
            self.assertIsNone(fds.open_request(bytes(bad), host_seed),
                              f"tamper at {pos} must fail")
        # truncated / garbage
        self.assertIsNone(fds.open_request(env[:-5], host_seed))
        self.assertIsNone(fds.open_request(b"garbage", host_seed))
        self.assertIsNone(fds.open_request(b"", host_seed))
        # a different host key cannot open it
        self.assertIsNone(fds.open_request(env, b"\x07" * 32))

    def test_seal_request_rejects_low_order_host_key(self):
        with self.assertRaises(ValueError):
            self.fds.seal_request(b"x", bytes(32))  # all-zero pubkey

    def test_host_key_persistence_and_corruption(self):
        fds = self.fds
        path = os.path.join(fds.host_key_dir(), fds.HOST_KEY_FILE)
        with open(path, "rb") as fh:
            first = fh.read()
        self.assertEqual(len(first), 32)
        self.assertEqual(fds.load_or_create_host_key(), first)  # stable
        # corrupt file: regenerated, not crash-looped
        with open(path, "wb") as fh:
            fh.write(b"short")
        second = fds.load_or_create_host_key()
        self.assertEqual(len(second), 32)
        self.assertNotEqual(second, b"short")
        # permissions are owner-only
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_advertised_url_with_key(self):
        fds = self.fds
        url = fds.advertised_url_with_key("http://192.168.1.4:8000/")
        self.assertIsNotNone(url)
        self.assertTrue(url.startswith("http://192.168.1.4:8000/#k="))
        import base64
        k = url.split("#k=", 1)[1]
        self.assertNotIn("=", k)  # padding stripped
        decoded = base64.urlsafe_b64decode(k + "=" * (-len(k) % 4))
        self.assertEqual(decoded, fds.host_public_key())
        # fits the QR encoder's version cap
        m = fds.qr_matrix(url)
        self.assertLessEqual(len(m), 41)
        # too long -> None (never truncate key material)
        long_url = "http://" + "a" * 100 + ":8000/"
        self.assertIsNone(fds.advertised_url_with_key(long_url))


class EncryptedServerTests(ServerTestBase):
    """--encrypt: only the sealed endpoints answer; every plaintext route
    (page included) is a blind 404."""

    secret = ("--encrypt",)

    @classmethod
    def setUpClass(cls):
        cls.key_dir = tempfile.TemporaryDirectory()
        os.environ["LANDIR_KEY_DIR"] = cls.key_dir.name
        super().setUpClass()

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        del os.environ["LANDIR_KEY_DIR"]
        cls.key_dir.cleanup()

    def sealed_post(self, path, plaintext):
        """POST a sealed request envelope; returns (status, opened plaintext
        or raw body). The response must authenticate under the host key."""
        fds = self.fds
        env, eph = fds.seal_request(plaintext, fds.host_public_key())
        resp = self.request("POST", path, env,
                            {"Content-Type": "application/octet-stream"})
        body = resp.read()
        if resp.status == 200:
            opened = fds.open_response(body, eph, fds.host_public_key())
            self.assertIsNotNone(opened, "sealed response must authenticate")
            return resp.status, opened
        return resp.status, body

    def sealed_upload(self, filename, content):
        boundary = "testboundary42"
        body, _ = multipart(filename, content)
        st, opened = self.sealed_post(
            "/supload", boundary.encode() + b"\r\n" + body)
        self.assertEqual(st, 200)
        self.assertEqual(opened, b"OK")

    def test_plaintext_routes_are_blind_404(self):
        for method, path in [("GET", "/"), ("GET", "/index.html"),
                             ("GET", "/files"), ("GET", "/fl/x"),
                             ("GET", "/ls/sub"), ("POST", "/upload"),
                             ("POST", "/snope"), ("POST", "/sfilesx")]:
            with self.subTest(method=method, path=path):
                resp = self.request(method, path, b"" if method == "POST" else None)
                self.assertEqual(resp.status, 404)
                resp.read()

    def test_sealed_upload_list_download_roundtrip(self):
        self.sealed_upload("hello.txt", b"sealed hello")
        self.assertEqual(self.read_saved("hello.txt"), b"sealed hello")

        st, body = self.sealed_post("/sfiles", b"")
        self.assertEqual(st, 200)
        names = [it["name"] for it in json.loads(body)]
        self.assertIn("hello.txt", names)

        st, body = self.sealed_post("/sfl", b"hello.txt")
        self.assertEqual(st, 200)
        self.assertEqual(body, b"sealed hello")

    def test_sealed_subdir_listing_and_download(self):
        folder = os.path.join(self.upload_dir.name, "sub")
        os.makedirs(folder)
        with open(os.path.join(folder, "inner.txt"), "wb") as f:
            f.write(b"inner content")
        st, body = self.sealed_post("/sls", b"sub")
        self.assertEqual(st, 200)
        self.assertIn("inner.txt", body.decode())
        st, body = self.sealed_post("/sfl", b"sub/inner.txt")
        self.assertEqual(st, 200)
        self.assertEqual(body, b"inner content")

    def test_sealed_listing_hides_hidden_names(self):
        with open(os.path.join(self.upload_dir.name, ".hidden.txt"), "wb") as f:
            f.write(b"secret")
        self.sealed_upload("shown.txt", b"data")
        st, body = self.sealed_post("/sfiles", b"")
        self.assertEqual(st, 200)
        names = [it["name"] for it in json.loads(body)]
        self.assertIn("shown.txt", names)
        self.assertNotIn(".hidden.txt", names)

    def test_sealed_traversal_still_lands_inside(self):
        # SPEC rule 1 below the crypto layer: a traversal filename inside a
        # sealed body is sanitized exactly like a plaintext one
        self.sealed_upload("../../pwn", b"pwned")
        self.assertIn("pwn", self.saved_files())
        self.assertEqual(self.read_saved("pwn"), b"pwned")
        # and traversal in sealed ls/fl paths is rejected
        st, _ = self.sealed_post("/sfl", b"../landir.py")
        self.assertEqual(st, 404)
        st, _ = self.sealed_post("/sls", b"../../etc")
        self.assertEqual(st, 404)
        st, _ = self.sealed_post("/sfl", b".hidden")
        self.assertEqual(st, 404)

    def test_sealed_same_name_twice_keeps_both(self):
        self.sealed_upload("doc.bin", b"version-1")
        self.sealed_upload("doc.bin", b"version-2")
        files = [f for f in self.saved_files() if f.startswith("doc")]
        self.assertEqual(len(files), 2)
        self.assertEqual(sorted(self.read_saved(f) for f in files),
                         [b"version-1", b"version-2"])

    def test_sealed_upload_without_file_400(self):
        boundary = "testboundary42"
        st, _ = self.sealed_post("/supload",
                                 boundary.encode() + b"\r\n"
                                 + b"--testboundary42--\r\n")
        self.assertEqual(st, 400)

    def test_sealed_upload_malformed_plaintext_400(self):
        # no CRLF boundary line inside the sealed plaintext
        st, _ = self.sealed_post("/supload", b"no boundary line here")
        self.assertEqual(st, 400)

    def test_sealed_bad_envelope_400(self):
        # garbage, wrong version byte, truncated, and tampered envelopes
        env, _ = self.fds.seal_request(b"x", self.fds.host_public_key())
        cases = [b"garbage", b"", bytes([0x4d]) + env[1:], env[:-3]]
        bad = bytearray(env)
        bad[-1] ^= 1
        cases.append(bytes(bad))
        for payload in cases:
            with self.subTest(payload=payload[:8].hex()):
                resp = self.request("POST", "/sfiles", payload,
                                    {"Content-Type": "application/octet-stream"})
                self.assertEqual(resp.status, 400)
                resp.read()

    def test_sealed_bad_content_length_400(self):
        for value in ("-5", "twelve"):
            with self.subTest(cl=value):
                resp = self.request("POST", "/sfiles", b"",
                                    {"Content-Type": "application/octet-stream",
                                     "Content-Length": value})
                self.assertEqual(resp.status, 400)
                resp.read()

    def test_sealed_wrong_key_cannot_open(self):
        # an envelope sealed to a different host key fails AEAD at this host
        other_pub = self.fds._x25519_base(b"\x09" * 32)
        env, _ = self.fds.seal_request(b"x", other_pub)
        resp = self.request("POST", "/sfiles", env,
                            {"Content-Type": "application/octet-stream"})
        self.assertEqual(resp.status, 400)
        resp.read()

    def test_sealed_events_logged(self):
        self.sealed_upload("evt.txt", b"abc")
        self.sealed_post("/sfl", b"evt.txt")
        events = [t for _, t in self.fds.ACTIVITY.events()]
        self.assertTrue(any("uploaded evt.txt (3 B)" in e for e in events),
                        events)
        self.assertTrue(any("downloaded evt.txt (3 B)" in e for e in events),
                        events)

    def test_sealed_endpoint_splices_rejected(self):
        # The endpoint is not authenticated (no AAD): a path-rewriting MITM
        # can post a valid sealed envelope to a different sealed endpoint.
        # Every cross-endpoint splice must fail with a visible 4xx — a 200
        # would make the client believe a dropped upload succeeded (or save
        # a listing as the downloaded file). The plaintext shapes are
        # mutually incompatible, and sfiles enforces its documented empty
        # plaintext, so nothing answers 200 for a redirected envelope.
        fds = self.fds
        host_pub = fds.host_public_key()
        boundary = "testboundary42"
        body, _ = multipart("splice-report.pdf", b"quarterly report")
        upload_plain = boundary.encode() + b"\r\n" + body
        with open(os.path.join(self.upload_dir.name, "splice-notes.txt"),
                  "wb") as f:
            f.write(b"my notes")
        os.makedirs(os.path.join(self.upload_dir.name, "splicedir"),
                    exist_ok=True)
        requests = {
            "upload": (fds.S_UPLOAD_PATH, upload_plain),
            "root-listing": (fds.S_FILES_PATH, b""),
            "sub-listing": (fds.S_LS_PATH, b"splicedir"),
            "download": (fds.S_FL_PATH, b"splice-notes.txt"),
        }
        for name, (intended, plaintext) in requests.items():
            for target in fds.SEALED_PATHS:
                if target == intended:
                    with self.subTest(name=name, target=target):
                        env, _ = fds.seal_request(plaintext, host_pub)
                        resp = self.request(
                            "POST", target, env,
                            {"Content-Type": "application/octet-stream"})
                        self.assertEqual(resp.status, 200)
                        resp.read()
                    continue
                with self.subTest(name=name, redirected_to=target):
                    env, _ = fds.seal_request(plaintext, host_pub)
                    resp = self.request(
                        "POST", target, env,
                        {"Content-Type": "application/octet-stream"})
                    self.assertIn(resp.status, (400, 404),
                                   f"{name} redirected to {target} answered "
                                   f"{resp.status}")
                    resp.read()

    def test_no_token_in_encrypted_mode(self):
        self.assertTrue(self.fds.ENCRYPTED)
        self.assertIsNone(self.fds.SECRET_TOKEN)
        self.assertEqual(self.fds.PAGE_PATH, "/")


class MaxUploadServerTests(ServerTestBase):
    """--max-upload: oversized uploads are rejected with 413 before their
    body is read or saved (the OOM vector — the body is buffered in memory
    otherwise, ~4x its size in transient copies)."""

    secret = ("--insecure", "--max-upload", "1000")

    def test_under_limit_upload_ok(self):
        self.upload_ok("/upload", "small.txt", b"x" * 200)
        self.assertEqual(self.read_saved("small.txt"), b"x" * 200)

    def test_over_limit_upload_413_not_saved(self):
        body, ctype = multipart("big.bin", b"x" * 2000)
        resp = self.post_upload("/upload", body, ctype)
        self.assertEqual(resp.status, 413)
        resp.read()
        self.assertNotIn("big.bin", self.saved_files())

    def test_oversized_rejected_before_the_body_is_read(self):
        # The 413 must come from the Content-Length header alone: a server
        # that reads first would block for its whole 60 s timeout and buffer
        # the promised body.
        s = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        try:
            s.sendall(b"POST /upload HTTP/1.1\r\nHost: x\r\n"
                      b"Content-Type: multipart/form-data; boundary=B\r\n"
                      b"Content-Length: 100000000\r\n\r\n"
                      b"--B\r\n")  # a sliver of the promised body
            data = s.recv(1024)  # answers within seconds, not the timeout
        finally:
            s.close()
        self.assertIn(b"413", data)
        # and nothing landed in the uploads dir
        self.assertEqual(self.saved_files(), [])


class MaxUploadEncryptedServerTests(EncryptedServerTests):
    """The same sealed surface under a --max-upload cap: the inherited
    small-payload tests re-run under the limit, and the oversize cases below
    prove a sealed upload is rejected before its envelope is buffered."""

    secret = ("--encrypt", "--max-upload", "1000")

    def test_sealed_over_limit_413_not_saved(self):
        fds = self.fds
        boundary = "testboundary42"
        body, _ = multipart("big.bin", b"x" * 2000)
        st, resp = self.sealed_post(
            "/supload", boundary.encode() + b"\r\n" + body)
        self.assertEqual(st, 413)
        self.assertNotIn("big.bin", self.saved_files())

    def test_sealed_just_under_limit_ok(self):
        boundary = "testboundary42"
        body, _ = multipart("edge.bin", b"y" * 800)  # + framing < 1000
        st, opened = self.sealed_post(
            "/supload", boundary.encode() + b"\r\n" + body)
        self.assertEqual(st, 200)
        self.assertEqual(opened, b"OK")
        self.assertEqual(self.read_saved("edge.bin"), b"y" * 800)

if __name__ == "__main__":
    unittest.main()
