//! Static HTML page served at the page route. Same constant as landir.py.

pub const PAGE: &str = r##"
<!doctype html>
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
"##;
