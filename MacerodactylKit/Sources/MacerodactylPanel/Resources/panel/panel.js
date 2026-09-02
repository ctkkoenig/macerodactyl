// Macerodactyl web panel — phone-first SPA.
//
// XSS posture: this file assigns NO parsed-HTML sink (no HTML-string property,
// no adjacent-HTML insertion, no document writing). All UI is built with the h()
// helper below, where untrusted values (container names, file names, log/console
// text, overview fields, schedule data) can only become DOM text nodes or
// attribute values — never parsed markup. A missed escape is therefore
// impossible by construction, not by discipline. A test enforces this invariant.

const CSRF = { 'X-Macerodactyl-CSRF': '1' };
const view = document.getElementById('view'), titleEl = document.getElementById('title');
const backBtn = document.getElementById('back'), tabbar = document.getElementById('tabbar');

// --- safe DOM builder -------------------------------------------------------
function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  if (props) {
    for (const k in props) {
      const v = props[k];
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k.slice(0, 2) === 'on') { if (typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v); }  // never as an inline-handler attribute
      else if (k === 'value') el.value = v;
      else if (k === 'disabled' || k === 'checked' || k === 'hidden') el[k] = !!v;
      else el.setAttribute(k, v === true ? '' : v);
    }
  }
  addKids(el, kids);
  return el;
}
function addKids(el, kids) {
  for (const kid of kids) {
    if (kid == null || kid === false) continue;
    if (Array.isArray(kid)) addKids(el, kid);
    else el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
}
function show(...nodes) { view.replaceChildren(...nodes.flat().filter(Boolean)); view.scrollTop = 0; }
function msg(text, err) { return h('p', { class: err ? 'msg err' : 'msg', text }); }

const bytes = n => {
  if (n == null) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0, v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)) + ' ' + u[i];
};

let statSrc = null, logSrc = null, landingTimer = null, current = null, detail = null, tab = 'console';
let me = { isAdmin: false };
function closeStreams() { if (statSrc) { statSrc.close(); statSrc = null; } if (logSrc) { logSrc.close(); logSrc = null; } }
function stopLanding() { if (landingTimer) { clearInterval(landingTimer); landingTimer = null; } }
async function jget(p) { const r = await fetch(p); if (!r.ok) throw r; return r.json(); }
const enc = encodeURIComponent;
const api = suffix => '/api/containers/' + enc(current) + suffix;

document.getElementById('signout').onclick = async () => { await fetch('/logout', { method: 'POST', headers: CSRF }); location.href = '/login'; };
document.getElementById('account').onclick = () => openAccount();
backBtn.onclick = () => showHome();

// --- account & security (2FA + sessions) ------------------------------------
async function openAccount() {
  const body = h('div', {});
  const sheet = h('div', { class: 'sheet' },
    h('header', {},
      h('button', { class: 'lnk', text: 'Close', onclick: () => sheet.remove() }),
      h('span', { class: 'fp' }, me.username ? ('Signed in as ' + me.username) : 'Account & security')),
    h('div', { style: 'overflow:auto; flex:1; padding:4px 2px 20px;' }, body));
  document.body.appendChild(sheet);
  await renderAccount(body);
}
async function renderAccount(body) {
  body.replaceChildren(h('p', { class: 'msg', text: 'Loading…' }));
  const [twofa, sessions] = await Promise.all([
    jget('/api/2fa/status').catch(() => ({ enabled: false })),
    jget('/api/sessions').catch(() => []),
  ]);
  body.replaceChildren(twoFactorSection(twofa, body), sessionsSection(sessions, body));
}
function twoFactorSection(status, body) {
  const wrap = h('div', {}, h('h2', { text: 'Two-factor authentication' }));
  if (status.enabled) {
    wrap.append(
      h('div', { class: 'note okrun', text: '2FA is ON. A code from your authenticator is required at login.' }),
      h('div', { class: 'field' },
        h('input', { id: 'off2fa', placeholder: 'Current 6-digit code', inputmode: 'numeric', autocomplete: 'one-time-code' }),
        h('button', { class: 'danger', style: 'width:auto;margin:0;', text: 'Turn off', onclick: async () => {
          const code = document.getElementById('off2fa').value.trim();
          const r = await fetch('/api/2fa/disable', { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, CSRF), body: JSON.stringify({ code }) });
          if (r.ok) renderAccount(body); else alert((await r.json().catch(() => ({}))).error || 'Failed');
        } })));
  } else {
    wrap.append(
      h('div', { class: 'note', text: 'Add a second factor. You will need an authenticator app (e.g. 1Password, Google Authenticator).' }),
      h('button', { class: 'primary', text: 'Set up 2FA', onclick: () => beginEnroll(body) }));
  }
  return wrap;
}
async function beginEnroll(body) {
  let data; try { data = await (await fetch('/api/2fa/begin', { method: 'POST', headers: CSRF })).json(); } catch (e) { alert('Failed'); return; }
  if (!data.secret) { alert(data.error || 'Failed'); return; }
  const panel = h('div', {},
    h('h2', { text: 'Set up 2FA' }),
    h('div', { class: 'note', text: 'Add this key to your authenticator app (or open the link on this device), then enter the current code to confirm.' }),
    h('div', { class: 'kv' }, h('span', { class: 'kk', text: 'Secret' }), h('span', { class: 'vv', text: data.secret })),
    h('div', { class: 'kv' }, h('span', { class: 'kk', text: 'Link' }), h('a', { class: 'vv', href: data.uri, style: 'color:var(--accent)', text: 'otpauth://…' })),
    h('div', { class: 'field' },
      h('input', { id: 'on2fa', placeholder: '6-digit code', inputmode: 'numeric', autocomplete: 'one-time-code' }),
      h('button', { class: 'primary', style: 'width:auto;margin:0;', text: 'Confirm', onclick: async () => {
        const code = document.getElementById('on2fa').value.trim();
        const r = await fetch('/api/2fa/confirm', { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, CSRF), body: JSON.stringify({ code }) });
        if (r.ok) renderAccount(body); else alert((await r.json().catch(() => ({}))).error || 'Failed');
      } })));
  body.replaceChildren(panel);
}
function sessionsSection(sessions, body) {
  const wrap = h('div', {}, h('h2', { text: 'Active sessions' }));
  if (Array.isArray(sessions) && sessions.length > 1) {
    wrap.append(h('button', { class: 'danger', text: 'Sign out everywhere else', onclick: async () => {
      await fetch('/api/sessions/revoke-others', { method: 'POST', headers: CSRF });
      renderAccount(body);
    } }));
  }
  for (const s of (sessions || [])) {
    const when = s.lastSeen || s.createdAt || '';
    const label = (s.ip || 'unknown') + (s.current ? '  · this device' : '');
    const row = h('div', { class: 'fileitem' },
      h('span', { class: 'meta', style: 'flex:1;min-width:0;' },
        h('div', { class: 'nm', text: label }),
        h('div', { class: 'st', style: 'font-size:12px;color:var(--muted);', text: when })));
    if (!s.current) {
      row.append(h('button', { class: 'act del', title: 'Revoke', text: '✕', onclick: async () => {
        await fetch('/api/sessions/' + enc(s.id), { method: 'DELETE', headers: CSRF });
        renderAccount(body);
      } }));
    }
    wrap.append(row);
  }
  return wrap;
}
// Tear everything down when the tab is hidden (phone backgrounds Safari) or
// unloaded — no docker logs/stats keeps running server-side for a lost tab.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { closeStreams(); stopLanding(); }
  else { if (current) openContainerStreams(); else if (isHome) startLanding(); }
});
window.addEventListener('pagehide', () => { closeStreams(); stopLanding(); });

// --- landing (Pterodactyl-style server list) --------------------------------
let isHome = true;
let rowLimits = {};  // name -> {mem, cpu} for the "of X"/hot calc on each poll
function cores(n) { return n === 1 ? '1 core' : (Number.isInteger(n) ? n + ' cores' : n.toFixed(1) + ' cores'); }
function firstAddr(ports) {
  // "0.0.0.0:27980->80/tcp, ..." — surface the first host mapping compactly.
  const m = (ports || '').match(/(?:0\.0\.0\.0:|:::|127\.0\.0\.1:)?(\d+)->/);
  return m ? (':' + m[1]) : '';
}
async function showHome() {
  closeStreams(); current = null; detail = null; isHome = true; document.body.classList.remove('detail');
  titleEl.replaceChildren(document.createTextNode('Macerodactyl')); backBtn.hidden = true; tabbar.hidden = true;
  let list;
  try { list = await jget('/api/containers'); } catch (e) { show(msg('Could not load containers.', true)); return; }
  if (!list.length) { show(msg('No containers you can access.')); return; }
  rowLimits = {};
  list.forEach(c => rowLimits[c.name] = { mem: c.memoryLimitBytes, cpu: c.cpuCores });
  const byStack = {}, loose = [];
  list.forEach(c => { if (c.stack) (byStack[c.stack] = byStack[c.stack] || []).push(c); else loose.push(c); });
  const nodes = [];
  Object.keys(byStack).sort().forEach(s => { nodes.push(h('h2', { class: 'section', text: s }), serverList(byStack[s])); });
  if (loose.length) nodes.push(h('h2', { class: 'section', text: 'Unmanaged' }), serverList(loose));
  if (me.isAdmin) nodes.push(maintenanceCard());
  show(nodes);
  startLanding();
}
function serverList(cs) { return h('div', { class: 'serverlist' }, cs.map(serverRow)); }
function serverRow(c) {
  const cls = !c.running ? 'down' : (c.health === 'unhealthy' || c.health === 'starting' ? 'warn' : 'up');
  const memLim = c.memoryLimitBytes ? 'of ' + bytes(c.memoryLimitBytes) : 'Unlimited';
  const cpuLim = c.cpuCores != null ? 'of ' + cores(c.cpuCores) : 'Unlimited';
  const addr = c.running ? firstAddr(c.ports) : '';
  return h('button', { class: 'server ' + cls, onclick: () => enter(c.name) },
    h('span', { class: 'avatar', text: /mc|minecraft/i.test(c.name) ? '🎮' : '🐳' }),
    h('span', { class: 'ident' }, h('div', { class: 'nm', text: c.name }), h('div', { class: 'desc', text: c.image })),
    addr ? h('span', { class: 'addr' }, h('span', { class: 'ai', text: '🔗' }), addr) : h('span', { class: 'addr' }),
    h('span', { class: 'sgroups' },
      statGroup(c.name, 'cpu', '◔', c.running ? '…' : '—', cpuLim),
      statGroup(c.name, 'mem', '▤', c.running ? '…' : '—', memLim)),
    h('span', { class: 'edge' }));
}
function statGroup(name, kind, icon, value, limit) {
  return h('span', { class: 'sg', 'data-sg': name + ':' + kind },
    h('span', { class: 'ic', text: icon }),
    h('span', {}, h('div', { class: 'v', 'data-c': name, 'data-stat': kind, text: value }), h('div', { class: 'lim', text: limit })));
}
function maintenanceCard() {
  return h('div', {},
    h('h2', { class: 'section', text: 'Maintenance (admin)' }),
    h('div', { class: 'filebar' },
      h('button', { text: 'Disk usage', onclick: showDisk }),
      h('button', { text: 'Prune dangling images', onclick: pruneImages })));
}
async function showDisk() {
  try { const d = await jget('/api/maintenance/disk'); alert(d.output || '(no output)'); }
  catch (e) { alert('Failed to read disk usage.'); }
}
async function pruneImages() {
  if (!confirm('Remove all dangling images across the whole daemon?')) return;
  try {
    const r = await fetch('/api/maintenance/image-prune', { method: 'POST', headers: CSRF });
    const j = await r.json().catch(() => ({}));
    alert(r.ok ? (j.output || 'Done') : (j.error || 'Failed'));
  } catch (e) { alert('Failed.'); }
}
function startLanding() { stopLanding(); pollStats(); landingTimer = setInterval(pollStats, 5000); }
async function pollStats() {
  let stats; try { stats = await jget('/api/stats'); } catch (e) { return; }
  const map = {}; stats.forEach(s => map[s.name] = s);
  document.querySelectorAll('.v[data-c][data-stat]').forEach(el => {
    const name = el.getAttribute('data-c'), kind = el.getAttribute('data-stat'), s = map[name];
    const lim = rowLimits[name] || {};
    let hot = false;
    if (!s) { el.textContent = '—'; }
    else if (kind === 'cpu') {
      el.textContent = s.cpuPercent.toFixed(1) + '%';
      if (lim.cpu != null) hot = s.cpuPercent / (lim.cpu * 100) > 0.9;
    } else if (kind === 'mem') {
      el.textContent = bytes(s.memUsedBytes);
      if (lim.mem) hot = s.memUsedBytes / lim.mem > 0.9;
    }
    const sg = document.querySelector('.sg[data-sg="' + name + ':' + kind + '"]');
    if (sg) sg.classList.toggle('hot', hot);
  });
}

// --- container view ---------------------------------------------------------
window.enter = async function (name) {
  stopLanding();
  try { detail = await jget('/api/containers/' + enc(name)); } catch (e) { show(msg('Unavailable.', true)); return; }
  current = name; isHome = false; document.body.classList.add('detail');
  titleEl.replaceChildren(document.createTextNode(name)); backBtn.hidden = false;
  // Only build nav items for features that exist — never a tab that leads nowhere.
  const p = detail.permissions, tabs = [];
  if (p.console) tabs.push(['console', 'Console', '⌘']);
  tabs.push(['overview', 'Overview', 'ⓘ']);
  tabs.push(['logs', 'Logs', '≣']);
  if (p.files && detail.filesAvailable) tabs.push(['files', 'Files', '▤']);
  if (p.schedules) tabs.push(['schedules', 'Schedules', '⏱']);
  tabbar.hidden = false;
  tabbar.replaceChildren(...tabs.map(t => h('button', { class: 'navitem', 'data-t': t[0], onclick: () => setTab(t[0]) },
    h('span', { class: 'tile', text: t[2] }), h('span', { class: 'lbl', text: t[1] }))));
  tab = p.console ? 'console' : 'overview';
  openContainerStreams();
  render();
};
function openContainerStreams() {
  if (!current) return;
  if (statSrc) statSrc.close();
  statSrc = new EventSource(api('/stats'));
  statSrc.onmessage = e => { try { paintStats(JSON.parse(e.data)); } catch (_) { } };
}
let lastStats = null;
function paintStats(s) {
  lastStats = s.unavailable ? null : s;
  const old = document.getElementById('statstrip');
  if (old) old.replaceWith(statCards());
}
// The stat column (screenshot 2): icon tile, label, and value with the limit
// after a slash. Limits are the container's REAL configured limits, or
// "Unlimited" — never the host total. The icon turns red near a real limit.
function statCards() {
  const s = lastStats, d = detail;
  const memHot = !!(s && d.memoryLimitBytes && s.memUsedBytes / d.memoryLimitBytes > 0.9);
  const cpuHot = !!(s && d.cpuCores != null && s.cpuPercent / (d.cpuCores * 100) > 0.9);
  const card = (cls, ic, k, main, lim, hot) => h('div', { class: 'statcard ' + cls + (main == null ? ' na' : '') + (hot ? ' hot' : '') },
    h('span', { class: 'ic', text: ic }),
    h('div', { class: 'body' }, h('div', { class: 'k', text: k }),
      h('div', { class: 'v' }, main == null ? '—' : main, (main != null && lim) ? h('span', { class: 'lim', text: ' / ' + lim }) : null)));
  return h('div', { class: 'statcol', id: 'statstrip' },
    card('cpu', '◔', 'CPU', s ? s.cpuPercent.toFixed(1) + '%' : null, d.cpuCores != null ? cores(d.cpuCores) : 'Unlimited', cpuHot),
    card('mem', '▤', 'Memory', s ? bytes(s.memUsedBytes) : null, d.memoryLimitBytes ? bytes(d.memoryLimitBytes) : 'Unlimited', memHot),
    card('net', '⇅', 'Network', s ? ('↓ ' + bytes(s.netRxBytes) + '   ↑ ' + bytes(s.netTxBytes)) : null, null),
    card('pids', '◈', 'Processes', s ? String(s.pids) : null, null));
}

function wsHead() {
  return h('div', { class: 'wshead' },
    h('div', { class: 'h' },
      h('h1', { text: current }),
      h('div', { class: 'desc', text: detail.image + (detail.stack ? '  ·  ' + detail.stack : '') })),
    powerRow());
}
function metaRows() {
  const d = detail, kv = (k, v) => h('div', { class: 'kv' }, h('span', { class: 'kk', text: k }), h('span', { class: 'vv', text: v }));
  const rows = [kv('Status', d.status), kv('Image', d.image)];
  if (d.ports) rows.push(kv('Ports', d.ports));
  if (d.stack) rows.push(kv('Stack', d.stack));
  return h('div', {}, rows);
}

window.setTab = function (t) { if (logSrc) { logSrc.close(); logSrc = null; } tab = t; render(); };
function render() {
  tabbar.querySelectorAll('.navitem').forEach(b => b.classList.toggle('sel', b.getAttribute('data-t') === tab));
  const parts = [wsHead()];
  if (tab === 'console') {
    const main = h('div', {}, lifecycleRow(), h('div', { class: 'term', id: 'cterm' }), quickRow(), inputBar());
    parts.push(h('div', { class: 'consolelayout' }, main, statCards()));
  } else if (tab === 'overview') {
    const main = h('div', {},
      h('div', { class: 'sparkwrap' }, h('div', { class: 'lbl', text: 'CPU — last hour' }), h('div', { id: 'spark' })),
      metaRows(), lifecycleRow());
    parts.push(h('div', { class: 'consolelayout' }, main, statCards()));
  } else if (tab === 'logs') { parts.push(...logsTab()); }
  else if (tab === 'files') { parts.push(h('div', { id: 'files' })); }
  else if (tab === 'schedules') { parts.push(h('div', { id: 'sched' }, 'Loading…')); }
  show(parts);
  if (tab === 'logs') startLogs();
  if (tab === 'console') bindConsole();
  if (tab === 'overview') loadSparkline();
  if (tab === 'files') listDir('');
  if (tab === 'schedules') loadSchedule();
}

// --- console + power + lifecycle -------------------------------------------
function powerRow() {
  const r = detail.running, p = detail.permissions;
  if (!p.power) return null;
  return h('div', { class: 'power' },
    h('button', { class: 'start', disabled: r, onclick: () => power('start') }, 'Start'),
    h('button', { class: 'restart', disabled: !r, onclick: () => power('restart') }, 'Restart'),
    h('button', { class: 'stop', disabled: !r, onclick: () => power('stop') }, 'Stop'),
    h('button', { class: 'kill', disabled: !r, onclick: killC }, 'Kill'));
}
function lifecycleRow() {
  const p = detail.permissions;
  if (!p.lifecycle) return null;
  const row = h('div', { class: 'life' },
    h('button', { onclick: () => lifecycleStream('/pull', 'Pull ' + detail.image + '?') }, 'Pull'),
    detail.filesAvailable ? h('button', { onclick: () => lifecycleStream('/recreate', 'Recreate ' + current + '?') }, 'Recreate') : null,
    detail.filesAvailable ? h('button', { onclick: () => lifecycleStream('/compose/apply', 'Apply compose for ' + current + '?') }, 'Apply compose') : null,
    h('button', { class: 'rm', onclick: removeContainer }, 'Remove'));
  return row;
}
async function lifecycleStream(path, prompt) {
  if (!confirm(prompt)) return;
  const term = h('div', { class: 'term' });
  show(wsHead(), lifecycleRow(), term);
  try {
    const r = await fetch(api(path), { method: 'POST', headers: CSRF });
    if (!r.ok || !r.body) { const j = await r.json().catch(() => ({})); term.append(j.error || ('Failed (' + r.status + ')') + '\n'); return; }
    const reader = r.body.getReader(), dec = new TextDecoder();
    for (; ;) {
      const { value, done } = await reader.read(); if (done) break;
      // SSE frames "data: <text>\n\n" — strip the prefix, keep the text.
      dec.decode(value, { stream: true }).split('\n').forEach(ln => {
        if (ln.startsWith('data: ')) { term.append(ln.slice(6) + '\n'); term.scrollTop = term.scrollHeight; }
      });
    }
    term.append('\n✓ done\n');
    detail = await jget('/api/containers/' + enc(current)).catch(() => detail);
  } catch (e) { term.append('\nrequest failed\n'); }
}
async function removeContainer() {
  if (!confirm('Remove ' + current + '? The container must be stopped. This cannot be undone.')) return;
  try {
    const r = await fetch(api('/remove'), { method: 'DELETE', headers: CSRF });
    if (r.ok) { alert('Removed.'); showHome(); }
    else { const j = await r.json().catch(() => ({})); alert(j.error || 'Failed'); }
  } catch (e) { alert('Failed.'); }
}
window.power = async function (a) { if (!confirm(a + ' ' + current + '?')) return; await doPower(a); };
function killC() { if (!confirm('Kill ' + current + '? SIGKILL is immediate — no clean shutdown. Use Stop for graceful.')) return; doPower('kill'); }
async function doPower(a) {
  const r = await fetch(api('/power'), { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, CSRF), body: JSON.stringify({ action: a }) });
  detail = await jget('/api/containers/' + enc(current)); openContainerStreams(); render(); if (!r.ok) alert('Action failed');
}
function quickRow() {
  const mc = /mc|minecraft/i.test(current);
  const quick = mc ? ['list', 'say hi', 'time set day'] : ['ls', 'ls -la', 'cat ', 'tail -n 50 ', '|'];
  return h('div', { class: 'quick' }, quick.map(q => h('button', { onclick: () => qk(q), text: q })));
}
function inputBar() {
  const mc = /mc|minecraft/i.test(current);
  return h('div', { class: 'inputbar' },
    h('span', { class: 'chev', text: '›' }),
    h('input', { id: 'cin', placeholder: mc ? 'server command' : 'shell command', autocapitalize: 'off', autocorrect: 'off', spellcheck: 'false' }),
    h('button', { onclick: runCmd }, 'Send'));
}
let history = [];
function bindConsole() {
  const inp = document.getElementById('cin');
  if (inp) inp.addEventListener('keydown', e => { if (e.key === 'Enter') runCmd(); if (e.key === 'ArrowUp' && history.length) inp.value = history[history.length - 1]; });
}
function qk(t) { const i = document.getElementById('cin'); i.value += t; i.focus(); }
async function runCmd() {
  const inp = document.getElementById('cin'), term = document.getElementById('cterm');
  const cmd = inp.value.trim(); if (!cmd) return; inp.value = ''; history.push(cmd);
  term.append(h('div', { class: 'cmdline', text: '$ ' + cmd }));
  try {
    const r = await fetch(api('/console'), { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, CSRF), body: JSON.stringify({ command: cmd }) });
    const j = await r.json();
    term.append(h('div', { class: j.isError ? 'cerr' : '', text: j.output || '' }));
  } catch (e) { term.append(h('div', { class: 'cerr', text: 'request failed' })); }
  term.scrollTop = term.scrollHeight;
}

// --- logs (stream + search + download) --------------------------------------
let follow = true;
function logsTab() {
  const term = h('div', { class: 'term', id: 'lterm' });
  const fol = h('input', { type: 'checkbox', id: 'fol', checked: true });
  fol.onchange = () => { follow = fol.checked; };
  const q = h('input', { type: 'search', id: 'lq', placeholder: 'Search logs…', autocapitalize: 'off' });
  q.addEventListener('keydown', e => { if (e.key === 'Enter') searchLogs(q.value); });
  return [
    h('div', { class: 'toolrow' },
      h('label', {}, fol, ' Follow'),
      q,
      h('button', { class: 'lnk', onclick: () => searchLogs(q.value) }, 'Search'),
      h('button', { class: 'lnk', onclick: downloadLogs }, 'Download')),
    term
  ];
}
function startLogs() {
  const term = document.getElementById('lterm'); if (logSrc) logSrc.close();
  logSrc = new EventSource(api('/logs'));
  logSrc.onmessage = e => {
    const at = term.scrollTop + term.clientHeight >= term.scrollHeight - 30;
    term.append(e.data + '\n');
    if (follow && at) term.scrollTop = term.scrollHeight;
  };
}
async function searchLogs(q) {
  if (logSrc) { logSrc.close(); logSrc = null; }
  const term = document.getElementById('lterm'); term.textContent = '';
  try {
    const res = await jget(api('/logs/search') + '?q=' + enc(q || ''));
    if (!res.matches.length) { term.textContent = '(no matches)'; return; }
    term.textContent = res.matches.join('\n') + (res.truncated ? '\n… (truncated)' : '');
  } catch (e) { term.textContent = 'Search failed.'; }
}
function downloadLogs() { window.open(api('/logs/download'), '_blank'); }

// --- overview + metrics sparkline -------------------------------------------
async function loadSparkline() {
  const host = document.getElementById('spark'); if (!host) return;
  let samples; try { samples = await jget(api('/metrics') + '?since=3600'); } catch (e) { host.replaceChildren(document.createTextNode('—')); return; }
  if (!samples.length) { host.replaceChildren(h('span', { class: 'lbl', text: 'measuring…' })); return; }
  host.replaceChildren(sparkline(samples.map(s => s.cpuPercent)));
}
function sparkline(values) {
  const W = 300, H = 44, n = values.length;
  const max = Math.max(1, ...values);
  const x = i => (n <= 1 ? 0 : (i / (n - 1)) * W);
  const y = v => H - 2 - (v / max) * (H - 4);
  const pts = values.map((v, i) => x(i).toFixed(1) + ',' + y(v).toFixed(1));
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('class', 'spark'); svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H); svg.setAttribute('preserveAspectRatio', 'none');
  const area = document.createElementNS(NS, 'polygon');
  area.setAttribute('class', 'fill');
  area.setAttribute('points', '0,' + H + ' ' + pts.join(' ') + ' ' + W + ',' + H);
  const line = document.createElementNS(NS, 'polyline');
  line.setAttribute('class', 'line'); line.setAttribute('points', pts.join(' '));
  svg.append(area, line);
  return svg;
}

// --- files (list + open/edit + upload/mkdir/download/rename/delete) ----------
async function listDir(path) {
  const host = document.getElementById('files'); if (!host) return;
  let entries;
  try { entries = await jget(api('/files') + '?path=' + enc(path)); }
  catch (e) { host.replaceChildren(msg('Cannot list folder.', true)); return; }
  const parts = path ? path.split('/') : [];
  const crumb = h('div', { class: 'crumb' }, h('button', { onclick: () => cd(''), text: '/' }));
  parts.forEach((seg, i) => { const acc = parts.slice(0, i + 1).join('/'); crumb.append(h('span', { text: '/' }), h('button', { onclick: () => cd(acc), text: seg })); });
  const bar = h('div', { class: 'filebar' },
    h('button', { text: '＋ New folder', onclick: () => mkdir(path) }),
    uploadButton(path));
  const listEl = h('div', { class: 'clist' }, entries.map(en => fileRow(en, path)));
  host.replaceChildren(crumb, bar, listEl);
}
function fileRow(en, path) {
  const row = h('div', { class: 'fileitem' },
    h('span', { text: en.isDirectory ? '📁' : '📄' }),
    h('button', { class: 'nm', style: 'background:none;border:0;color:inherit;text-align:left;font:inherit;padding:0;', text: en.name,
      onclick: () => en.isDirectory ? cd(en.path) : openFile(en.path) }),
    en.isDirectory ? null : h('span', { class: 'use', text: bytes(en.size) }));
  if (!en.isDirectory) row.append(h('button', { class: 'act', title: 'Download', onclick: () => window.open(api('/files/download') + '?path=' + enc(en.path), '_blank'), text: '⤓' }));
  row.append(
    h('button', { class: 'act', title: 'Rename', onclick: () => renameEntry(en, path), text: '✎' }),
    h('button', { class: 'act del', title: 'Delete', onclick: () => deleteEntry(en), text: '🗑' }));
  return row;
}
function uploadButton(path) {
  const input = h('input', { type: 'file', hidden: true });
  input.onchange = async () => {
    const f = input.files[0]; if (!f) return;
    const target = (path ? path + '/' : '') + f.name;
    try {
      const r = await fetch(api('/files/upload') + '?path=' + enc(target), { method: 'POST', headers: CSRF, body: f });
      if (!r.ok) { const j = await r.json().catch(() => ({})); alert(j.error || 'Upload failed'); }
    } catch (e) { alert('Upload failed.'); }
    listDir(path);
  };
  const btn = h('button', { text: '⤒ Upload', onclick: () => input.click() });
  return h('span', {}, btn, input);
}
async function mkdir(path) {
  const name = prompt('New folder name'); if (!name) return;
  const target = (path ? path + '/' : '') + name;
  const r = await fetch(api('/files/dir'), { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, CSRF), body: JSON.stringify({ path: target }) });
  if (!r.ok) { const j = await r.json().catch(() => ({})); alert(j.error || 'Failed'); }
  listDir(path);
}
async function renameEntry(en, path) {
  const name = prompt('Rename to', en.name); if (!name || name === en.name) return;
  const to = (path ? path + '/' : '') + name;
  const r = await fetch(api('/files/move'), { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, CSRF), body: JSON.stringify({ from: en.path, to }) });
  if (!r.ok) { const j = await r.json().catch(() => ({})); alert(j.error || 'Failed'); }
  listDir(path);
}
async function deleteEntry(en) {
  if (!confirm('Delete ' + en.name + '?' + (en.isDirectory ? ' The folder and its contents.' : ''))) return;
  const r = await fetch(api('/files/entry') + '?path=' + enc(en.path), { method: 'DELETE', headers: CSRF });
  if (!r.ok) { const j = await r.json().catch(() => ({})); alert(j.error || 'Failed'); }
  const parent = en.path.includes('/') ? en.path.slice(0, en.path.lastIndexOf('/')) : '';
  listDir(parent);
}
function cd(path) { listDir(path); }
async function openFile(path) {
  let c;
  try { c = await jget(api('/files/content') + '?path=' + enc(path)); }
  catch (e) { const j = await e.json().catch(() => ({})); alert(j.error || 'Cannot open'); return; }
  editor(path, c.text, c.lineEnding);
}
function editor(path, text, le) {
  const dt = h('span', { id: 'dt' });
  const ed = h('textarea', { id: 'ed', spellcheck: 'false', autocapitalize: 'off', autocorrect: 'off' });
  const orig = text;
  const closeBtn = h('button', { class: 'lnk', text: 'Close' });
  const saveBtn = h('button', { class: 'lnk save', text: 'Save' });
  const acc = h('div', { class: 'acc' }, ['tab', 'in', 'out', 'home', 'end', 'find'].map(k =>
    h('button', { 'data-k': k, text: { tab: 'Tab', in: '⇥+', out: '⇤-', home: 'Home', end: 'End', find: 'Find' }[k] })));
  const sheet = h('div', { class: 'sheet' },
    h('header', {}, closeBtn, h('span', { class: 'fp' }, dt, path), saveBtn), ed, acc);
  document.body.appendChild(sheet);
  ed.value = text;
  ed.addEventListener('input', () => dt.textContent = ed.value !== orig ? '● ' : '');
  closeBtn.onclick = () => { if (ed.value !== orig && !confirm('Discard changes?')) return; sheet.remove(); };
  saveBtn.onclick = async () => {
    const r = await fetch(api('/files/content') + '?path=' + enc(path), { method: 'PUT', headers: Object.assign({ 'Content-Type': 'application/json' }, CSRF), body: JSON.stringify({ text: ed.value, lineEnding: le }) });
    if (r.ok) { dt.textContent = ''; } else { const j = await r.json().catch(() => ({ error: 'Save failed' })); alert(j.error || 'Save failed'); }
  };
  acc.querySelectorAll('button').forEach(b => b.onclick = () => accKey(ed, b.getAttribute('data-k')));
}
function accKey(ed, k) {
  const s = ed.selectionStart, e = ed.selectionEnd, v = ed.value, set = (a, b) => { ed.focus(); ed.setSelectionRange(a, b); };
  if (k === 'tab') { ed.value = v.slice(0, s) + '  ' + v.slice(e); set(s + 2, s + 2); ed.dispatchEvent(new Event('input')); }
  else if (k === 'home') { const ls = v.lastIndexOf('\n', s - 1) + 1; set(ls, ls); }
  else if (k === 'end') { let le = v.indexOf('\n', s); if (le < 0) le = v.length; set(le, le); }
  else if (k === 'in' || k === 'out') {
    const ls = v.lastIndexOf('\n', s - 1) + 1; let le = v.indexOf('\n', e); if (le < 0) le = v.length;
    const seg = v.slice(ls, le), out = seg.split('\n').map(l => k === 'in' ? '  ' + l : l.replace(/^ {2}/, '')).join('\n');
    ed.value = v.slice(0, ls) + out + v.slice(le); set(ls, ls + out.length); ed.dispatchEvent(new Event('input'));
  }
  else if (k === 'find') { const q = prompt('Find'); if (q) { const i = v.indexOf(q, e); if (i >= 0) set(i, i + q.length); else alert('Not found'); } }
}

// --- schedules --------------------------------------------------------------
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
let selDays = new Set();
async function loadSchedule() {
  const host = document.getElementById('sched'); if (!host) return;
  let data;
  try { data = await jget(api('/schedule')); } catch (e) { host.replaceChildren(msg('Unavailable.', true)); return; }
  const s = data.schedule; selDays = new Set(s ? s.weekdays : []);
  const nodes = [];
  if (s) {
    nodes.push(h('div', { class: 'kv' }, h('span', { class: 'kk', text: 'Current' }), h('span', { class: 'vv', text: s.description })));
    if (s.lastRun) {
      const cls = s.lastRun.outcome === 'ok' ? 'okrun' : (s.lastRun.outcome === 'timedOut' ? 'timeout' : 'fail');
      nodes.push(h('div', { class: 'note ' + cls, text: 'Last run ' + s.lastRun.date + ' — ' + s.lastRun.outcome + (s.lastRun.message ? ': ' + s.lastRun.message : '') }));
    }
  }
  const hh = s ? s.hour : 4, mm = s ? s.minute : 0;
  const hSel = h('select', { id: 'hh' }, opts(24, hh)), mSel = h('select', { id: 'mm' }, opts(60, mm));
  const daysEl = h('div', { class: 'days' }, DAYS.map((d, i) => {
    const b = h('button', { class: selDays.has(i) ? 'on' : '', text: d });
    b.onclick = () => { if (selDays.has(i)) { selDays.delete(i); b.classList.remove('on'); } else { selDays.add(i); b.classList.add('on'); } };
    return b;
  }));
  nodes.push(
    h('h2', { text: (s ? 'Change' : 'Add') + ' schedule' }),
    h('div', { class: 'field' }, 'At ', hSel, ' : ', mSel),
    daysEl,
    h('div', { class: 'note', text: 'No days selected = every day. Runs via launchd even when the app is closed; restart only.' }),
    h('button', { class: 'primary', text: s ? 'Save changes' : 'Add schedule', onclick: () => saveSched(hSel, mSel) }));
  if (s) nodes.push(h('button', { class: 'danger', text: 'Remove schedule', onclick: delSched }));
  host.replaceChildren(...nodes);
}
function opts(n, sel) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(h('option', { value: i, selected: i === sel }, String(i).padStart(2, '0')));
  return out;
}
async function saveSched(hSel, mSel) {
  const r = await fetch(api('/schedule'), { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, CSRF), body: JSON.stringify({ hour: +hSel.value, minute: +mSel.value, weekdays: [...selDays] }) });
  if (r.ok) loadSchedule(); else { const j = await r.json().catch(() => ({})); alert(j.error || 'Failed'); }
}
async function delSched() {
  if (!confirm('Remove this schedule?')) return;
  const r = await fetch(api('/schedule'), { method: 'DELETE', headers: CSRF });
  if (r.ok) loadSchedule(); else alert('Failed');
}

// --- boot -------------------------------------------------------------------
(async () => { try { me = await jget('/api/me'); } catch (e) { } showHome(); })();
