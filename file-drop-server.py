#!/usr/bin/env python3
"""File Drop Server - a simple LAN file upload server.

Usage:
    python3 file_drop_server.py [port] [uploads_dir]

Defaults: port 8000, uploads in ./uploads next to the script.
Then open http://<your-linux-box-ip>:8000 from any device on the same
network (e.g. an Android phone) and drag files in.
"""

import html
import os
import re
import sys
import socket
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
UPLOAD_DIR = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else "uploads")

PAGE = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>File Drop</title>
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
  p.hint { color:#888; font-size:.85rem; }
</style>
</head><body>
<h1>Drop files here</h1>
<p class="hint">or tap the box to pick files</p>
<div id="drop">&#128193; Choose or drop files</div>
<input type="file" id="files" multiple>
<ul id="list"></ul>
<div id="bar"><div></div></div>
<script>
const drop = document.getElementById('drop');
const input = document.getElementById('files');
const list = document.getElementById('list');
const bar = document.getElementById('bar');
const fill = bar.firstElementChild;

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
    if (done >= files.length) { bar.style.display = 'none'; return; }
    const f = files[done++];
    const li = document.createElement('li');
    li.innerHTML = `<span></span><span class="ok">&#8230;</span>`;
    li.firstElementChild.textContent = f.name;
    list.prepend(li);
    const fd = new FormData();
    fd.append('file', f);
    fetch('/upload', { method: 'POST', body: fd })
      .then(r => { li.lastElementChild.textContent = r.ok ? 'OK' : 'FAIL';
                   li.lastElementChild.className = r.ok ? 'ok' : 'err'; })
      .catch(() => { li.lastElementChild.textContent = 'ERR';
                     li.lastElementChild.className = 'err'; })
      .finally(() => { fill.style.width = (100*done/files.length)+'%'; next(); });
  };
  next();
}
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
    if not name or name.strip("."):
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


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            body = PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/upload":
            self.send_error(404)
            return

        # Parse multipart/form-data using the CGI boundary
        ctype = self.headers.get("Content-Type", "")
        m = re.search(r'boundary="?([^";]+)"?', ctype)
        if not m:
            self.send_error(400, "Bad request")
            return
        boundary = m.group(1).encode()

        length = int(self.headers.get("Content-Length", 0))
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
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))


def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main():
    os.makedirs(UPLOAD_DIR, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Uploads directory: {UPLOAD_DIR}")
    print(f"Serving on http://{lan_ip()}:{PORT}  (Ctrl+C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")

if __name__ == "__main__":
    main()