import Foundation
import MacerodactylKit

/// The panel's two pages for this phase: a login form and an identity page that
/// proves who you are and what you're scoped to — and nothing else. Phone-first
/// (390px), inline styles, no external assets.
enum PanelHTML {
    static func page(title: String, body: String) -> String {
        """
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>\(escape(title)) · Macerodactyl</title>
        <style>
          :root { color-scheme: light dark; --bg:#0e1116; --card:#171b22; --fg:#e6edf3; --muted:#9aa4b2; --accord:#2f81f7; --line:#2a2f37; }
          * { box-sizing: border-box; }
          body { margin:0; font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:var(--bg); color:var(--fg); }
          .wrap { max-width:430px; margin:0 auto; padding:28px 18px 60px; }
          h1 { font-size:20px; margin:0 0 4px; }
          .sub { color:var(--muted); margin:0 0 22px; }
          .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:18px; margin-bottom:14px; }
          label { display:block; font-size:13px; color:var(--muted); margin:12px 0 5px; }
          input { width:100%; padding:12px; font-size:16px; border:1px solid var(--line); border-radius:10px; background:#0d1117; color:var(--fg); }
          button { width:100%; margin-top:18px; padding:13px; font-size:16px; font-weight:600; border:0; border-radius:10px; background:var(--accord); color:#fff; }
          button:active { opacity:.85; }
          .err { color:#f85149; font-size:14px; min-height:20px; margin-top:10px; }
          .row { display:flex; justify-content:space-between; align-items:center; padding:9px 0; border-bottom:1px solid var(--line); }
          .row:last-child { border-bottom:0; }
          .perm { display:inline-block; font-size:12px; padding:2px 8px; border-radius:999px; margin-left:4px; }
          .on { background:rgba(47,129,247,.18); color:#7cb0ff; }
          .off { color:var(--muted); }
          .pill { font-size:12px; color:var(--muted); }
          .admin { background:rgba(63,185,80,.16); color:#59d06b; padding:2px 9px; border-radius:999px; font-size:12px; }
          a { color:var(--accord); }
        </style></head><body><div class="wrap">\(body)</div></body></html>
        """
    }

    static func login() -> String {
        page(title: "Sign in", body: """
        <h1>Macerodactyl</h1>
        <p class="sub">Sign in to the control panel.</p>
        <div class="card">
          <label for="u">Username</label>
          <input id="u" autocapitalize="none" autocomplete="username" autofocus>
          <label for="p">Password</label>
          <input id="p" type="password" autocomplete="current-password">
          <button id="go">Sign in</button>
          <div class="err" id="err"></div>
        </div>
        <script>
          const go = document.getElementById('go'), err = document.getElementById('err');
          async function submit() {
            err.textContent = '';
            go.disabled = true;
            try {
              const r = await fetch('/login', {
                method:'POST',
                headers:{'Content-Type':'application/json','X-Macerodactyl-CSRF':'1'},
                body: JSON.stringify({username:document.getElementById('u').value, password:document.getElementById('p').value})
              });
              if (r.ok) { location.href = '/me'; return; }
              const j = await r.json().catch(()=>({}));
              err.textContent = j.error || ('Error ' + r.status);
            } catch (e) { err.textContent = 'Network error'; }
            go.disabled = false;
          }
          go.addEventListener('click', submit);
          document.getElementById('p').addEventListener('keydown', e => { if (e.key==='Enter') submit(); });
        </script>
        """)
    }

    /// The phone-first single-page app: container list, detail with power/logs/
    /// console/files tabs. All data via the JSON/SSE APIs; scoping is enforced
    /// server-side, so the UI only ever shows what the APIs return.
    static func app() -> String {
        page(title: "Containers", body: appBody) + appScript
    }

    static func identity(user: PanelUser, grants: [String: ContainerGrant]) -> String {
        let header = """
        <h1>\(escape(user.username)) \(user.isAdmin ? "<span class=\"admin\">admin</span>" : "")</h1>
        <p class="sub">You are signed in. This is what the panel knows about you.</p>
        """

        let scopeCard: String
        if user.isAdmin {
            scopeCard = """
            <div class="card">
              <div class="pill">Scope</div>
              <div class="row"><span>All containers</span><span class="perm on">full access</span></div>
              <p class="sub" style="margin:10px 0 0">As an admin you can view, power, edit files, and use the console on every container.</p>
            </div>
            """
        } else if grants.isEmpty {
            scopeCard = """
            <div class="card">
              <div class="pill">Scope</div>
              <p class="sub" style="margin:8px 0 0">You haven't been granted access to any containers yet. An admin manages this from the desktop app.</p>
            </div>
            """
        } else {
            let rows = grants.sorted { $0.key < $1.key }.map { name, grant in
                """
                <div class="row"><span>\(escape(name))</span><span>\(perm("view", grant.view))\(perm("power", grant.power))\(perm("files", grant.files))\(perm("console", grant.console))</span></div>
                """
            }.joined()
            scopeCard = """
            <div class="card"><div class="pill">Containers you're scoped to</div>\(rows)</div>
            """
        }

        let logout = """
        <div class="card"><button id="out">Sign out</button></div>
        <script>
          document.getElementById('out').addEventListener('click', async () => {
            await fetch('/logout', {method:'POST', headers:{'X-Macerodactyl-CSRF':'1'}});
            location.href = '/login';
          });
        </script>
        """
        return page(title: user.username, body: header + scopeCard + logout)
    }

    private static func perm(_ label: String, _ on: Bool) -> String {
        "<span class=\"perm \(on ? "on" : "off")\">\(label)</span>"
    }

    // MARK: SPA

    static let appBody = """
    <style>
      .topbar { display:flex; align-items:center; justify-content:space-between; margin-bottom:14px; }
      .topbar h1 { font-size:18px; }
      .link { background:none; border:0; color:var(--accord); font-size:14px; padding:6px; }
      .clist { display:flex; flex-direction:column; gap:10px; }
      .citem { display:flex; align-items:center; gap:10px; width:100%; text-align:left; background:var(--card); border:1px solid var(--line); border-radius:12px; padding:14px; color:var(--fg); }
      .dot { width:10px; height:10px; border-radius:50%; flex:0 0 auto; }
      .dot.up { background:#3fb950; } .dot.down { background:#6e7681; } .dot.warn { background:#d29922; }
      .citem .meta { flex:1; min-width:0; }
      .citem .nm { font-weight:600; }
      .citem .st { font-size:12px; color:var(--muted); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      .badge { font-size:11px; color:var(--muted); border:1px solid var(--line); border-radius:999px; padding:1px 7px; }
      .tabbar { position:sticky; bottom:0; display:flex; background:var(--card); border-top:1px solid var(--line); margin:0 -18px -60px; padding:4px 6px calc(8px + env(safe-area-inset-bottom)); }
      .tabbar button { flex:1; background:none; border:0; color:var(--muted); font-size:11px; padding:8px 2px; border-radius:8px; }
      .tabbar button.sel { color:var(--accord); }
      .tabbar .ic { display:block; font-size:17px; }
      .pane { min-height:52vh; }
      .btnrow { display:flex; gap:8px; margin:14px 0; }
      .btn { flex:1; padding:12px; border:0; border-radius:10px; font-size:15px; font-weight:600; }
      .btn.start { background:rgba(63,185,80,.2); color:#59d06b; }
      .btn.stop { background:rgba(248,81,73,.16); color:#f85149; }
      .btn.restart { background:rgba(47,129,247,.18); color:#7cb0ff; }
      .btn:disabled { opacity:.4; }
      .kv { display:flex; justify-content:space-between; padding:8px 0; border-bottom:1px solid var(--line); font-size:14px; gap:12px; }
      .kv span:last-child { color:var(--muted); font-family:ui-monospace,monospace; text-align:right; word-break:break-all; }
      .term { background:#0a0d12; border:1px solid var(--line); border-radius:10px; padding:10px; height:46vh; overflow:auto; font:12px/1.45 ui-monospace,monospace; white-space:pre-wrap; word-break:break-word; }
      .cmdline { color:#7cb0ff; } .cerr { color:#f85149; }
      .quick { display:flex; gap:6px; overflow-x:auto; padding:8px 0; -webkit-overflow-scrolling:touch; }
      .quick button { flex:0 0 auto; background:var(--card); border:1px solid var(--line); color:var(--fg); border-radius:8px; padding:7px 11px; font:13px ui-monospace,monospace; }
      .inputbar { display:flex; gap:8px; padding-bottom:env(safe-area-inset-bottom); }
      .inputbar input { flex:1; font:14px ui-monospace,monospace; }
      .inputbar button { padding:0 16px; border:0; border-radius:10px; background:var(--accord); color:#fff; font-weight:600; }
      .crumb { display:flex; flex-wrap:wrap; gap:2px; align-items:center; font-size:13px; margin-bottom:8px; }
      .crumb button { background:none; border:0; color:var(--accord); padding:4px; }
      .sheet { position:fixed; inset:0; background:var(--bg); display:flex; flex-direction:column; padding:10px calc(10px + env(safe-area-inset-left)) 0; z-index:10; }
      .sheet header { display:flex; align-items:center; gap:8px; padding:6px 0; }
      .sheet .fp { flex:1; font:12px ui-monospace,monospace; color:var(--muted); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
      .sheet textarea { flex:1; width:100%; font:13px/1.5 ui-monospace,monospace; border:1px solid var(--line); border-radius:8px; background:#0a0d12; color:var(--fg); padding:10px; resize:none; }
      .acc { display:flex; gap:6px; overflow-x:auto; padding:8px 0 calc(8px + env(safe-area-inset-bottom)); }
      .acc button { flex:0 0 auto; background:var(--card); border:1px solid var(--line); color:var(--fg); border-radius:8px; padding:9px 12px; font:13px ui-monospace,monospace; min-width:44px; }
      .save { background:var(--accord)!important; color:#fff!important; border:0!important; font-weight:600; }
      .msg { color:var(--muted); font-size:14px; padding:14px 2px; }
      .msg.err { color:#f85149; }
      .dirty { color:var(--accord); }
    </style>
    <div class="topbar"><h1 id="title">Containers</h1><button class="link" id="signout">Sign out</button></div>
    <div id="view"></div>
    """

    static let appScript = """
    <script>
    const CSRF = {'X-Macerodactyl-CSRF':'1'};
    const view = document.getElementById('view'), title = document.getElementById('title');
    const esc = s => (s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    let logSource = null, current = null;

    function closeLogs(){ if(logSource){ logSource.close(); logSource = null; } }

    async function api(path, opts){
      const r = await fetch(path, Object.assign({headers:{}}, opts||{}));
      return r;
    }
    async function jget(path){ const r = await api(path); if(!r.ok) throw r; return r.json(); }

    document.getElementById('signout').onclick = async () => {
      await fetch('/logout',{method:'POST',headers:CSRF}); location.href='/login';
    };

    function dotClass(c){ if(!c.running) return 'down'; if(c.health==='unhealthy'||c.health==='starting') return 'warn'; return 'up'; }

    async function home(){
      closeLogs(); current = null; title.textContent = 'Containers';
      let list;
      try { list = await jget('/api/containers'); } catch(e){ view.innerHTML = '<div class="msg err">Could not load containers.</div>'; return; }
      if(!list.length){ view.innerHTML = '<div class="msg">No containers you can access.</div>'; return; }
      view.innerHTML = '<div class="clist">'+list.map(c =>
        '<button class="citem" onclick="detail(\\''+encodeURIComponent(c.name)+'\\')">'+
        '<span class="dot '+dotClass(c)+'"></span>'+
        '<span class="meta"><div class="nm">'+esc(c.name)+'</div><div class="st">'+esc(c.status)+'</div></span>'+
        (c.stack?'<span class="badge">'+esc(c.stack)+'</span>':'')+'</button>'
      ).join('')+'</div>';
    }

    let d = null, tab = 'overview';
    window.detail = async function(nameEnc){
      closeLogs();
      const name = decodeURIComponent(nameEnc);
      try { d = await jget('/api/containers/'+encodeURIComponent(name)); }
      catch(e){ view.innerHTML = '<div class="msg err">Unavailable.</div>'; return; }
      current = name; title.textContent = name; tab = 'overview';
      renderDetail();
    };

    function renderDetail(){
      const p = d.permissions;
      const tabs = [['overview','Overview','●'],['logs','Logs','≡'],['console','Console','⌘'],['files','Files','▤']];
      view.innerHTML =
        '<button class="link" onclick="home()">‹ All containers</button>'+
        '<div class="pane" id="pane"></div>'+
        '<div class="tabbar">'+tabs.map(t =>
          (t[0]==='console'&&!p.console)||(t[0]==='files'&&!(p.files&&d.filesAvailable)) ? '' :
          '<button class="'+(tab===t[0]?'sel':'')+'" onclick="setTab(\\''+t[0]+'\\')"><span class="ic">'+t[2]+'</span>'+t[1]+'</button>'
        ).join('')+'</div>';
      paint();
    }
    window.setTab = function(t){ closeLogs(); tab = t; document.querySelectorAll('.tabbar button').forEach(b=>b.classList.remove('sel')); renderDetail(); };

    function paint(){
      const pane = document.getElementById('pane'); const p = d.permissions;
      if(tab==='overview'){
        pane.innerHTML =
          (p.power?'<div class="btnrow">'+
            '<button class="btn start" '+(d.running?'disabled':'')+' onclick="power(\\'start\\')">Start</button>'+
            '<button class="btn stop" '+(d.running?'':'disabled')+' onclick="power(\\'stop\\')">Stop</button>'+
            '<button class="btn restart" '+(d.running?'':'disabled')+' onclick="power(\\'restart\\')">Restart</button></div>':'')+
          kv('Status',d.status)+kv('Image',d.image)+(d.ports?kv('Ports',d.ports):'')+(d.stack?kv('Stack',d.stack):'');
      } else if(tab==='logs'){ paintLogs(pane); }
      else if(tab==='console'){ paintConsole(pane); }
      else if(tab==='files'){ paintFiles(pane); }
    }
    const kv = (k,v)=>'<div class="kv"><span>'+esc(k)+'</span><span>'+esc(v)+'</span></div>';

    window.power = async function(action){
      if(!confirm(action+' '+current+'?')) return;
      const r = await fetch('/api/containers/'+encodeURIComponent(current)+'/power',{method:'POST',headers:Object.assign({'Content-Type':'application/json'},CSRF),body:JSON.stringify({action})});
      d = await jget('/api/containers/'+encodeURIComponent(current)); // refresh
      renderDetail();
      if(!r.ok){ alert('Action failed'); }
    };

    function paintLogs(pane){
      pane.innerHTML = '<div class="term" id="term"></div>';
      const term = document.getElementById('term');
      logSource = new EventSource('/api/containers/'+encodeURIComponent(current)+'/logs');
      logSource.onmessage = e => { const atBottom = term.scrollTop+term.clientHeight >= term.scrollHeight-30; term.textContent += e.data+'\\n'; if(atBottom) term.scrollTop = term.scrollHeight; };
      logSource.onerror = () => { /* browser will retry; closed on tab change */ };
    }

    let history = [];
    function paintConsole(pane){
      const mc = /mc|minecraft/i.test(current);
      const quicks = mc ? ['list','say hi','time set day','/'] : ['ls','ls -la','cat ','tail -n 50 ','|','/','~'];
      pane.innerHTML =
        '<div class="term" id="cterm"></div>'+
        '<div class="quick">'+quicks.map(q=>'<button onclick="qk(\\''+q.replace(/'/g,"\\\\'")+'\\')">'+esc(q)+'</button>').join('')+'</div>'+
        '<div class="inputbar"><input id="cin" placeholder="'+(mc?'server command':'shell command')+'" autocapitalize="off" autocorrect="off" spellcheck="false"><button onclick="runCmd()">Send</button></div>';
      const inp = document.getElementById('cin');
      inp.addEventListener('keydown', e => { if(e.key==='Enter') runCmd(); if(e.key==='ArrowUp'&&history.length){ inp.value = history[history.length-1]; } });
    }
    window.qk = function(t){ const inp=document.getElementById('cin'); inp.value += t; inp.focus(); };
    window.runCmd = async function(){
      const inp = document.getElementById('cin'), term = document.getElementById('cterm');
      const cmd = inp.value.trim(); if(!cmd) return; inp.value=''; history.push(cmd);
      term.innerHTML += '<div class="cmdline">$ '+esc(cmd)+'</div>';
      try {
        const r = await fetch('/api/containers/'+encodeURIComponent(current)+'/console',{method:'POST',headers:Object.assign({'Content-Type':'application/json'},CSRF),body:JSON.stringify({command:cmd})});
        const j = await r.json();
        term.innerHTML += '<div'+(j.isError?' class="cerr"':'')+'>'+esc(j.output||'')+'</div>';
      } catch(e){ term.innerHTML += '<div class="cerr">request failed</div>'; }
      term.scrollTop = term.scrollHeight;
    };

    let cwd = '';
    function paintFiles(pane){ listDir(pane, ''); }
    async function listDir(pane, path){
      cwd = path;
      let entries;
      try { entries = await jget('/api/containers/'+encodeURIComponent(current)+'/files?path='+encodeURIComponent(path)); }
      catch(e){ pane.innerHTML = '<div class="msg err">Cannot list folder.</div>'; return; }
      const parts = path? path.split('/') : [];
      let crumb = '<div class="crumb"><button onclick="cd(\\'\\')">/</button>';
      let acc = '';
      parts.forEach((seg,i)=>{ acc = parts.slice(0,i+1).join('/'); crumb += '<span>/</span><button onclick="cd(\\''+encodeURIComponent(acc)+'\\')">'+esc(seg)+'</button>'; });
      crumb += '</div>';
      pane.innerHTML = crumb + '<div class="clist">'+entries.map(en =>
        '<button class="citem" onclick="'+(en.isDirectory?'cd(\\''+encodeURIComponent(en.path)+'\\')':'openFile(\\''+encodeURIComponent(en.path)+'\\')')+'">'+
        '<span>'+(en.isDirectory?'📁':'📄')+'</span><span class="meta"><div class="nm">'+esc(en.name)+'</div></span>'+
        (en.isDirectory?'':'<span class="badge">'+en.size+' B</span>')+'</button>'
      ).join('')+'</div>';
    }
    window.cd = function(pathEnc){ listDir(document.getElementById('pane'), decodeURIComponent(pathEnc)); };

    window.openFile = async function(pathEnc){
      const path = decodeURIComponent(pathEnc);
      let content;
      try { content = await jget('/api/containers/'+encodeURIComponent(current)+'/files/content?path='+encodeURIComponent(path)); }
      catch(e){ const j = await e.json().catch(()=>({error:'Cannot open'})); alert(j.error||'Cannot open file'); return; }
      openEditor(path, content.text, content.lineEnding);
    };

    function openEditor(path, text, lineEnding){
      const sheet = document.createElement('div'); sheet.className='sheet';
      sheet.innerHTML =
        '<header><button class="link" id="cls">Close</button><span class="fp"><span id="dirty"></span>'+esc(path)+'</span><button class="link save" id="sv">Save</button></header>'+
        '<textarea id="ed" spellcheck="false" autocapitalize="off" autocorrect="off"></textarea>'+
        '<div class="acc">'+
          '<button data-k="tab">Tab</button><button data-k="in">⇥+</button><button data-k="out">⇤-</button>'+
          '<button data-k="home">Home</button><button data-k="end">End</button><button data-k="find">Find</button>'+
        '</div>';
      document.body.appendChild(sheet);
      const ed = sheet.querySelector('#ed'); ed.value = text; const orig = text;
      const dirty = sheet.querySelector('#dirty');
      ed.addEventListener('input', ()=>{ dirty.textContent = ed.value!==orig ? '● ' : ''; dirty.className='dirty'; });
      sheet.querySelector('#cls').onclick = ()=>{ if(ed.value!==orig && !confirm('Discard changes?')) return; sheet.remove(); };
      sheet.querySelector('#sv').onclick = async ()=>{
        const r = await fetch('/api/containers/'+encodeURIComponent(current)+'/files/content?path='+encodeURIComponent(path),
          {method:'PUT',headers:Object.assign({'Content-Type':'application/json'},CSRF),body:JSON.stringify({text:ed.value,lineEnding})});
        if(r.ok){ dirty.textContent=''; sheet.querySelector('.fp').insertAdjacentHTML('afterbegin',''); }
        else { const j = await r.json().catch(()=>({error:'Save failed'})); alert(j.error||'Save failed'); }
      };
      sheet.querySelectorAll('.acc button').forEach(b => b.onclick = ()=>accKey(ed, b.dataset.k));
    }
    function accKey(ed, k){
      const s = ed.selectionStart, e = ed.selectionEnd, v = ed.value;
      const setSel=(a,b)=>{ ed.focus(); ed.setSelectionRange(a,b); };
      if(k==='tab'){ ed.value = v.slice(0,s)+'  '+v.slice(e); setSel(s+2,s+2); ed.dispatchEvent(new Event('input')); }
      else if(k==='home'){ const ls = v.lastIndexOf('\\n',s-1)+1; setSel(ls,ls); }
      else if(k==='end'){ let le = v.indexOf('\\n',s); if(le<0) le=v.length; setSel(le,le); }
      else if(k==='in'||k==='out'){ // indent/dedent current line(s)
        const ls = v.lastIndexOf('\\n',s-1)+1; let le = v.indexOf('\\n',e); if(le<0) le=v.length;
        const seg = v.slice(ls,le); const out = seg.split('\\n').map(l => k==='in' ? '  '+l : l.replace(/^  /,'')).join('\\n');
        ed.value = v.slice(0,ls)+out+v.slice(le); setSel(ls,ls+out.length); ed.dispatchEvent(new Event('input'));
      } else if(k==='find'){ const q = prompt('Find'); if(q){ const i = v.indexOf(q, e); if(i>=0) setSel(i,i+q.length); else alert('Not found'); } }
    }

    // Tear the log stream down if the page is hidden or unloaded (phone
    // backgrounds the browser or navigates away) so no docker logs process
    // is left running server-side.
    document.addEventListener('visibilitychange', ()=>{ if(document.hidden) closeLogs(); else if(tab==='logs'&&current) paint(); });
    window.addEventListener('pagehide', closeLogs);

    home();
    </script>
    """

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
