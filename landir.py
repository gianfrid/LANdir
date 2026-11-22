#!/usr/bin/env python3
"""LANdir - a simple LAN file upload server.

Usage:
    python3 landir.py [--port PORT] [--dir UPLOADS_DIR] [--insecure]

Defaults: port 8000, uploads in ./uploads next to the script, secret mode ON.
At startup the server prints the address to open from any device on the
same network (e.g. an Android phone), rendered as a scannable QR code.
By default the pages live under a random unguessable URL path; the QR code
encodes that full path, and requests to any other path get a 404.
Pass --insecure (-i) to serve on plain /, /upload, ... URLs instead.
If the requested port is occupied, or --port 0 is given, a random high
port (32768-60999) is used instead.
"""

import argparse
import json
import os
import re
import secrets
import shutil
import sys
import socket
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote


def _parse_args():
    parser = argparse.ArgumentParser(
        description="LAN file upload server",
        usage="%(prog)s [--port PORT] [--dir UPLOADS_DIR] [--insecure]")
    parser.add_argument("--port", type=int, default=8000,
                        help="port to listen on (default: 8000; 0 or an "
                             "occupied port falls back to a random high port)")
    parser.add_argument("--dir", metavar="UPLOADS_DIR", default="uploads",
                        help="directory where uploaded files are stored "
                             "(default: ./uploads)")
    parser.add_argument("--insecure", "-i", action="store_true",
                        help="serve on plain /, /upload, ... URLs with no "
                             "token (default is secret mode with a random "
                             "URL path, included in the printed QR code)")
    return parser.parse_args()


ARGS = _parse_args()
UPLOAD_DIR = os.path.abspath(ARGS.dir)


def _find_available_port(start_port):
    """Probe start_port; if 0 or occupied, pick a random high port (32768-60999)."""
    import random
    if start_port:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("0.0.0.0", start_port))
            return start_port
        except OSError:
            pass
        finally:
            sock.close()
    # Port is occupied; try random high ports (IANA dynamic/private range)
    for _ in range(100):
        port = random.randint(32768, 60999)
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("0.0.0.0", port))
            return port
        except OSError:
            sock.close()
            continue
        finally:
            sock.close()
    raise RuntimeError("Could not find an available port after 100 attempts")


PORT = _find_available_port(ARGS.port)
# token_urlsafe() is URL-path-safe and ~128 bits of entropy
SECRET_TOKEN = None if ARGS.insecure else secrets.token_urlsafe(16)
PAGE_PATH = f"/{SECRET_TOKEN}/" if SECRET_TOKEN else "/"
UPLOAD_PATH = f"/{SECRET_TOKEN}/upload" if SECRET_TOKEN else "/upload"
FILES_PATH = f"{PAGE_PATH}files"          # JSON listing of the uploads dir
FILE_DOWNLOAD_PREFIX = f"{PAGE_PATH}fl/"  # download one file by name
FILES_LIST_PREFIX = f"{PAGE_PATH}ls/"   # list directory contents (optional path)


# --- Client activity tracking -------------------------------------------------
# Every request refreshes the client's presence; uploads/downloads/errors are
# logged as events with the client IP. Listing polls are never logged as
# lines, they only keep the client visible in the "online" list.

PRESENCE_TTL = 10.0  # seconds a client stays "online" after its last request


class ActivityLog:
    """Thread-safe record of client presence and notable events."""

    def __init__(self, ttl=PRESENCE_TTL, max_events=500):
        self.ttl = ttl
        self.max_events = max_events
        self._lock = threading.Lock()
        self._last_seen = {}  # ip -> monotonic timestamp
        self._events = []     # (wall-clock timestamp, text)

    def touch(self, ip):
        with self._lock:
            self._last_seen[ip] = time.monotonic()

    def add_event(self, text):
        with self._lock:
            self._events.append((time.time(), text))
            del self._events[:-self.max_events]

    def online(self, now=None):
        """IPs seen within the TTL, oldest-expired first pruned. [now] is a
        monotonic timestamp, injectable for tests."""
        now = time.monotonic() if now is None else now
        with self._lock:
            for ip in [ip for ip, t in self._last_seen.items()
                       if now - t > self.ttl]:
                del self._last_seen[ip]
            return sorted(self._last_seen)

    def events(self):
        with self._lock:
            return list(self._events)


ACTIVITY = ActivityLog()
PLAIN_MODE = True  # False while the curses UI runs (events go to the UI pane)


def classify_request(command, path):
    """'upload' / 'download' for notable requests, None for quiet ones
    (page loads, file-listing polls, redirects, errors are handled apart)."""
    base = path.split("?", 1)[0]
    if command == "POST" and base == UPLOAD_PATH:
        return "upload"
    if command == "GET" and base.startswith(FILE_DOWNLOAD_PREFIX):
        return "download"
    return None


def emit_event(text):
    """Record an event; in plain mode also print it as a log line."""
    ACTIVITY.add_event(text)
    if PLAIN_MODE:
        stamp = datetime.now().strftime("%H:%M:%S")
        sys.stderr.write("[%s] %s\n" % (stamp, text))
        sys.stderr.flush()


# --- Minimal QR code encoder (byte mode, EC level M, versions 1-6) ----------
# Self-contained implementation of the QR spec so the server stays
# zero-dependency. Versions 1-6 hold up to 106 bytes, enough for the URL.

QR_BLOCKS = {  # version -> (ec codewords per block, data codewords per block)
    1: (10, [16]), 2: (16, [28]), 3: (26, [44]),
    4: (18, [32, 32]), 5: (24, [43, 43]), 6: (16, [27, 27, 27, 27]),
}


def _gf_tables():
    """exp/log tables for GF(256), QR polynomial x^8+x^4+x^3+x^2+1."""
    exp, log = [0] * 512, [0] * 256
    x = 1
    for i in range(255):
        exp[i], log[x] = x, i
        x <<= 1
        if x & 0x100:
            x ^= 0x11D
    for i in range(255, 512):
        exp[i] = exp[i - 255]
    return exp, log


_GEXP, _GLOG = _gf_tables()


def _gmul(a, b):
    if a == 0 or b == 0:
        return 0
    return _GEXP[_GLOG[a] + _GLOG[b]]


def _rs_generator(dcount):
    """Generator polynomial prod(x - a^i), coefficients MSB-first."""
    g = [1]
    for i in range(dcount):
        ng = [0] * (len(g) + 1)
        for j, c in enumerate(g):
            ng[j] ^= c
            ng[j + 1] ^= _gmul(c, _GEXP[i])
        g = ng
    return g


def _rs_remainder(block, gen):
    res = list(block) + [0] * (len(gen) - 1)
    for i in range(len(block)):
        coef = res[i]
        if coef:
            for j in range(1, len(gen)):
                res[i + j] ^= _gmul(gen[j], coef)
    return res[len(block):]


def _qr_codewords(data):
    """Byte-mode bit stream for `data`, returns (version, interleaved cw)."""
    for version, (ec_count, blocks) in QR_BLOCKS.items():
        if len(data) <= (sum(blocks) * 8 - 12) // 8:  # 12 = mode+count bits
            break
    else:
        raise ValueError("text too long for QR versions 1-6")
    dcw_count = sum(blocks)

    bits = []

    def put(value, count):
        for i in range(count - 1, -1, -1):
            bits.append((value >> i) & 1)

    put(0b0100, 4)             # byte mode
    put(len(data), 8)          # char count (8 bits for versions 1-9)
    for b in data:
        put(b, 8)
    put(0, min(4, dcw_count * 8 - len(bits)))  # terminator

    data_cw = []
    while bits:
        bits.extend([0] * (8 - len(bits)))  # pad to byte boundary
        data_cw.append(int("".join(map(str, bits[:8])), 2))
        bits = bits[8:]
    pad = 0xEC
    while len(data_cw) < dcw_count:        # standard alternating pad codewords
        data_cw.append(pad)
        pad = 0x11 if pad == 0xEC else 0xEC

    # split into blocks, compute ECC per block, interleave both streams
    gen = _rs_generator(ec_count)
    data_blocks, ec_blocks = [], []
    offset = 0
    for blen in blocks:
        block = data_cw[offset:offset + blen]
        offset += blen
        data_blocks.append(block)
        ec_blocks.append(_rs_remainder(block, gen))

    out = []
    for i in range(max(blocks)):
        for block in data_blocks:
            if i < len(block):
                out.append(block[i])
    for i in range(ec_count):
        for block in ec_blocks:
            out.append(block[i])
    return version, out


def _mask_bit(mask, r, c):
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


def _qr_function_patterns(version):
    """Grid with finder/alignment/timing/layout patterns already drawn."""
    n = 17 + 4 * version
    grid = [[False] * n for _ in range(n)]
    reserved = [[False] * n for _ in range(n)]

    def setm(r, c, dark):
        if not (0 <= r < n and 0 <= c < n):
            return
        grid[r][c] = dark
        reserved[r][c] = True

    for r0, c0 in ((0, 0), (0, n - 7), (n - 7, 0)):  # finders + separators
        for dr in range(-1, 8):
            for dc in range(-1, 8):
                dark = (0 <= dr < 7 and 0 <= dc < 7 and
                        max(abs(dr - 3), abs(dc - 3)) != 2)
                setm(r0 + dr, c0 + dc, dark)

    if version >= 2:  # alignment pattern (v1-6 have exactly one, bottom-right)
        ar = ac = n - 7
        for dr in range(-2, 3):
            for dc in range(-2, 3):
                setm(ar + dr, ac + dc, max(abs(dr), abs(dc)) != 1)

    for i in range(8, n - 8):  # timing patterns
        setm(6, i, i % 2 == 0)
        setm(i, 6, i % 2 == 0)

    setm(n - 8, 8, True)  # dark module

    # format info cells (values drawn per mask after choosing it)
    for i in range(6):
        reserved[i][8] = True
    reserved[7][8] = reserved[8][8] = reserved[8][7] = True
    for i in range(9, 15):
        reserved[8][14 - i] = True
    for i in range(8):
        reserved[8][n - 1 - i] = True
    for i in range(8, 15):
        reserved[n - 15 + i][8] = True
    return grid, reserved


def _place_data(grid, reserved, codewords):
    n = len(grid)
    bitseq = [(cw >> (7 - b)) & 1 for cw in codewords for b in range(8)]
    i = 0
    right = n - 1
    while right >= 1:  # zigzag through column pairs, skipping the timing col
        upward = ((right + 1) & 2) == 0
        for vert in range(n):
            r = (n - 1 - vert) if upward else vert
            for dc in range(2):
                c = right - dc
                if not reserved[r][c] and i < len(bitseq):
                    grid[r][c] = bool(bitseq[i])
                    i += 1
        right = 5 if right == 8 else right - 2


def _draw_format(grid, mask):
    """Format info: EC level M (00) + mask, BCH-coded (15 bits), two copies."""
    n = len(grid)
    v = mask  # 00 << 3 | mask: EC level M is indicator 00
    rem = v
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    bits = ((v << 10) | rem) ^ 0x5412

    def bit(i):
        return bool((bits >> i) & 1)

    for i in range(6):
        grid[i][8] = bit(i)
    for i in range(8):
        grid[8][n - 1 - i] = bit(i)
    grid[7][8] = bit(6)
    grid[8][8] = bit(7)
    grid[8][7] = bit(8)
    for i in range(9, 15):
        grid[8][14 - i] = bit(i)
    for i in range(8, 15):
        grid[n - 15 + i][8] = bit(i)
    grid[n - 8][8] = True  # always-dark module


def _run_penalty(line):
    score, run = 0, 1
    for i in range(1, len(line)):
        if line[i] == line[i - 1]:
            run += 1
        else:
            if run >= 5:
                score += run - 2  # 3 + (run - 5)
            run = 1
    if run >= 5:
        score += run - 2
    return score


_FINDER_LIKE = ([0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1],
                [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0])


def _penalty(grid, n):
    score = 0
    cols_ = [list(col) for col in zip(*grid)]
    for line in grid + cols_:
        score += _run_penalty(line)
        ints = [int(v) for v in line]
        for i in range(len(line) - 10):
            window = ints[i:i + 11]
            if window in _FINDER_LIKE:
                score += 40
    for r in range(n - 1):
        for c in range(n - 1):
            if grid[r][c] == grid[r][c + 1] == grid[r + 1][c] == grid[r + 1][c + 1]:
                score += 3
    dark = sum(sum(1 for v in row if v) for row in grid)
    pct = dark * 100.0 / (n * n)
    score += int(abs(pct - 50) // 5) * 10
    return score


def qr_matrix(text: str):
    """Encode text into a QR code; returns rows of bools (True = dark)."""
    version, codewords = _qr_codewords(text.encode("utf-8"))
    grid, reserved = _qr_function_patterns(version)
    _place_data(grid, reserved, codewords)

    best, best_score = None, None
    for mask in range(8):
        trial = [row[:] for row in grid]
        n = len(trial)
        for r in range(n):
            for c in range(n):
                if not reserved[r][c] and _mask_bit(mask, r, c):
                    trial[r][c] = not trial[r][c]
        _draw_format(trial, mask)
        score = _penalty(trial, n)
        if best is None or score < best_score:
            best, best_score = trial, score
    return best


def qr_terminal(matrix, quiet=4):
    """ANSI half-block rendering with no explicit colors at all.

    Modules are drawn in the terminal's default foreground on its default
    background, which always contrast: light terminal → black-on-white look,
    dark terminal → light-on-dark (an inverted QR, which phone cameras
    decode fine). Setting any explicit fg/bg breaks in some colorschemes
    (e.g. herdr renders palette white as black), so we set nothing.
    """
    n = len(matrix)
    w = n + 2 * quiet
    prefix = ""

    def dark(r, c):
        return 0 <= r - quiet < n and 0 <= c - quiet < n and matrix[r - quiet][c - quiet]

    lines = []
    for r in range(0, w, 2):
        chunks = []
        for c in range(w):
            top, bottom = dark(r, c), dark(r + 1, c)
            chunks.append("█" if top and bottom else "▀" if top
                          else "▄" if bottom else " ")
        lines.append("".join(chunks))
    return "\n".join(lines)


PAGE = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LANdir</title>
<style>
  :root { color-scheme: dark; }
  body { font-family: system-ui, sans-serif; background:#111; color:#eee;
         margin:0; display:flex; flex-direction:column; align-items:center;
         min-height:100vh; }
  h1 { font-size:1.3rem; margin:1.2rem 0 .5rem; }
  #drop { border:2px dashed #555; border-radius:12px; padding:3rem 2rem;
          text-align:center; cursor:pointer; width:min(90vw, 500px); }
  #drop.hover { border-color:#4caf50; background:#1b2b1b; }
  #files { display:none; }
  #list { margin:1rem; padding:0; list-style:none; width:min(90vw,500px); }
  #list li { display:flex; justify-content:space-between; gap:1rem;
             padding:.4rem .6rem; border-radius:6px; background:#222;
             margin-bottom:.4rem; font-size:.9rem; overflow-wrap:anywhere; }
  .ok { color:#7fd77f; } .err { color:#e57373; }
  #bar { width:min(90vw,500px); height:6px; background:#333; border-radius:3px;
         margin-top:1rem; display:none; }
  #bar > div { height:100%; width:0; background:#4caf50; border-radius:3px; }
  h2 { font-size:1rem; margin:1.2rem 0 .4rem; color:#ccc; }
  #saved { margin:0; padding:0; list-style:none; width:min(90vw,500px); }
  #saved li { display:flex; justify-content:space-between; gap:1rem;
              padding:.4rem .6rem; border-radius:6px; background:#222;
              margin-bottom:.4rem; font-size:.9rem; overflow-wrap:anywhere; }
  #saved a { color:#7ec2ff; text-decoration:none; }
  #saved .size { color:#888; white-space:nowrap; }
  #saved .date { color:#888; white-space:nowrap; font-size:.8rem; }
  #saved .meta { display:flex; gap:1rem; align-items:center; }
  #saved .empty { color:#888; justify-content:center; }
  #saved .dir { color:#ffcc00; cursor:pointer; }
  #saved .dir:hover { background:#333; }
  p.hint { color:#888; font-size:.85rem; }
  #breadcrumb { margin:0; padding:0; list-style:none; width:min(90vw,500px); 
                display:flex; flex-wrap:wrap; gap:.5rem; font-size:.85rem; color:#888; }
  #breadcrumb li { display:inline-flex; }
  #breadcrumb a { color:#7ec2ff; text-decoration:none; }
  #breadcrumb a:hover { text-decoration:underline; }
  #toggleDates { background:#333; color:#ccc; border:1px solid #555; border-radius:4px;
                 padding:.2rem .5rem; font-size:.8rem; cursor:pointer; margin-bottom:.5rem; }
  #toggleDates:hover { background:#444; }
  #sortSelect { background:#333; color:#ccc; border:1px solid #555; border-radius:4px;
                 padding:.2rem .3rem; font-size:.8rem; cursor:pointer; margin-bottom:.5rem; }
  .button-group { display:flex; gap:.5rem; align-items:center; }
  body:not(.show-dates) #saved .date { display: none; }
</style>
</head><body>
<h1 id="page-title">Drop files here</h1>
<p class="hint">or tap the box to pick files</p>
<div id="drop">&#128193; Choose or drop files</div>
<input type="file" id="files" multiple>
<ul id="list"></ul>
<div id="bar"><div></div></div>
<ul id="breadcrumb"></ul>
<h2>Saved files</h2>
<p class="hint">tap a file to download it, tap a folder to enter it</p>
<div class="button-group">
<button id="toggleDates" onclick="toggleDates()">Show Dates</button>
<select id="sortSelect" onchange="setSort(this.value)">
  <option value="newest">Sort: Newest</option>
  <option value="name">Sort: Name</option>
</select>
</div>
<ul id="saved"></ul>
<script>
const drop = document.getElementById('drop');
const input = document.getElementById('files');
const list = document.getElementById('list');
const bar = document.getElementById('bar');
const fill = bar.firstElementChild;
const saved = document.getElementById('saved');
const breadcrumb = document.getElementById('breadcrumb');
const pageTitle = document.getElementById('page-title');
let sortByNewest = true;
let refreshInterval;

// Detect mobile/touch devices
function isMobile() {
  return window.matchMedia('(max-width: 600px)').matches || 
         ('ontouchstart' in window) || 
         (navigator.userAgent.match(/Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i));
}

// Update text for mobile devices
if (isMobile()) {
  pageTitle.textContent = 'Upload files here';
  drop.textContent = '📁 Choose files';
}

let currentPath = ''; // Current directory path (relative to uploads root)

drop.onclick = () => input.click();
drop.ondragover = e => { e.preventDefault(); drop.classList.add('hover'); };
drop.ondragleave = () => drop.classList.remove('hover');
drop.ondrop = e => {
  e.preventDefault();
  drop.classList.remove('hover');
  upload([...e.dataTransfer.files]);
};
input.onchange = () => { upload([...input.files]); input.value = ''; };

function upload(files) {
  if (!files.length) return;
  bar.style.display = 'block';
  let done = 0;
  const next = () => {
    if (done >= files.length) { bar.style.display = 'none'; refresh(); return; }
    const f = files[done++];
    const li = document.createElement('li');
    li.innerHTML = `<span></span><span class="ok">&#8230;</span>`;
    li.firstElementChild.textContent = f.name;
    list.prepend(li);
    const fd = new FormData();
    // relative path resolves under the (possibly secret) page URL
    fd.append('file', f);
    fetch('upload', { method: 'POST', body: fd })
      .then(r => { li.lastElementChild.textContent = r.ok ? 'OK' : 'FAIL';
                   li.lastElementChild.className = r.ok ? 'ok' : 'err'; })
      .catch(() => { li.lastElementChild.textContent = 'ERR';
                     li.lastElementChild.className = 'err'; })
      .finally(() => { fill.style.width = (100*done/files.length)+'%'; next(); });
  };
  next();
}

function fmtSize(n) {
  if (n < 1024) return n + ' B';
  const u = ['KB', 'MB', 'GB'];
  let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
  return n.toFixed(n >= 100 ? 0 : 1) + ' ' + u[i];
}

function fmtDate(timestamp) {
  const d = new Date(timestamp * 1000);
  return d.toLocaleDateString() + ' ' + d.toLocaleTimeString();
}

function toggleDates() {
  const body = document.body;
  const button = document.getElementById('toggleDates');
  
  if (body.classList.contains('show-dates')) {
    body.classList.remove('show-dates');
    button.textContent = 'Show Dates';
  } else {
    body.classList.add('show-dates');
    button.textContent = 'Hide Dates';
  }
}

function setSort(mode) {
  sortByNewest = (mode === 'newest');
  refresh();
}

function renderBreadcrumb() {
  breadcrumb.textContent = '';
  const parts = currentPath.split('/').filter(p => p);
  
  // Always show root link
  const rootLi = document.createElement('li');
  const rootA = document.createElement('a');
  rootA.href = '#';
  rootA.textContent = 'root';
  rootA.onclick = (e) => { e.preventDefault(); currentPath = ''; refresh(); };
  rootLi.appendChild(rootA);
  breadcrumb.appendChild(rootLi);
  
  // Show path parts
  let pathSoFar = '';
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    pathSoFar += (pathSoFar ? '/' : '') + part;
    
    const li = document.createElement('li');
    li.textContent = '/';
    breadcrumb.appendChild(li);
    
    const partLi = document.createElement('li');
    const partA = document.createElement('a');
    partA.href = '#';
    partA.textContent = part;
    partA.onclick = (e) => { 
      e.preventDefault(); 
      currentPath = pathSoFar.substring(0, pathSoFar.indexOf('/' + part) + part.length + 1);
      // Actually, let's rebuild it properly
      const newParts = parts.slice(0, i + 1);
      currentPath = newParts.join('/');
      refresh(); 
    };
    partLi.appendChild(partA);
    breadcrumb.appendChild(partLi);
  }
}

function refresh() {
  renderBreadcrumb();
  
  let url = 'files'; // fetch('files' for root directory listing
  if (currentPath) {
    url = 'ls/' + encodeURIComponent(currentPath);
  }
  
  fetch(url)
    .then(r => r.ok ? r.json() : [])
    .then(items => {
      // Sort items based on current sort mode
      if (sortByNewest) {
        items.sort((a, b) => b.mtime - a.mtime);
      } else {
        items.sort((a, b) => a.name.localeCompare(b.name));
      }
      
      saved.textContent = '';
      if (!items.length) {
        const li = document.createElement('li');
        li.className = 'empty';
        li.textContent = 'nothing here yet';
        saved.appendChild(li);
        return;
      }
      for (const it of items) {
        const li = document.createElement('li');
        
        if (it.is_dir) {
          const span = document.createElement('span');
          span.className = 'dir';
          span.textContent = it.name + '/';
          span.onclick = () => {
            currentPath = currentPath ? currentPath + '/' + it.name : it.name;
            refresh();
          };
          li.appendChild(span);
          const meta = document.createElement('span');
          meta.className = 'meta';
          const date = document.createElement('span');
          date.className = 'date';
          date.textContent = fmtDate(it.mtime);
          meta.appendChild(date);
          li.appendChild(meta);
          saved.appendChild(li);
        } else {
          const a = document.createElement('a');
          const filePath = currentPath ? currentPath + '/' + it.name : it.name;
          a.href = 'fl/' + encodeURIComponent(filePath);
          a.download = it.name;   // force download, not navigation
          a.textContent = it.name;
          li.appendChild(a);
          const meta = document.createElement('span');
          meta.className = 'meta';
          const size = document.createElement('span');
          size.className = 'size';
          size.textContent = fmtSize(it.size);
          const date = document.createElement('span');
          date.className = 'date';
          date.textContent = fmtDate(it.mtime);
          meta.appendChild(size);
          meta.appendChild(date);
          li.appendChild(meta);
          saved.appendChild(li);
        }
      }
    })
    .catch(() => {});
}

// Auto-refresh every 5 seconds
refreshInterval = setInterval(refresh, 5000);
// Initial refresh
refresh();
</script>
</body></html>
"""


def safe_name(name: str) -> str:
    # Decode, reduce to a bare filename: kills ../, ..\\, absolute paths
    name = unquote(name).replace("\\", "/")
    name = os.path.basename(name)
    # Strip control chars and NUL bytes (truncation / injection tricks)
    name = re.sub(r"[\x00-\x1f\x7f]", "", name).strip()
    # Reject hidden and dot-only names (".", "..", ".bashrc", "...")
    name = name.lstrip(".") or ""
    # Only keep characters known safe; everything else becomes "_"
    name = re.sub(r"[^A-Za-z0-9._ ()\[\]-]", "_", name)
    if not name or not name.strip("."):
        name = "file_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    # Defense in depth: final resolved path MUST stay inside UPLOAD_DIR
    path = os.path.realpath(os.path.join(UPLOAD_DIR, name))
    if os.path.commonpath([path, os.path.realpath(UPLOAD_DIR)]) != os.path.realpath(UPLOAD_DIR):
        raise ValueError("path escapes upload directory")
    # Avoid overwriting: add a timestamp if the file exists
    if os.path.exists(path):
        stem, ext = os.path.splitext(name)
        path = os.path.join(UPLOAD_DIR,
                            f"{stem}_{datetime.now():%Y%m%d_%H%M%S}{ext}")
    return os.path.basename(path)


def _inside_uploads(path: str) -> bool:
    real = os.path.realpath(UPLOAD_DIR)
    return os.path.commonpath([os.path.realpath(path), real]) == real


def _safe_path_component(name: str) -> str:
    """Sanitize a single path component (filename or directory name).
    
    Returns sanitized name or empty string if invalid.
    """
    name = unquote(name).replace("\\", "/")
    name = os.path.basename(name)
    name = re.sub(r"[\x00-\x1f\x7f]", "", name).strip()
    if not name or name.startswith("."):
        return ""
    if not re.fullmatch(r"[A-Za-z0-9._ ()\[\]-]+", name):
        return ""
    return name


def download_lookup(raw: str):
    """Resolve a client-requested file name to a path inside UPLOAD_DIR.

    Returns the absolute path, or None if the name is rejected. Reuses the
    same whitelist as safe_name(), so only files uploads could have created
    are reachable; hidden names and traversal fragments never match.
    
    Supports paths with directories (e.g., 'folder/file.txt').
    """
    # Unquote first to handle URL-encoded slashes (%2F)
    raw = unquote(raw)
    # Split the path into components
    path_parts = raw.split("/")
    
    # Sanitize each component
    sanitized_parts = []
    for part in path_parts:
        sanitized = _safe_path_component(part)
        if not sanitized:
            return None
        sanitized_parts.append(sanitized)
    
    if not sanitized_parts:
        return None
    
    # Build the full path
    path = os.path.join(UPLOAD_DIR, *sanitized_parts)
    
    # Security check: must be inside UPLOAD_DIR
    if not _inside_uploads(path):
        return None
    
    # Must be a file (not a directory)
    if not os.path.isfile(path):
        return None
    
    return path


class Handler(BaseHTTPRequestHandler):
    def send_page(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _client_ip(self):
        return self.client_address[0]

    def do_GET(self):
        ACTIVITY.touch(self._client_ip())
        base = self.path.split("?", 1)[0]
        if SECRET_TOKEN and base == "/" + SECRET_TOKEN:
            # redirect to add the trailing slash so relative URLs resolve
            self.send_response(302)
            self.send_header("Location", PAGE_PATH)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if base == PAGE_PATH or (not SECRET_TOKEN and base == "/index.html"):
            self.send_page(PAGE.encode("utf-8"))
            return
        if base == FILES_PATH:  # listing as JSON; the page renders it
            entries = []
            try:
                names = os.listdir(UPLOAD_DIR)
            except OSError:
                names = []
            for name in names:
                path = os.path.join(UPLOAD_DIR, name)
                try:
                    if not _inside_uploads(path):
                        continue
                    if os.path.isdir(path):
                        entries.append((os.path.getmtime(path), name, 0, True))
                    elif os.path.isfile(path):
                        entries.append((os.path.getmtime(path), name,
                                        os.path.getsize(path), False))
                except OSError:
                    continue
            entries.sort(reverse=True)
            body = json.dumps([{"name": n, "size": s, "is_dir": is_dir, 
                               "mtime": mtime} 
                              for mtime, n, s, is_dir in entries])
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))
            return
        
        if base.startswith(FILES_LIST_PREFIX):
            # List contents of a specific directory
            rel_path = base[len(FILES_LIST_PREFIX):]
            # Unquote first to handle URL-encoded slashes (%2F)
            rel_path = unquote(rel_path)
            # Sanitize and resolve the directory path
            path_parts = rel_path.split("/")
            sanitized_parts = []
            for part in path_parts:
                sanitized = _safe_path_component(part)
                if not sanitized:
                    self.send_error(404)
                    return
                sanitized_parts.append(sanitized)
            
            if not sanitized_parts:
                # List root upload directory
                dir_path = UPLOAD_DIR
            else:
                dir_path = os.path.join(UPLOAD_DIR, *sanitized_parts)
            
            # Security check
            if not _inside_uploads(dir_path) or not os.path.isdir(dir_path):
                self.send_error(404)
                return
            
            entries = []
            try:
                names = os.listdir(dir_path)
            except OSError:
                names = []
            
            for name in names:
                path = os.path.join(dir_path, name)
                try:
                    if not _inside_uploads(path):
                        continue
                    if os.path.isdir(path):
                        entries.append((os.path.getmtime(path), name, 0, True))
                    elif os.path.isfile(path):
                        entries.append((os.path.getmtime(path), name,
                                        os.path.getsize(path), False))
                except OSError:
                    continue
            
            entries.sort(reverse=True)
            body = json.dumps([{"name": n, "size": s, "is_dir": is_dir, 
                               "mtime": mtime} 
                              for mtime, n, s, is_dir in entries])
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))
            return
        if classify_request("GET", self.path) == "download":
            path = download_lookup(base[len(FILE_DOWNLOAD_PREFIX):])
            if path is None:
                self.send_error(404)
                return
            size = os.path.getsize(path)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="%s"'
                             % os.path.basename(path))
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(path, "rb") as fh:
                shutil.copyfileobj(fh, self.wfile)
            emit_event(f"{self._client_ip()} downloaded "
                       f"{os.path.basename(path)} ({size} B)")
            return
        self.send_error(404)

    def do_POST(self):
        ACTIVITY.touch(self._client_ip())
        if classify_request("POST", self.path) != "upload":
            self.send_error(404)
            return

        # Parse multipart/form-data using the CGI boundary
        ctype = self.headers.get("Content-Type", "")
        m = re.search(r'boundary="?([^";]+)"?', ctype)
        if not m:
            self.send_error(400, "Bad request")
            return
        boundary = m.group(1).encode()

        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            length = -1
        if length < 0:  # negative or non-numeric: reject, don't crash
            self.send_error(400, "Bad request")
            return
        data = self.rfile.read(length)

        # Split parts
        parts = data.split(b"--" + boundary)
        saved = 0
        for part in parts:
            if b"filename=" not in part:
                continue
            try:
                header_blob, _, filedata = part.partition(b"\r\n\r\n")
                filedata = filedata.rsplit(b"\r\n", 1)[0]
                nm = re.search(rb'filename="([^"]*)"', header_blob).group(1)
                name = safe_name(nm.decode("utf-8", "replace"))
                with open(os.path.join(UPLOAD_DIR, name), "wb") as fh:
                    fh.write(filedata)
                emit_event(f"{self._client_ip()} uploaded "
                           f"{name} ({len(filedata)} B)")
                saved += 1
            except Exception:
                continue

        if saved:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK")
        else:
            self.send_error(400, "No file saved")

    def log_message(self, fmt, *args):
        # Per-request lines are suppressed: listing polls are pure noise.
        # Uploads/downloads are emitted explicitly with the client IP.
        pass

    def send_error(self, code, message=None, explain=None):
        emit_event(f"{self._client_ip()} {self.command} "
                   f"{self.path.split('?', 1)[0]} -> {code}")
        super().send_error(code, message, explain)


def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def _curses_available():
    try:
        import curses  # noqa: F401
        return True
    except ImportError:
        return False


def _safe_add(win, y, x, text, attr=0):
    """addnstr that never raises on the bottom-right cell / tiny terminals."""
    import curses
    try:
        win.addnstr(y, x, text, max(0, win.getmaxyx()[1] - x - 1), attr)
    except curses.error:
        pass


def _ui_loop(stdscr, url):
    """Full-screen UI: QR + online clients on top, scrollable event log below.
    'q' toggles the QR panel, arrows/PgUp/PgDn scroll the log, Ctrl+C quits."""
    import curses
    curs_set_ok = True
    try:
        curses.curs_set(0)
    except curses.error:
        curs_set_ok = False
    stdscr.nodelay(True)
    show_qr = True
    scroll = 0  # how many lines the log is scrolled up from the bottom
    qr_lines = qr_terminal(qr_matrix(url)).splitlines()
    # qr_terminal emits no color codes; draw the QR with the terminal's
    # default colors (default fg always contrasts with default bg, so the
    # code is camera-readable in light and dark terminals alike).
    qr_attr = 0
    while True:
        key = stdscr.getch()
        if key == ord("q"):
            show_qr = not show_qr
        elif key == curses.KEY_UP:
            scroll += 1
        elif key == curses.KEY_DOWN:
            scroll = max(0, scroll - 1)
        elif key == curses.KEY_PPAGE:
            scroll += 10
        elif key == curses.KEY_NPAGE:
            scroll = max(0, scroll - 10)

        h, w = stdscr.getmaxyx()
        top_h = (len(qr_lines) + 3) if show_qr else 3
        top_h = min(top_h, max(3, h - 3))
        log_h = h - top_h
        top = curses.newwin(top_h, w, 0, 0)
        log = curses.newwin(log_h, w, top_h, 0)

        top.erase()
        _safe_add(top, 0, 0, f" LANdir  {url}   (q: QR on/off, Ctrl+C: stop)")
        line = 1
        if show_qr:
            for ql in qr_lines:
                if line >= top_h - 1:
                    break
                _safe_add(top, line, 0, ql, qr_attr)
                line += 1
        online = ACTIVITY.online()
        _safe_add(top, top_h - 1, 0,
                  " Online: " + (", ".join(online) if online else "-"))
        top.noutrefresh()

        log.erase()
        visible = ["%s  %s" % (datetime.fromtimestamp(t).strftime("%H:%M:%S"),
                               txt) for t, txt in ACTIVITY.events()]
        max_scroll = max(0, len(visible) - log_h)
        scroll = min(scroll, max_scroll)
        end = len(visible) - scroll
        start = max(0, end - log_h)
        for i, ln in enumerate(visible[start:end]):
            _safe_add(log, i, 0, ln)
        log.noutrefresh()
        curses.doupdate()
        time.sleep(0.25)


def _run_curses_ui(url):
    import curses
    curses.wrapper(lambda stdscr: _ui_loop(stdscr, url))


def main():
    global PLAIN_MODE
    os.makedirs(UPLOAD_DIR, exist_ok=True)
    url = f"http://{lan_ip()}:{PORT}{PAGE_PATH}"
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    if sys.stdout.isatty() and _curses_available():
        # Interactive terminal: full-screen UI, server on a background thread.
        PLAIN_MODE = False
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            _run_curses_ui(url)
        except KeyboardInterrupt:
            pass
        finally:
            server.shutdown()
            server.server_close()
        print("Stopped.")
    else:
        # Piped output / no curses (container, Windows): plain filtered logs.
        print(f"Uploads directory: {UPLOAD_DIR}", flush=True)
        print(f"Open {url}  (Ctrl+C to stop)", flush=True)
        try:
            print(qr_terminal(qr_matrix(url)), flush=True)
        except ValueError as exc:
            print(f"(no QR code: {exc})", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")


if __name__ == "__main__":
    main()
