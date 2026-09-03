// Macerodactyl admin panel SPA.
//
// XSS posture identical to panel.js: NO parsed-HTML sink anywhere. Every node is
// built with the h() helper, so untrusted values (server names, egg text, user
// input, install-log lines) can only ever become DOM text or attribute values,
// never markup. A test enforces this invariant across the bundle.

const CSRF = { 'X-Macerodactyl-CSRF': '1' };
const content = document.getElementById('content');
const navEl = document.getElementById('nav');
const crumbEl = document.getElementById('crumb');
const brandEl = document.getElementById('brand');

// --- safe DOM builder (same contract as panel.js) ---------------------------
function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  if (props) {
    for (const k in props) {
      const v = props[k];
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k.slice(0, 2) === 'on') { if (typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v); }
      else if (k === 'value') el.value = v;
      else if (k === 'disabled' || k === 'checked' || k === 'hidden' || k === 'selected') el[k] = !!v;
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
function show(...nodes) { content.replaceChildren(...nodes.flat().filter(Boolean)); content.scrollTop = 0; }
function msg(text, kind) { return h('div', { class: 'msg ' + (kind || ''), text }); }

// --- API --------------------------------------------------------------------
async function errText(r) { try { const j = await r.json(); return j.error || ('HTTP ' + r.status); } catch { return 'HTTP ' + r.status; } }
async function jget(p) { const r = await fetch(p); if (!r.ok) throw await errText(r); return r.json(); }
async function jsend(method, p, body) {
  const r = await fetch(p, { method, headers: { ...CSRF, 'Content-Type': 'application/json' }, body: body != null ? JSON.stringify(body) : undefined });
  if (!r.ok) throw await errText(r);
  const t = await r.text(); return t ? JSON.parse(t) : {};
}
async function postStream(url, body, onLine, method) {
  const r = await fetch(url, { method: method || 'POST', headers: { ...CSRF, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const ct = r.headers.get('content-type') || '';
  if (ct.includes('application/json')) { throw await errText(r); }   // a pre-stream validation error
  const reader = r.body.getReader(), dec = new TextDecoder(); let buf = '';
  for (;;) {
    const { value, done } = await reader.read(); if (done) break;
    buf += dec.decode(value, { stream: true });
    let i; while ((i = buf.indexOf('\n')) >= 0) { const line = buf.slice(0, i); buf = buf.slice(i + 1); if (line.startsWith('data: ')) onLine(line.slice(6)); }
  }
  if (buf.startsWith('data: ')) onLine(buf.slice(6));
  return r.ok;
}

// --- small UI atoms ---------------------------------------------------------
const enc = encodeURIComponent;
function pageHeader(title, sub, ...actions) {
  return h('div', { class: 'page-h' }, h('h1', { text: title }), sub && h('span', { class: 'sub', text: sub }),
    h('span', { class: 'spacer', style: 'flex:1' }), ...actions);
}
function card(title, ...body) { return h('div', { class: 'card' }, title && h('div', { class: 'hd' }, title), h('div', { class: 'bd' }, ...body)); }
function tableCard(title, cols, rows, extra) {
  const thead = h('tr', null, ...cols.map(c => h('th', { text: c })));
  const body = rows.length ? rows : [h('tr', null, h('td', { colspan: cols.length }, h('div', { class: 'empty', text: 'Nothing here yet.' })))];
  return h('div', { class: 'card' }, title && h('div', { class: 'hd' }, title, extra && h('span', { style: 'flex:1' }), extra),
    h('div', { class: 'bd tight' }, h('table', null, h('thead', null, thead), h('tbody', null, ...body))));
}
function field(label, inputEl, hint, required) {
  return h('div', { class: 'field' + (inputEl.tagName === 'TEXTAREA' ? ' full' : '') },
    h('label', null, label, required && h('span', { class: 'req', text: ' *' })), inputEl, hint && h('div', { class: 'hint', text: hint }));
}
function input(name, opts = {}) { return h('input', { type: opts.type || 'text', name, value: opts.value ?? '', placeholder: opts.ph || '' }); }
function select(name, options, value) { return h('select', { name }, ...options.map(o => h('option', { value: o.value, selected: String(o.value) === String(value) }, o.label))); }
function badge(text, kind) { return h('span', { class: 'badge ' + kind, text }); }
function statusBadge(s, running) {
  if (s === 'suspended') return badge('suspended', 'bad');
  if (running) return badge('running', 'good');
  if (s === 'installing') return badge('installing', 'warn');
  if (s === 'install_failed') return badge('install failed', 'bad');
  if (s === 'active') return badge('stopped', 'muted');
  return badge(s || 'unknown', 'muted');
}
// Mirror of ServerProvisioner.slugify — a friendly name → valid stack id.
function slugify(raw) {
  let out = '', lastDash = false;
  for (const ch of String(raw).toLowerCase()) {
    if (/[a-z0-9._-]/.test(ch)) { out += ch; lastDash = false; }
    else if (!lastDash && out) { out += '-'; lastDash = true; }
  }
  return out.replace(/^[^a-z0-9]+/, '').replace(/[-._]+$/, '').slice(0, 63).replace(/[-._]+$/, '');
}
const val = (form, n) => form.querySelector(`[name="${n}"]`).value.trim();
const num = (form, n) => { const v = form.querySelector(`[name="${n}"]`).value.trim(); return v === '' ? 0 : parseInt(v, 10) || 0; };
const chk = (form, n) => form.querySelector(`[name="${n}"]`).checked;

// --- sections ---------------------------------------------------------------
const SECTIONS = [
  { group: 'Basic administration', items: [
    { id: 'overview', label: 'Overview', ico: '▤', render: renderOverview },
    { id: 'audit', label: 'Audit log', ico: '❑', render: renderAudit },
    { id: 'settings', label: 'Settings', ico: '⚙', render: renderSettings },
  ] },
  { group: 'Management', items: [
    { id: 'servers', label: 'Servers', ico: '▦', render: renderServers },
    { id: 'databases', label: 'Databases', ico: '▤', render: renderDatabases },
    { id: 'users', label: 'Users', ico: '◍', render: renderUsers },
    { id: 'nodes', label: 'Nodes', ico: '⌗', render: renderNode },
    { id: 'locations', label: 'Locations', ico: '◎', render: renderLocations },
  ] },
  { group: 'Service management', items: [
    { id: 'mounts', label: 'Mounts', ico: '⇌', render: renderMounts },
    { id: 'nests', label: 'Nests & Eggs', ico: '◈', render: renderNests },
  ] },
];
const byId = {}; SECTIONS.forEach(g => g.items.forEach(it => byId[it.id] = it));

function buildNav(active) {
  navEl.replaceChildren(...SECTIONS.flatMap(g => [
    h('div', { class: 'navgroup', text: g.group }),
    ...g.items.map(it => h('a', {
      class: 'navitem' + (it.id === active ? ' active' : ''), href: '#' + it.id,
      onclick: () => document.body.classList.remove('nav-open'),
    }, h('span', { class: 'ico', text: it.ico }), h('span', { text: it.label }))),
  ]));
}

async function route() {
  const raw = (location.hash.replace(/^#/, '') || 'overview');
  const [id, sub, arg] = raw.split('/');
  const item = byId[id] || byId.overview;
  buildNav(item.id);
  crumbEl.textContent = 'Admin › ' + item.label;
  try {
    if (id === 'servers' && sub === 'new') { await renderCreateServer(); }
    else if (id === 'servers' && sub === 'edit' && arg) { await renderEditServer(decodeURIComponent(arg)); }
    else { await item.render(); }
  } catch (e) { show(pageHeader(item.label), msg(String(e), 'err')); }
}

// Overview
async function renderOverview() {
  const o = await jget('/api/admin/overview');
  const tile = (v, k) => h('div', { class: 'tile' }, h('div', { class: 'v', text: String(v) }), h('div', { class: 'k', text: k }));
  show(pageHeader('Overview', 'System at a glance'),
    h('div', { class: 'tiles' },
      tile(o.servers, 'Servers'), tile(o.users, 'Users'), tile(o.eggs, 'Eggs'),
      tile(o.allocationsFree + ' / ' + o.allocationsTotal, 'Free allocations'),
      tile(o.dockerReachable ? 'Ready' : 'Down', 'Docker')));
}

// Audit log
async function renderAudit() {
  const rows = await jget('/api/admin/audit');
  const trs = rows.map(a => h('tr', null,
    h('td', { class: 'mono', text: (a.timestamp || '').replace('T', ' ').replace(/\..*/, '') }),
    h('td', { text: a.username }),
    h('td', { text: a.action }),
    h('td', { text: a.container || '—' }),
    h('td', null, badge(a.outcome, a.outcome === 'ok' ? 'good' : (a.outcome === 'denied' || a.outcome === 'error') ? 'bad' : 'muted')),
    h('td', { class: 'mono', text: a.ip || '—' }),
    h('td', { text: a.detail || '' })));
  show(pageHeader('Audit log', 'Every action taken through the panel'),
    tableCard('Recent activity', ['Time', 'User', 'Action', 'Server', 'Outcome', 'IP', 'Detail'], trs));
}

// Settings
async function renderSettings() {
  const s = await jget('/api/admin/settings');
  const form = h('form', { onsubmit: async e => { e.preventDefault();
    try { await jsend('PUT', '/api/admin/settings', { companyName: val(form, 'companyName'), require2FA: val(form, 'require2FA'), defaultLanguage: val(form, 'defaultLanguage'), defaultTimezone: val(form, 'defaultTimezone') });
      brandEl.textContent = val(form, 'companyName') || 'Macerodactyl';
      note.replaceChildren(msg('Saved.', 'ok'));
    } catch (err) { note.replaceChildren(msg(String(err), 'err')); } } });
  const note = h('div');
  form.append(
    h('div', { class: 'form-row' },
      field('Company name', input('companyName', { value: s.companyName }), 'Shown in the panel header and emails.'),
      field('Require 2-Factor', select('require2FA', [{ value: 'off', label: 'Not required' }, { value: 'force', label: 'Force enrollment' }, { value: 'deny_non_2fa', label: 'Deny accounts without 2FA' }], s.require2FA), 'Applies at login for accounts without their own 2FA.')),
    h('div', { class: 'form-row' },
      field('Default language', input('defaultLanguage', { value: s.defaultLanguage }), 'UI language code (English ships today).'),
      field('Default timezone', input('defaultTimezone', { value: s.defaultTimezone }), 'Passed to new servers as TZ.')),
    h('div', { class: 'actions' }, h('button', { class: 'btn', type: 'submit' }, 'Save')), note);
  show(pageHeader('Panel settings', 'Configure Macerodactyl'), card(null, form));
}

// Users
async function renderUsers() {
  const users = await jget('/api/admin/users');
  const note = h('div');
  const rows = users.map(u => h('tr', null,
    h('td', { text: u.username }), h('td', null, u.isAdmin ? badge('admin', 'good') : badge('user', 'muted')),
    h('td', null, h('div', { class: 'rowact' },
      h('button', { class: 'btn ghost sm', onclick: async () => {
        try { const r = await jsend('POST', '/api/admin/users/' + u.id + '/reset'); showResetLink(note, r); }
        catch (e) { note.replaceChildren(msg(String(e), 'err')); } } }, 'Reset password'),
      h('button', { class: 'btn ghost sm danger', onclick: async () => { if (!confirm('Delete ' + u.username + '?')) return; try { await jsend('DELETE', '/api/admin/users/' + u.id); route(); } catch (e) { alert(e); } } }, 'Delete')))));
  const form = h('form', { class: 'form-row', onsubmit: async e => { e.preventDefault();
    try { await jsend('POST', '/api/admin/users', { username: val(form, 'username'), password: val(form, 'password'), isAdmin: chk(form, 'isAdmin') }); route(); }
    catch (err) { note.replaceChildren(msg(String(err), 'err')); } } },
    field('Username', input('username')), field('Password', input('password', { type: 'password' }), 'At least 8 characters.'),
    h('div', { class: 'field' }, h('label', { text: 'Role' }), h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'isAdmin' }), 'Administrator')),
    h('div', { class: 'field', style: 'flex:0 0 auto;justify-content:flex-end' }, h('button', { class: 'btn', type: 'submit' }, 'Create user')));
  show(pageHeader('Users', 'Accounts that can sign in to the panel'), tableCard('User list', ['Username', 'Role', ''], rows), card('Create user', note, form));
}
// Renders a freshly issued one-time reset link with a copy button. The link is
// shown once here; the server only stored its hash. Handing it to the user is
// out-of-band (there is no email delivery).
function showResetLink(note, r) {
  const url = location.origin + r.path;
  const box = h('input', { class: 'input mono', value: url, readonly: true, onclick: e => e.target.select() });
  box.style.width = '100%';
  note.replaceChildren(h('div', { class: 'card', style: 'margin-top:10px' },
    h('div', { class: 'muted', text: 'One-time reset link for ' + r.username + ' — copy it and send it to them. It expires in about an hour and works only once.' }),
    h('div', { class: 'form-row', style: 'margin-top:8px' }, box,
      h('button', { class: 'btn sm', style: 'flex:0 0 auto', onclick: () => {
        box.select();
        if (navigator.clipboard) navigator.clipboard.writeText(url).catch(() => {});
        else { try { document.execCommand('copy'); } catch (e) {} }
      } }, 'Copy'))));
}

// Node + allocations
async function renderNode() {
  const [node, allocs] = await Promise.all([jget('/api/admin/node'), jget('/api/admin/allocations')]);
  const nform = h('form', { class: 'form-row', onsubmit: async e => { e.preventDefault();
    try { await jsend('PUT', '/api/admin/node', { name: val(nform, 'name'), hostIp: val(nform, 'hostIp'), portRangeStart: num(nform, 's'), portRangeEnd: num(nform, 'e'), locationId: null }); nnote.replaceChildren(msg('Saved.', 'ok')); }
    catch (err) { nnote.replaceChildren(msg(String(err), 'err')); } } },
    field('Node name', input('name', { value: node.name })), field('Host IP', input('hostIp', { value: node.hostIp }), 'The IP allocations bind on the host.'),
    field('Port range start', input('s', { type: 'number', value: node.portRangeStart })), field('Port range end', input('e', { type: 'number', value: node.portRangeEnd })),
    h('div', { class: 'field', style: 'flex:0 0 auto;justify-content:flex-end' }, h('button', { class: 'btn', type: 'submit' }, 'Save node')));
  const nnote = h('div');
  const arows = allocs.map(a => h('tr', null,
    h('td', { class: 'mono', text: a.ip + ':' + a.port + '/' + a.proto }),
    h('td', null, a.serverName ? badge(a.serverName + (a.isPrimary ? ' (primary)' : ''), 'muted') : badge('free', 'good')),
    h('td', null, h('div', { class: 'rowact' }, !a.serverName && h('button', { class: 'btn ghost sm danger', onclick: async () => { try { await jsend('DELETE', '/api/admin/allocations/' + a.id); route(); } catch (e) { alert(e); } } }, 'Delete')))));
  const gnote = h('div');
  const gform = h('form', { class: 'form-row', onsubmit: async e => { e.preventDefault();
    try { const r = await jsend('POST', '/api/admin/allocations', { portStart: num(gform, 'gs'), portEnd: num(gform, 'ge'), ip: val(gform, 'gip'), proto: val(gform, 'gproto') }); gnote.replaceChildren(msg(r.created + ' allocation(s) added.', 'ok')); setTimeout(route, 500); }
    catch (err) { gnote.replaceChildren(msg(String(err), 'err')); } } },
    field('IP (blank = node IP)', input('gip')), field('From port', input('gs', { type: 'number', value: node.portRangeStart })), field('To port', input('ge', { type: 'number', value: node.portRangeEnd })),
    field('Protocol', select('gproto', [{ value: 'tcp', label: 'TCP' }, { value: 'udp', label: 'UDP' }, { value: 'both', label: 'TCP + UDP' }], 'tcp')),
    h('div', { class: 'field', style: 'flex:0 0 auto;justify-content:flex-end' }, h('button', { class: 'btn', type: 'submit' }, 'Generate')));
  show(pageHeader('Node', 'This machine — the single node'), card('Node configuration', nnote, nform),
    card('Generate allocations', gnote, gform), tableCard('Allocations', ['Binding', 'Assignment', ''], arows));
}

// Locations
async function renderLocations() {
  const locs = await jget('/api/admin/locations');
  const rows = locs.map(l => h('tr', null, h('td', { text: l.short }), h('td', { text: l.description || '—' }),
    h('td', null, h('div', { class: 'rowact' }, h('button', { class: 'btn ghost sm danger', onclick: async () => { try { await jsend('DELETE', '/api/admin/locations/' + l.id); route(); } catch (e) { alert(e); } } }, 'Delete')))));
  const note = h('div');
  const form = h('form', { class: 'form-row', onsubmit: async e => { e.preventDefault();
    try { await jsend('POST', '/api/admin/locations', { short: val(form, 'short'), description: val(form, 'description') }); route(); } catch (err) { note.replaceChildren(msg(String(err), 'err')); } } },
    field('Short code', input('short')), field('Description', input('description')),
    h('div', { class: 'field', style: 'flex:0 0 auto;justify-content:flex-end' }, h('button', { class: 'btn', type: 'submit' }, 'Add location')));
  show(pageHeader('Locations', 'Group nodes for easy categorization'), tableCard('Location list', ['Short code', 'Description', ''], rows), card('Add location', note, form));
}

// Servers
async function renderServers() {
  const servers = await jget('/api/admin/servers');
  const rows = servers.map(s => h('tr', null,
    h('td', null, h('div', { text: s.displayName || s.name }), s.displayName ? h('div', { class: 'mono', text: s.name }) : null),
    h('td', { class: 'mono', text: s.uuid.slice(0, 18) }), h('td', { class: 'mono', text: s.dockerImage }),
    h('td', null, statusBadge(s.status, s.running)),
    h('td', null, h('div', { class: 'rowact' },
      h('a', { class: 'btn ghost sm', href: '#servers/edit/' + enc(s.name) }, 'Edit'),
      s.status === 'suspended'
        ? h('button', { class: 'btn ghost sm', onclick: async () => { try { await jsend('POST', '/api/admin/servers/' + enc(s.name) + '/unsuspend'); route(); } catch (e) { alert(e); } } }, 'Unsuspend')
        : h('button', { class: 'btn ghost sm', onclick: async () => { if (!confirm('Suspend ' + s.name + '? It stops and becomes read-only for its owner.')) return; try { await jsend('POST', '/api/admin/servers/' + enc(s.name) + '/suspend'); route(); } catch (e) { alert(e); } } }, 'Suspend'),
      h('button', { class: 'btn ghost sm danger', onclick: async () => { if (!confirm('Delete server ' + s.name + ' and its data?')) return; try { await jsend('DELETE', '/api/admin/servers/' + enc(s.name)); route(); } catch (e) { alert(e); } } }, 'Delete')))));
  show(pageHeader('Servers', 'All servers on the panel', h('a', { class: 'btn', href: '#servers/new' }, 'Create new')),
    tableCard('Server list', ['Name', 'UUID', 'Image', 'Status', ''], rows));
}

// Create Server — one long form, matching Pterodactyl's create page.
async function renderCreateServer() {
  crumbEl.textContent = 'Admin › Servers › Create';
  const [nests, users, mounts] = await Promise.all([jget('/api/admin/nests'), jget('/api/admin/users'), jget('/api/admin/mounts')]);
  const eggsByNest = {};
  const note = h('div');
  const varsBox = h('div', null, h('div', { class: 'hint', text: 'Pick an egg to load its variables.' }));
  const imageBox = h('div');

  const nestSel = select('nest', [{ value: '', label: '— choose —' }, ...nests.map(n => ({ value: n.id, label: n.name }))], '');
  const eggSel = h('select', { name: 'egg' }, h('option', { value: '', text: '— choose a nest first —' }));

  nestSel.addEventListener('change', async () => {
    eggSel.replaceChildren(h('option', { value: '', text: '— choose —' }));
    varsBox.replaceChildren(); imageBox.replaceChildren();
    const nid = nestSel.value; if (!nid) return;
    const eggs = eggsByNest[nid] || (eggsByNest[nid] = await jget('/api/admin/eggs?nest=' + enc(nid)));
    eggs.forEach(e => eggSel.append(h('option', { value: e.id, text: e.name })));
  });
  eggSel.addEventListener('change', async () => { const id = eggSel.value; if (!id) return; await loadEgg(id); });

  async function loadEgg(id) {
    const egg = await jget('/api/admin/eggs/' + enc(id));
    imageBox.replaceChildren(field('Docker image', select('image', egg.images.map(i => ({ value: i.image, label: i.label + '  (' + i.image + ')' })), egg.images[0] && egg.images[0].image), 'The runtime image for this server.'));
    const shown = egg.variables.filter(v => v.userViewable);
    varsBox.replaceChildren(...(shown.length ? shown.map(v => field(
      v.name + (v.userEditable ? '' : ' (locked)'),
      h('input', { type: 'text', name: 'var:' + v.envVariable, value: v.defaultValue, disabled: !v.userEditable }),
      (v.description || '') + (v.rules.length ? '  ·  ' + v.rules.join(', ') : ''))) : [h('div', { class: 'hint', text: 'This egg has no configurable variables.' })]));
    if (!egg.hasInstallScript) varsBox.append(h('div', { class: 'hint', text: 'Note: this egg has no install script, so no server files will be downloaded.' }));
  }

  // Server name with a live "will be created as" preview (spaces & capitals
  // are converted to a valid stack id rather than rejected).
  const nameInput = input('name');
  const nameHint = h('div', { class: 'hint', text: 'Letters, numbers, spaces — capitals and spaces are converted.' });
  nameInput.addEventListener('input', () => {
    const s = slugify(nameInput.value);
    nameHint.textContent = s ? ('Will be created as: ' + s) : 'Needs at least one letter or number.';
  });
  const nameField = h('div', { class: 'field' }, h('label', null, 'Server name', h('span', { class: 'req', text: ' *' })), nameInput, nameHint);

  const form = h('form', { onsubmit: submit },
    h('fieldset', null, h('legend', { text: 'Core details' }),
      h('div', { class: 'form-row' }, nameField,
        field('Owner', select('owner', [{ value: '', label: '— none —' }, ...users.map(u => ({ value: u.id, label: u.username }))], ''), 'Gets full access to this server.'))),
    h('fieldset', null, h('legend', { text: 'Nest configuration' }),
      h('div', { class: 'form-row' }, field('Nest', nestSel, null, true), field('Egg', eggSel, null, true)), imageBox),
    h('fieldset', null, h('legend', { text: 'Allocation' }),
      h('div', { class: 'form-row' }, field('Additional allocations', input('extra', { type: 'number', value: 0 }), 'Extra ports beyond the primary.'))),
    h('fieldset', null, h('legend', { text: 'Resource limits (0 = unlimited)' }),
      h('div', { class: 'form-row' }, field('Memory (MiB)', input('mem', { type: 'number', value: 1024 })), field('Swap (MiB)', input('swap', { type: 'number', value: 0 }), '-1 = unlimited'),
        field('CPU (%)', input('cpu', { type: 'number', value: 0 }), '100 = one core')),
      h('div', { class: 'form-row' }, field('Disk (MiB)', input('disk', { type: 'number', value: 0 }), 'Not hard-enforced on macOS Docker — a soft target.'),
        field('CPU pinning', input('cpuset'), 'e.g. 0,1,3 — blank = all'), field('Block IO weight', input('io', { type: 'number' }), '10–1000, blank = default')),
      h('div', { class: 'form-row' }, field('PID limit', input('pids', { type: 'number' }), 'blank = default'),
        h('div', { class: 'field' }, h('label', { text: 'OOM killer' }), h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'oom' }), 'Kill on memory breach')))),
    mounts.length ? h('fieldset', null, h('legend', { text: 'Mounts' }),
      h('div', { class: 'hint' }, 'Attach admin-defined host mounts to this server.'),
      ...mounts.map(m => h('label', { class: 'check', style: 'margin:6px 0' },
        h('input', { type: 'checkbox', name: 'mount:' + m.id }),
        h('span', null, m.name, ' ', h('span', { class: 'mono', text: m.source + ' → ' + m.target + (m.readOnly ? ' (ro)' : '') }))))) : null,
    h('fieldset', null, h('legend', { text: 'Service variables' }), varsBox),
    h('div', { class: 'actions' }, h('button', { class: 'btn', type: 'submit' }, 'Create server'), h('a', { class: 'btn ghost', href: '#servers' }, 'Cancel')), note);

  async function submit(e) {
    e.preventDefault();
    const values = {};
    form.querySelectorAll('[name^="var:"]').forEach(el => { values[el.name.slice(4)] = el.value; });
    const mountIds = [];
    form.querySelectorAll('[name^="mount:"]:checked').forEach(el => mountIds.push(parseInt(el.name.slice(6), 10)));
    const body = {
      name: slugify(val(form, 'name')), eggId: parseInt(eggSel.value, 10) || 0,
      ownerUserId: form.querySelector('[name=owner]').value ? parseInt(form.querySelector('[name=owner]').value, 10) : null,
      image: form.querySelector('[name=image]') ? form.querySelector('[name=image]').value : null,
      memoryMiB: num(form, 'mem'), swapMiB: num(form, 'swap'), diskMiB: num(form, 'disk'), cpuPercent: num(form, 'cpu'),
      cpuPinning: val(form, 'cpuset') || null, ioWeight: val(form, 'io') ? num(form, 'io') : null, pidsLimit: val(form, 'pids') ? num(form, 'pids') : null,
      oomKillDisable: chk(form, 'oom'), additionalAllocations: num(form, 'extra'), values, mountIds,
    };
    if (!body.name) { note.replaceChildren(msg('A server name needs at least one letter or number.', 'err')); return; }
    if (!body.eggId) { note.replaceChildren(msg('Choose an egg to create from.', 'err')); return; }
    const term = h('div', { class: 'term' });
    const done = h('div');
    show(pageHeader('Creating ' + body.name), card('Install log', term), done);
    const append = line => {
      const cls = line.startsWith('✔') ? 'ok' : line.startsWith('✖') ? 'bad' : line.startsWith('»') ? 'step' : '';
      term.append(h('div', { class: cls, text: line })); term.scrollTop = term.scrollHeight;
    };
    try {
      await postStream('/api/admin/servers', body, append);
      done.replaceChildren(h('div', { class: 'actions', style: 'margin-top:14px' }, h('a', { class: 'btn', href: '#servers', onclick: () => setTimeout(route, 0) }, 'Back to servers')));
    } catch (err) { done.replaceChildren(msg(String(err), 'err'), h('a', { class: 'btn ghost', href: '#servers/new', onclick: () => setTimeout(route, 0) }, 'Try again')); }
  }
  show(pageHeader('Create server', 'Provision a new server from an egg'), card(null, form));
}

// Edit an existing server (limits / image / owner / variables + reinstall).
async function renderEditServer(name) {
  crumbEl.textContent = 'Admin › Servers › Edit';
  const [d, users] = await Promise.all([jget('/api/admin/servers/' + enc(name)), jget('/api/admin/users')]);
  const note = h('div');
  const shownVars = (d.variables || []).filter(v => v.userViewable);
  const form = h('form', { onsubmit: e => { e.preventDefault(); saveEdit(); } },
    h('fieldset', null, h('legend', { text: 'Core' }),
      h('div', { class: 'form-row' },
        field('Display name', input('displayName', { value: d.displayName || '' }), 'Identifier stays "' + d.name + '".'),
        field('Owner', select('owner', [{ value: '', label: '— none —' }, ...users.map(u => ({ value: u.id, label: u.username }))], d.ownerUserId || ''), 'Gets full access.'),
        d.images && d.images.length ? field('Docker image', select('image', d.images.map(i => ({ value: i.image, label: i.label })), d.dockerImage)) : field('Docker image', input('image', { value: d.dockerImage })))),
    h('fieldset', null, h('legend', { text: 'Resource limits (0 = unlimited)' }),
      h('div', { class: 'form-row' },
        field('Memory (MiB)', input('mem', { type: 'number', value: d.memoryMiB })),
        field('Swap (MiB)', input('swap', { type: 'number', value: d.swapMiB })),
        field('CPU (%)', input('cpu', { type: 'number', value: d.cpuPercent }))),
      h('div', { class: 'form-row' },
        field('Disk (MiB)', input('disk', { type: 'number', value: d.diskMiB }), 'Not hard-enforced on macOS Docker.'),
        field('CPU pinning', input('cpuset', { value: d.cpuPinning || '' })),
        field('Block IO weight', input('io', { type: 'number', value: d.ioWeight ?? '' }))),
      h('div', { class: 'form-row' },
        field('PID limit', input('pids', { type: 'number', value: d.pidsLimit ?? '' })),
        h('div', { class: 'field' }, h('label', { text: 'OOM killer' }), h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'oom', checked: d.oomKillDisable }), 'Kill on memory breach')))),
    shownVars.length ? h('fieldset', null, h('legend', { text: 'Service variables' }),
      ...shownVars.map(v => field(v.name + (v.userEditable ? '' : ' (locked)'), h('input', { type: 'text', name: 'var:' + v.envVariable, value: d.values[v.envVariable] ?? v.defaultValue, disabled: !v.userEditable }), (v.description || '') + (v.rules.length ? '  ·  ' + v.rules.join(', ') : '')))) : null,
    h('div', { class: 'actions' },
      h('button', { class: 'btn', type: 'submit' }, 'Save & apply'),
      h('button', { class: 'btn ghost', type: 'button', onclick: reinstall }, 'Reinstall'),
      h('a', { class: 'btn ghost', href: '#servers' }, 'Back')),
    note);

  function collect() {
    const values = {};
    form.querySelectorAll('[name^="var:"]').forEach(el => { if (!el.disabled) values[el.name.slice(4)] = el.value; });
    return {
      displayName: val(form, 'displayName') || null,
      ownerUserId: form.querySelector('[name=owner]').value ? parseInt(form.querySelector('[name=owner]').value, 10) : null,
      image: form.querySelector('[name=image]').value || null,
      memoryMiB: num(form, 'mem'), swapMiB: num(form, 'swap'), diskMiB: num(form, 'disk'), cpuPercent: num(form, 'cpu'),
      cpuPinning: val(form, 'cpuset') || null, ioWeight: val(form, 'io') ? num(form, 'io') : null,
      pidsLimit: val(form, 'pids') ? num(form, 'pids') : null, oomKillDisable: chk(form, 'oom'), values,
    };
  }
  function streamInto(promise, title) {
    const term = h('div', { class: 'term' });
    show(pageHeader(title + ' ' + name), card('Log', term), h('a', { class: 'btn', href: '#servers', onclick: () => setTimeout(route, 0) }, 'Back to servers'));
    const append = line => { const cls = line.startsWith('✔') ? 'ok' : line.startsWith('✖') ? 'bad' : line.startsWith('»') ? 'step' : ''; term.append(h('div', { class: cls, text: line })); term.scrollTop = term.scrollHeight; };
    promise(append).catch(err => append('✖ ' + err));
  }
  async function saveEdit() {
    streamInto(cb => postStream('/api/admin/servers/' + enc(name), collect(), cb, 'PUT'), 'Updating');
  }
  async function reinstall() {
    if (!confirm('Reinstall re-runs the egg install over the existing data and restarts the server. Continue?')) return;
    streamInto(cb => postStream('/api/admin/servers/' + enc(name) + '/reinstall', {}, cb), 'Reinstalling');
  }
  show(pageHeader('Edit server', d.name), card(null, form));
}

// Databases (per server)
async function renderDatabases() {
  const servers = await jget('/api/admin/servers');
  const sel = select('server', [{ value: '', label: '— choose a server —' }, ...servers.map(s => ({ value: s.name, label: s.name }))], '');
  const listBox = h('div');
  const load = async name => {
    if (!name) { listBox.replaceChildren(); return; }
    const dbs = await jget('/api/admin/servers/' + enc(name) + '/databases');
    const rows = dbs.map(d => h('tr', null, h('td', { text: d.name }), h('td', { class: 'mono', text: (d.host || '') + (d.port ? ':' + d.port : '') }), h('td', { text: d.username || '—' }),
      h('td', null, h('div', { class: 'rowact' }, h('button', { class: 'btn ghost sm danger', onclick: async () => { try { await jsend('DELETE', '/api/admin/databases/' + d.id); load(name); } catch (e) { alert(e); } } }, 'Delete')))));
    const form = h('form', { class: 'form-row', onsubmit: async e => { e.preventDefault(); try { await jsend('POST', '/api/admin/servers/' + enc(name) + '/databases', { name: val(form, 'dbname'), host: val(form, 'host') || null, port: val(form, 'port') ? num(form, 'port') : null, username: val(form, 'user') || null }); load(name); } catch (err) { alert(err); } } },
      field('Database name', input('dbname')), field('Host', input('host')), field('Port', input('port', { type: 'number' })), field('Username', input('user')),
      h('div', { class: 'field', style: 'flex:0 0 auto;justify-content:flex-end' }, h('button', { class: 'btn', type: 'submit' }, 'Add')));
    listBox.replaceChildren(tableCard('Databases · ' + name, ['Name', 'Host', 'User', ''], rows), card('Add database', form));
  };
  sel.addEventListener('change', () => load(sel.value));
  show(pageHeader('Databases', 'Connection bookkeeping for each server'),
    msg('These are records only — Macerodactyl does not create the database or credentials yet. Use them to note an existing database’s connection details for a server. Real provisioning is planned.', ''),
    card('Server', field('Server', sel)), listBox);
}

// Mounts
async function renderMounts() {
  const mounts = await jget('/api/admin/mounts');
  const rows = mounts.map(m => h('tr', null, h('td', { text: m.name }), h('td', { class: 'mono', text: m.source }), h('td', { class: 'mono', text: m.target }), h('td', null, m.readOnly ? badge('ro', 'muted') : badge('rw', 'good')),
    h('td', null, h('div', { class: 'rowact' }, h('button', { class: 'btn ghost sm danger', onclick: async () => { try { await jsend('DELETE', '/api/admin/mounts/' + m.id); route(); } catch (e) { alert(e); } } }, 'Delete')))));
  const note = h('div');
  const form = h('form', { class: 'form-row', onsubmit: async e => { e.preventDefault(); try { await jsend('POST', '/api/admin/mounts', { name: val(form, 'name'), source: val(form, 'source'), target: val(form, 'target'), readOnly: chk(form, 'ro'), description: val(form, 'desc') || null }); route(); } catch (err) { note.replaceChildren(msg(String(err), 'err')); } } },
    field('Name', input('name')), field('Host source path', input('source')), field('Container target path', input('target')),
    h('div', { class: 'field' }, h('label', { text: 'Mode' }), h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'ro' }), 'Read-only')),
    field('Description', input('desc')), h('div', { class: 'field', style: 'flex:0 0 auto;justify-content:flex-end' }, h('button', { class: 'btn', type: 'submit' }, 'Add mount')));
  show(pageHeader('Mounts', 'Extra host paths that can be attached to servers'), tableCard('Mounts', ['Name', 'Source', 'Target', 'Mode', ''], rows), card('Add mount', note, form));
}

// Nests & Eggs
async function renderNests() {
  const [nests, eggs] = await Promise.all([jget('/api/admin/nests'), jget('/api/admin/eggs')]);
  const nestName = {}; nests.forEach(n => nestName[n.id] = n.name);
  const nrows = nests.map(n => h('tr', null, h('td', { text: n.name }), h('td', { text: n.author || '—' }), h('td', { text: n.description || '—' }),
    h('td', null, h('div', { class: 'rowact' }, h('button', { class: 'btn ghost sm danger', onclick: async () => { if (!confirm('Delete nest ' + n.name + ' and its eggs?')) return; try { await jsend('DELETE', '/api/admin/nests/' + n.id); route(); } catch (e) { alert(e); } } }, 'Delete')))));
  const nnote = h('div');
  const nform = h('form', { class: 'form-row', onsubmit: async e => { e.preventDefault(); try { await jsend('POST', '/api/admin/nests', { name: val(nform, 'name'), author: val(nform, 'author') || null, description: val(nform, 'desc') || null }); route(); } catch (err) { nnote.replaceChildren(msg(String(err), 'err')); } } },
    field('Nest name', input('name')), field('Author', input('author')), field('Description', input('desc')),
    h('div', { class: 'field', style: 'flex:0 0 auto;justify-content:flex-end' }, h('button', { class: 'btn', type: 'submit' }, 'Add nest')));

  const erows = eggs.map(e => h('tr', null, h('td', { text: e.name }), h('td', { text: nestName[e.nestId] || e.nestId }), h('td', null, badge(e.metaVersion || '?', 'muted')),
    h('td', null, h('div', { class: 'rowact' }, h('a', { class: 'btn ghost sm', href: '/api/admin/eggs/' + e.id + '/export' }, 'Export'), h('button', { class: 'btn ghost sm danger', onclick: async () => { if (!confirm('Delete egg ' + e.name + '?')) return; try { await jsend('DELETE', '/api/admin/eggs/' + e.id); route(); } catch (err) { alert(err); } } }, 'Delete')))));

  const inote = h('div');
  const iform = h('form', { onsubmit: async e => { e.preventDefault();
    try { const r = await jsend('POST', '/api/admin/eggs/import', { nestId: iform.querySelector('[name=nestId]').value ? parseInt(iform.querySelector('[name=nestId]').value, 10) : null, nestName: val(iform, 'newNest') || null, json: iform.querySelector('[name=json]').value });
      inote.replaceChildren(msg('Imported "' + r.name + '"' + (r.warnings.length ? ' with ' + r.warnings.length + ' warning(s): ' + r.warnings.join('; ') : '.'), r.warnings.length ? 'err' : 'ok')); setTimeout(route, 900); }
    catch (err) { inote.replaceChildren(msg(String(err), 'err')); } } },
    h('div', { class: 'form-row' }, field('Into nest', select('nestId', [{ value: '', label: '— pick or name a new one —' }, ...nests.map(n => ({ value: n.id, label: n.name }))], '')), field('…or new nest name', input('newNest'))),
    field('Egg JSON', h('textarea', { name: 'json', placeholder: 'Paste a Pterodactyl egg export here' }), 'Paste the raw egg export JSON. Compatible with PTDL_v1 and v2.'),
    h('div', { class: 'actions' }, h('button', { class: 'btn', type: 'submit' }, 'Import egg')));

  show(pageHeader('Nests & Eggs', 'Egg definitions that servers are created from'),
    tableCard('Nests', ['Name', 'Author', 'Description', ''], nrows), card('Add nest', nnote, nform),
    tableCard('Eggs', ['Name', 'Nest', 'Version', ''], erows), card('Import egg', inote, iform));
}

// --- boot -------------------------------------------------------------------
document.getElementById('signout').onclick = async () => { await fetch('/logout', { method: 'POST', headers: CSRF }); location.href = '/login'; };
document.getElementById('menu').onclick = () => document.body.classList.toggle('nav-open');
window.addEventListener('hashchange', route);
(async () => { try { const me = await jget('/api/me'); if (!me.isAdmin) { location.href = '/me'; return; } } catch { location.href = '/login'; return; } try { const s = await jget('/api/admin/settings'); brandEl.textContent = s.companyName || 'Macerodactyl'; } catch {} route(); })();
