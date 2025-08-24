#!/bin/sh
# eWOL — enhanced Wake-On-LAN UI for OpenWrt (vanilla uhttpd) or GL.iNet devices
#
# Features:
# - Dark/light UI (switch, remembers preference, default dark)
# - Font size zoom +/- buttons (remembers preference)
# - Simple Lua CGI API using LuCI libs
# - Self-contained in /www/ewol ; single symlink into /www/cgi-bin
#
# Optional: 
# - Set ALLOW_PUBLIC=0 to restrict to LAN only (basic check).
# - You can tweak LAN_IF and PING_TIMEOUT if needed.
# (GL.iNet devices usually have br-lan as default, but please double-check yours first.)

set -eu

EWOL_DIR="/www/ewol"
CGI_LINK="/www/cgi-bin/ewol-ctl"
LAN_IF="br-lan"
PING_TIMEOUT=1
ALLOW_PUBLIC=0

mkdir -p "$EWOL_DIR"

# ---------------
#  index.html
# ---------------
cat > "$EWOL_DIR/index.html" << 'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate" />
  <link rel="icon" type="image/png" href="/luci-static/bootstrap/favicon.png"/>
  <link rel="stylesheet" href="/ewol/style.css"/>
  <title>eWOL: enhanced Wake-On-LAN</title>
</head>
<body>
  <header>
    <div class="wrap row">
      <h1>eWOL - <span class="muted">enhanced Wake-On-LAN</span></h1>
      <div class="row" style="gap:8px">
        <span id="status" class="pill">Idle</span>
        <label class="toggle"><input id="themeToggle" type="checkbox" checked/> Dark mode</label>
        <button id="fontPlus" class="font-resize-btn" title="Increase font size">A+</button>
        <button id="fontMinus" class="font-resize-btn" title="Decrease font size">A-</button>
        <button id="refresh">Refresh</button>
      </div>
    </div>
  </header>

  <main class="wrap">
    <div id="err" class="card" style="display:none"></div>

    <div class="card">
      <table id="grid">
        <thead>
          <tr>
            <th class="sortable" data-key="name">Hostname</th>
            <th class="sortable" data-key="mac">MAC</th>
            <th class="sortable" data-key="ip">IP</th>
            <th>Status</th>
            <th class="center">Action</th>
          </tr>
        </thead>
        <tbody></tbody>
      </table>
    </div>

    <div class="footer">
    Served from <code>/www/ewol</code><br/>
    API: <code>/cgi-bin/ewol-ctl</code><br/>
    <a href="https://github.com/domomg/ewol" target="_blank" rel="noopener">GitHub: domomg/ewol</a>
    </div>
  </main>

  <script src="/ewol/script.js" defer></script>
</body>
</html>
EOF

# ---------------------------
#  style.css
# ---------------------------
cat > "$EWOL_DIR/style.css" << 'EOF'
:root {
  --bg: #0b0c10; --fg: #e5e7eb; --muted:#9ca3af; --card:#111827; --border:#1f2937; --accent:#60a5fa; --ok:#22c55e; --err:#ef4444;
  --base-font-size: 14px;
}
@media (prefers-color-scheme: light){
  :root { --bg:#f7fafc; --fg:#111827; --muted:#6b7280; --card:#ffffff; --border:#e5e7eb; --accent:#2563eb; --ok:#16a34a; --err:#dc2626; }
}
[data-theme="light"]:root { --bg:#f7fafc; --fg:#111827; --muted:#6b7280; --card:#ffffff; --border:#e5e7eb; --accent:#2563eb; --ok:#16a34a; --err:#dc2626; }
[data-theme="dark"]:root { --bg:#0b0c10; --fg:#e5e7eb; --muted:#9ca3af; --card:#111827; --border:#1f2937; --accent:#60a5fa; --ok:#22c55e; --err:#ef4444; }

* { box-sizing: border-box }
body { 
  margin:0; 
  font-size: var(--base-font-size, 14px);
  line-height: 1.45;
  font-family: system-ui, -apple-system, Segoe UI, Roboto, Ubuntu, Cantarell, Noto Sans, Helvetica, Arial, sans-serif;
  background:var(--bg); color:var(--fg); 
}
header { position: sticky; top:0; z-index:10; backdrop-filter: blur(6px); background: color-mix(in oklab, var(--bg) 88%, transparent); border-bottom:1px solid var(--border); }
.wrap { max-width: 980px; margin: 0 auto; padding: 16px; }
h1 { margin:0; font-size: 20px; }
.muted { color: var(--muted); }
.row { display:flex; gap:12px; align-items:center; justify-content:space-between; flex-wrap:wrap; }
button, .btn { cursor:pointer; border:1px solid var(--border); background:var(--card); color:var(--fg); padding:6px 10px; border-radius:10px; }
button:hover { border-color: var(--accent); }
.pill { font-size:12px; padding:3px 8px; border-radius:999px; border:1px solid var(--border); }
.ok { color: var(--ok); }
.err { color: var(--err); }

main { padding:16px; }
.card { background:var(--card); border:1px solid var(--border); border-radius:14px; padding: 12px; }

table { width:100%; border-collapse: collapse; }
th, td { padding: 10px; border-bottom:1px solid var(--border); text-align:left; }
th { font-weight:600; user-select:none; }
th.sortable { cursor:pointer; }
tr:hover td { background: color-mix(in oklab, var(--card) 92%, var(--accent) 8% ); }
.actions { display:flex; gap:8px; }
.center { text-align:center; }

.footer { color: var(--muted); font-size:12px; padding:12px 0 20px }
.toggle { display:inline-flex; align-items:center; gap:8px }
img.status-icon { height:18px;vertical-align:middle;margin-right:3px; }
.font-resize-btn { font-size:16px; min-width:32px; }
EOF

# ---------------
#  script.js
# ---------------
cat > "$EWOL_DIR/script.js" << 'EOF'
'use strict';
(function(){
  const api = '/cgi-bin/ewol-ctl';
  const $ = (sel, el=document)=>el.querySelector(sel);

  // Status icons for eWOL, GL.iNet default LuCI resources
    const ICONS = {
    Online: '/luci-static/resources/icons/port_up.png',
    Offline: '/luci-static/resources/icons/port_down.png',
    Loading: '/luci-static/resources/icons/loading.gif',
    Sent: '/luci-static/resources/icons/port_up.png',
    Error: '/luci-static/resources/icons/signal-none.png'
  };

  const state = { rows: [], sortKey:'name', sortDir:1, statusMap: {} };

  // --- FONT SIZE LOGIC ---
  const FONT_MIN = 10, FONT_MAX = 22, FONT_STEP = 2, FONT_DEFAULT = 14;
  function setFontSize(size) {
    size = Math.max(FONT_MIN, Math.min(FONT_MAX, size));
    document.documentElement.style.setProperty('--base-font-size', size + 'px');
    try { localStorage.setItem('ewol-font-size', size); } catch(e){}
  }
  function loadFontSize() {
    let size = FONT_DEFAULT;
    try {
      size = parseInt(localStorage.getItem('ewol-font-size')) || FONT_DEFAULT;
    } catch(e){}
    setFontSize(size);
  }
  function handleFontPlus() {
    let size = parseInt(getComputedStyle(document.documentElement).getPropertyValue('--base-font-size')) || FONT_DEFAULT;
    setFontSize(size + FONT_STEP);
  }
  function handleFontMinus() {
    let size = parseInt(getComputedStyle(document.documentElement).getPropertyValue('--base-font-size')) || FONT_DEFAULT;
    setFontSize(size - FONT_STEP);
  }

  function setStatus(text, cls){
    const pill = $('#status');
    pill.textContent = text;
    pill.className = 'pill ' + (cls||'');
  }

  function showError(msg){
    const box = $('#err');
    box.style.display = 'block';
    box.textContent = msg;
    setStatus('Error', 'err');
  }

  function sortRows(){
    const k = state.sortKey, d = state.sortDir;
    state.rows.sort((a,b)=>{
      const x = a[k] ?? '', y = b[k] ?? '';
      return (String(x).localeCompare(String(y), undefined, {numeric:true})) * d;
    });
  }

  function render(){
    sortRows();
    const tb = $('#grid tbody');
    tb.innerHTML = '';
    for(const r of state.rows){
      const statusText = state.statusMap[r.name] || '';
      let statusIcon = '';
      let label = '';
      let statusClass = '';
      if(statusText === 'Online') {
        statusIcon = ICONS.Online; label = 'Online'; statusClass = 'ok';
      } else if(statusText === 'Offline') {
        statusIcon = ICONS.Offline; label = 'Offline'; statusClass = 'err';
      } else if(statusText === 'Loading') {
        statusIcon = ICONS.Loading; label = ''; statusClass = '';
      } else if(statusText === 'Error') {
        statusIcon = ICONS.Error; label = 'Error'; statusClass = 'err';
      } else if(statusText === 'Sent') {
        statusIcon = ICONS.Sent; label = 'Sent!'; statusClass = 'ok';
      }
      // For Sent, show ASCII green check and "Sent!", we don't have any usable resource on GL.iNet devices
      const iconHtml = (label === 'Sent!') ? '<span style="color:var(--ok);font-weight:bold;">✔</span> ' : (statusIcon ? `<img class="status-icon" src="${statusIcon}" alt="">` : '');
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${r.name||''}</td>
        <td><code>${r.mac||''}</code></td>
        <td><code>${r.ip||''}</code></td>
        <td><span id="status-${r.name}" class="${statusClass}">${iconHtml}${label}</span></td>
        <td class="center actions">
          <button data-act="wake" data-host="${r.name}">Wake</button>
          <button data-act="ping" data-host="${r.name}">Check</button>
        </td>`;
      tb.appendChild(tr);
    }
  }

  async function call(cmd, params={}){
    const url = new URL(location.origin + api);
    url.searchParams.set('cmd', cmd);
    Object.entries(params).forEach(([k,v])=>url.searchParams.set(k,v));
    const res = await fetch(url, { cache:'no-store' });
    if(!res.ok) throw new Error('HTTP '+res.status);
    const data = await res.json();
    if(!data.ok) throw new Error(data.err||'Unknown error');
    return data.data;
  }

  async function loadHosts(){
    try{
      setStatus('Loading…');
      const data = await call('hl');
      state.rows = data;
      state.statusMap = {};
      render();
      setStatus('Ready');
    }catch(e){ showError('Failed to load hosts: '+e.message); }
  }

  async function wake(name){
    state.statusMap[name] = 'Sent';
    render();
    setStatus('Waking…');
    try{
      await call('hw', { host:name });
      setStatus('Magic packet sent', 'ok');
    }catch(e){
      state.statusMap[name] = 'Error';
      render();
      showError('Wake failed: '+e.message);
    }
  }

  async function ping(name){
    state.statusMap[name] = 'Loading';
    render();
    setStatus('Checking…');
    try{
      const data = await call('ping', { host:name });
      const online = !!data.online;
      state.statusMap[name] = online ? 'Online' : 'Offline';
      render();
      setStatus('Ready', online ? 'ok' : 'err');
    }catch(e){
      state.statusMap[name] = 'Error';
      render();
      showError('Ping failed: '+e.message);
    }
  }

  function handleClick(ev){
    const btn = ev.target.closest('button[data-act]');
    if(!btn) return;
    const host = btn.dataset.host;
    if(btn.dataset.act==='wake') wake(host);
    if(btn.dataset.act==='ping') ping(host);
  }

  // --- THEME LOGIC ---
  function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    $('#themeToggle').checked = theme === 'dark';
    try { localStorage.setItem('theme', theme); } catch(e){}
  }

  function getSystemTheme() {
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  function loadTheme() {
    let theme = 'dark';
    try {
      theme = localStorage.getItem('theme') || getSystemTheme();
    } catch(e){
      theme = getSystemTheme();
    }
    applyTheme(theme);
  }

  function handleThemeToggle() {
    const theme = $('#themeToggle').checked ? 'dark' : 'light';
    applyTheme(theme);
  }

  function handleSort(ev){
    const th = ev.target.closest('th.sortable');
    if(!th) return;
    const key = th.dataset.key;
    if(key){
      if(state.sortKey === key){
        state.sortDir = -state.sortDir;
      }else{
        state.sortKey = key; state.sortDir = 1;
      }
      render();
    }
  }

  function init(){
    $('#grid').addEventListener('click', handleClick);
    $('#grid thead').addEventListener('click', handleSort);
    $('#refresh').addEventListener('click', loadHosts);

    // Theme logic
    $('#themeToggle').addEventListener('change', handleThemeToggle);
    loadTheme();

    // Font size logic
    $('#fontPlus').addEventListener('click', handleFontPlus);
    $('#fontMinus').addEventListener('click', handleFontMinus);
    loadFontSize();

    loadHosts();
  }

  window.addEventListener('DOMContentLoaded', init);
})();
EOF

# ---------------------------
#  api.lua (CGI) -- fix ping for all OpenWrt
# ---------------------------
cat > "$EWOL_DIR/api.lua" << 'EOF'
#!/usr/bin/lua
-- eWOL CGI API

local json = require('luci.jsonc')
local nixio = require('nixio')
local sys = require('luci.sys')
local ip = require('luci.ip')

local DEVICES_JSON = '/www/ewol/devices.json'
local LAN_IF = 'br-lan'
local PING_TIMEOUT = 1
local ALLOW_PUBLIC = 0 -- Set 1 to allow WAN/public

local function in_lan(addr)
  local a = ip.IPv4(addr)
  local dev = ip.IPv4(ip.getaddr(LAN_IF) or '0.0.0.0/0')
  return a and dev and a:is4() and dev:contains(a)
end

local function enforce_origin()
  if ALLOW_PUBLIC == 1 then return true end
  local ra = nixio.getenv('REMOTE_ADDR') or ''
  if ra == '' then return false end
  if in_lan(ra) then return true end
  return false
end

local function wol_send(mac)
  return sys.call(string.format("etherwake -D -i %s %q >/dev/null 2>&1", LAN_IF, mac)) == 0
end

-- Use system ping for best compatibility, not luci.sys.ping
local function ping_host(ipaddr)
  return os.execute("ping -c 1 -w 1 " .. ipaddr .. " >/dev/null 2>&1") == 0
end

local function load_devices()
  local f = io.open(DEVICES_JSON, 'r')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  return json.parse(data)
end

local function json_out(tbl)
  io.write('Status: 200 OK\r\n')
  io.write('Content-Type: application/json\r\n\r\n')
  io.write(json.stringify(tbl))
end

local function main()
  local args = require('luci.http').urldecode_params(nixio.getenv('QUERY_STRING') or '')
  local ret = { ok=false }

  if not enforce_origin() then
    ret.err = 'Forbidden: not from LAN';
    return json_out(ret)
  end

  local devices = load_devices()
  if not devices then ret.err = 'Missing devices.json'; return json_out(ret) end

  local cmd = args.cmd or 'hl'
  if cmd == 'hl' then
    local rows = {}
    for name, info in pairs(devices) do
      rows[#rows+1] = { name=name, mac=info.mac, ip=info.ip }
    end
    ret.ok = true; ret.data = rows
  elseif cmd == 'hw' then
    local h = devices[args.host]
    if not h then ret.err = 'Unknown host'
    else
      if wol_send(h.mac) then
        ret.ok = true; ret.data = { sent=true }
      else ret.err = 'WoL command failed' end
    end
  elseif cmd == 'ping' then
    local h = devices[args.host]
    if not h or not h.ip then ret.err = 'Unknown host or missing IP'
    else
      local online = ping_host(h.ip)
      ret.ok = true; ret.data = { online = online }
    end
  else
    ret.err = 'Unknown command'
  end

  return json_out(ret)
end

main()
EOF

# ---------------------------
#  devices.json sample file
# ---------------------------
if [ ! -f "$EWOL_DIR/devices.json" ]; then
  cat > "$EWOL_DIR/devices.json" << 'EOF'
{
  "PC1": {
    "mac": "11:11:11:11:11:11",
    "ip": "192.168.1.101"
  },
  "PC2": {
    "mac": "22:22:22:22:22:22",
    "ip": "192.168.1.102"
  },
  "PC3": {
    "mac": "33:33:33:33:33:33",
    "ip": "192.168.1.103"
  }
}
EOF
fi

# ---------------------------
#  permissions + cgi link
# ---------------------------
chmod 644 "$EWOL_DIR/index.html"
chmod 644 "$EWOL_DIR/script.js"
chmod 644 "$EWOL_DIR/style.css"
chmod 644 "$EWOL_DIR/devices.json"
chmod 755 "$EWOL_DIR/api.lua"
[ -L "$CGI_LINK" ] || ln -s "$EWOL_DIR/api.lua" "$CGI_LINK"

cat <<EOF
eWOL installed!

----------------------------------------------------------------------------
Next steps:
  1) Edit $EWOL_DIR/devices.json with your hosts:
       {
         "office-pc": { "mac": "AA:BB:CC:DD:EE:FF", "ip": "192.168.1.100" },
         "nas": { "mac": "11:22:33:44:55:66", "ip": "192.168.1.101" }
       }

  2) Install etherwake if missing:
       opkg update && opkg install etherwake

  3) Open http://<router-ip>/ewol/index.html

Optional settings:

If you attempt to open http://<router-ip>/ewol and it gives 403, set 
  
    'option index_page "index.html"' 

in /etc/config/uhttpd and restart uhttpd with
  
    /etc/init.d/uhttpd restart

----------------------------------------------------------------------------

Optional security:

Default denies access from WAN. To allow public access, export 
EWOL_ALLOW_PUBLIC=1 in uhttpd env or set ALLOW_PUBLIC=1 in api.lua.
----------------------------------------------------------------------------
EOF
