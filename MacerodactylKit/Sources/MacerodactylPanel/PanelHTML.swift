import Foundation
import MacerodactylKit

/// The web panel: a login page and a phone-first single-page app modeled on
/// Pterodactyl's information architecture — a stack-grouped container list, and
/// a container view whose persistent sidebar becomes a bottom bar (thumb zone)
/// with Console/Overview/Logs/Files/Schedules. Live stat cards stream over SSE.
/// No external assets; readable in light and dark; one-handed at 390px.
enum PanelHTML {
    // MARK: Login

    static func login() -> String {
        """
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>Sign in · Macerodactyl</title>
        <style>\(loginCSS)</style></head><body>
        <div class="wrap">
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
        </div>
        <script>
          const go = document.getElementById('go'), err = document.getElementById('err');
          async function submit() {
            err.textContent = ''; go.disabled = true;
            try {
              const r = await fetch('/login', { method:'POST',
                headers:{'Content-Type':'application/json','X-Macerodactyl-CSRF':'1'},
                body: JSON.stringify({username:document.getElementById('u').value, password:document.getElementById('p').value})});
              if (r.ok) { location.href = '/me'; return; }
              const j = await r.json().catch(()=>({})); err.textContent = j.error || ('Error ' + r.status);
            } catch (e) { err.textContent = 'Network error'; }
            go.disabled = false;
          }
          go.addEventListener('click', submit);
          document.getElementById('p').addEventListener('keydown', e => { if (e.key==='Enter') submit(); });
        </script></body></html>
        """
    }

    static let loginCSS = """
    \(tokens)
    * { box-sizing: border-box; }
    body { margin:0; font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:var(--bg); color:var(--fg); }
    .wrap { max-width:430px; margin:0 auto; padding:34px 18px; }
    h1 { font-size:22px; margin:0 0 4px; }
    .sub { color:var(--muted); margin:0 0 22px; }
    .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:18px; }
    label { display:block; font-size:13px; color:var(--muted); margin:12px 0 5px; }
    input { width:100%; padding:12px; font-size:16px; border:1px solid var(--line); border-radius:10px; background:var(--input); color:var(--fg); }
    button { width:100%; margin-top:18px; padding:14px; font-size:16px; font-weight:600; border:0; border-radius:10px; background:var(--accent); color:#fff; min-height:44px; }
    button:active { opacity:.85; }
    :focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
    .err { color:var(--red); font-size:14px; min-height:20px; margin-top:10px; }
    """

    /// Semantic tokens, defined for both appearances so contrast holds in each.
    static let tokens = """
    :root {
      color-scheme: light dark;
      --bg:#f5f6f8; --card:#ffffff; --fg:#1a1d21; --muted:#5b6673; --line:#e3e6ea;
      --input:#ffffff; --accent:#2f6fed; --green:#1f9d55; --red:#d13b3b; --amber:#c67c1a;
      --termbg:#0d1117; --termfg:#e6edf3;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg:#0e1116; --card:#171b22; --fg:#e6edf3; --muted:#9aa4b2; --line:#2a2f37;
        --input:#0d1117; --accent:#4c8dff; --green:#3fb950; --red:#f85149; --amber:#d29922;
        --termbg:#0a0d12; --termfg:#e6edf3;
      }
    }
    """

    // MARK: App shell

    static func app() -> String {
        """
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>Containers · Macerodactyl</title>
        <style>\(appCSS)</style></head><body>
        <header class="top"><button class="icon" id="back" hidden aria-label="Back to containers">‹</button>
          <div class="title" id="title">Containers</div>
          <button class="icon" id="signout" aria-label="Sign out">⏻</button></header>
        <main id="view"></main>
        <nav class="tabbar" id="tabbar" hidden></nav>
        <script>\(appJS)</script></body></html>
        """
    }

    static let appCSS = """
    \(tokens)
    * { box-sizing:border-box; }
    body { margin:0; font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:var(--bg); color:var(--fg); -webkit-text-size-adjust:100%; }
    :focus-visible { outline:2px solid var(--accent); outline-offset:2px; border-radius:4px; }
    .top { position:sticky; top:0; z-index:5; display:flex; align-items:center; gap:8px;
      padding:calc(8px + env(safe-area-inset-top)) 14px 8px; background:var(--card); border-bottom:1px solid var(--line); }
    .top .title { flex:1; font-weight:600; font-size:17px; text-align:center; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .icon { width:40px; height:40px; border:0; background:none; color:var(--accent); font-size:22px; border-radius:10px; }
    main { max-width:520px; margin:0 auto; padding:14px 14px 96px; }
    h2 { font-size:15px; color:var(--muted); font-weight:600; margin:18px 2px 8px; }
    .msg { color:var(--muted); padding:16px 2px; }
    .msg.err { color:var(--red); }
    /* container cards (landing) */
    .clist { display:flex; flex-direction:column; gap:10px; }
    .citem { display:flex; align-items:center; gap:11px; width:100%; text-align:left; background:var(--card);
      border:1px solid var(--line); border-radius:13px; padding:14px; color:var(--fg); min-height:44px; }
    .dot { width:10px; height:10px; border-radius:50%; flex:0 0 auto; }
    .dot.up{background:var(--green);} .dot.down{background:var(--red);} .dot.warn{background:var(--amber);}
    .citem .meta { flex:1; min-width:0; } .citem .nm { font-weight:600; }
    .citem .st { font-size:13px; color:var(--muted); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .citem .use { text-align:right; font-size:13px; color:var(--muted); font-variant-numeric:tabular-nums; }
    /* stat strip — the memorable element */
    .stats { display:grid; grid-template-columns:repeat(2,1fr); gap:8px; margin:4px 0 14px; }
    @media (min-width:460px){ .stats{ grid-template-columns:repeat(4,1fr);} }
    .stat { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:11px 12px; position:relative; overflow:hidden; }
    .stat::before { content:""; position:absolute; left:0; top:10px; bottom:10px; width:3px; border-radius:2px; background:var(--accent); }
    .stat.cpu::before{background:#4c8dff;} .stat.mem::before{background:#a371f7;} .stat.net::before{background:#2bb6a3;} .stat.up::before{background:var(--green);}
    .stat .k { font-size:12px; color:var(--muted); margin-left:8px; }
    .stat .v { font-size:20px; font-weight:600; font-variant-numeric:tabular-nums; margin-left:8px; }
    .stat .s { font-size:12px; color:var(--muted); margin-left:8px; }
    .stat.na .v { color:var(--muted); font-size:15px; font-weight:500; }
    /* power buttons */
    .power { display:flex; gap:8px; margin-bottom:12px; flex-wrap:wrap; }
    .power button { flex:1; min-width:72px; min-height:46px; border:1px solid var(--line); border-radius:11px; font-weight:600; font-size:15px; background:var(--card); color:var(--fg); }
    .power .start{color:var(--green);} .power .stop{color:var(--fg);} .power .restart{color:var(--accent);}
    .power .kill{ color:#fff; background:var(--red); border-color:var(--red); flex:0 0 auto; padding:0 16px; }
    .power button:disabled{opacity:.4;}
    /* terminal / logs */
    .term { background:var(--termbg); color:var(--termfg); border:1px solid var(--line); border-radius:11px; padding:11px;
      height:46vh; overflow:auto; font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; white-space:pre-wrap; word-break:break-word; }
    .cmdline{color:#7cb0ff;} .cerr{color:var(--red);}
    .toolrow { display:flex; gap:8px; align-items:center; margin:8px 0; flex-wrap:wrap; }
    .toolrow label{display:flex; align-items:center; gap:5px; font-size:13px; color:var(--muted);}
    .quick { display:flex; gap:6px; overflow-x:auto; padding:8px 0; }
    .quick button { flex:0 0 auto; background:var(--card); border:1px solid var(--line); color:var(--fg); border-radius:9px; padding:9px 12px; font:13px ui-monospace,monospace; min-height:40px; }
    .inputbar { display:flex; gap:8px; }
    .inputbar input { flex:1; font:14px ui-monospace,monospace; padding:12px; border:1px solid var(--line); border-radius:10px; background:var(--input); color:var(--fg); }
    .inputbar button { padding:0 18px; border:0; border-radius:10px; background:var(--accent); color:#fff; font-weight:600; min-height:44px; }
    /* meta */
    .kv{display:flex; justify-content:space-between; gap:12px; padding:9px 0; border-bottom:1px solid var(--line); font-size:14px;}
    .kv:last-child{border-bottom:0;} .kv .kk{color:var(--muted);} .kv .vv{font-family:ui-monospace,monospace; text-align:right; word-break:break-all;}
    /* files */
    .crumb{display:flex; flex-wrap:wrap; gap:2px; align-items:center; margin-bottom:8px; font-size:14px;}
    .crumb button{background:none; border:0; color:var(--accent); padding:6px 4px; min-height:36px;}
    /* schedule */
    .field{display:flex; gap:8px; align-items:center; margin:10px 0; flex-wrap:wrap;}
    .field select, .field input{padding:10px; border:1px solid var(--line); border-radius:9px; background:var(--input); color:var(--fg); font-size:16px; min-height:44px;}
    .days{display:flex; gap:5px; flex-wrap:wrap;}
    .days button{border:1px solid var(--line); background:var(--card); color:var(--fg); border-radius:8px; padding:8px 10px; min-height:40px; font-size:13px;}
    .days button.on{background:var(--accent); color:#fff; border-color:var(--accent);}
    .primary{background:var(--accent); color:#fff; border:0; border-radius:11px; padding:13px; font-weight:600; width:100%; min-height:46px; margin-top:8px;}
    .danger{background:none; color:var(--red); border:1px solid var(--red); border-radius:11px; padding:12px; font-weight:600; width:100%; min-height:46px; margin-top:8px;}
    .note{font-size:13px; color:var(--muted); margin-top:8px;}
    .fail{color:var(--red);} .okrun{color:var(--muted);} .timeout{color:var(--amber);}
    /* bottom bar (the per-container sidebar, as a thumb-zone bar) */
    .tabbar { position:fixed; left:0; right:0; bottom:0; z-index:5; display:flex; background:var(--card); border-top:1px solid var(--line);
      padding:4px 4px calc(4px + env(safe-area-inset-bottom)); }
    .tabbar button { flex:1; background:none; border:0; color:var(--muted); font-size:11px; padding:7px 2px 5px; border-radius:9px; min-height:48px; }
    .tabbar button.sel { color:var(--accent); }
    .tabbar .ic { display:block; font-size:19px; line-height:1.1; }
    /* editor sheet */
    .sheet{position:fixed; inset:0; z-index:20; background:var(--bg); display:flex; flex-direction:column; padding:calc(8px + env(safe-area-inset-top)) 10px 0;}
    .sheet header{display:flex; align-items:center; gap:8px; padding:4px 0;}
    .sheet .fp{flex:1; font:12px ui-monospace,monospace; color:var(--muted); overflow:hidden; text-overflow:ellipsis; white-space:nowrap;}
    .sheet .lnk{background:none; border:0; color:var(--accent); font-size:15px; min-height:40px; padding:0 6px;}
    .sheet .save{color:#fff; background:var(--accent); border-radius:8px; padding:0 14px; font-weight:600;}
    .sheet textarea{flex:1; width:100%; font:13px/1.5 ui-monospace,monospace; border:1px solid var(--line); border-radius:9px; background:var(--termbg); color:var(--termfg); padding:10px; resize:none;}
    .acc{display:flex; gap:6px; overflow-x:auto; padding:8px 0 calc(8px + env(safe-area-inset-bottom));}
    .acc button{flex:0 0 auto; background:var(--card); border:1px solid var(--line); color:var(--fg); border-radius:9px; padding:10px 13px; font:14px ui-monospace,monospace; min-width:46px; min-height:44px;}
    @media (prefers-reduced-motion: reduce) { * { transition:none !important; animation:none !important; scroll-behavior:auto !important; } }
    """

    static let appJS = #"""
    const CSRF={'X-Macerodactyl-CSRF':'1'};
    const view=document.getElementById('view'), titleEl=document.getElementById('title');
    const backBtn=document.getElementById('back'), tabbar=document.getElementById('tabbar');
    const esc=s=>(s==null?'':(''+s)).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    const bytes=n=>{ if(n==null)return '—'; const u=['B','KB','MB','GB','TB']; let i=0,v=n; while(v>=1024&&i<u.length-1){v/=1024;i++;} return (v>=100||i===0?Math.round(v):v.toFixed(1))+' '+u[i]; };

    let statSrc=null, logSrc=null, landingTimer=null, current=null, detail=null, tab='console';
    function closeStreams(){ if(statSrc){statSrc.close();statSrc=null;} if(logSrc){logSrc.close();logSrc=null;} }
    function stopLanding(){ if(landingTimer){clearInterval(landingTimer); landingTimer=null;} }
    async function jget(p){ const r=await fetch(p); if(!r.ok) throw r; return r.json(); }

    document.getElementById('signout').onclick=async()=>{ await fetch('/logout',{method:'POST',headers:CSRF}); location.href='/login'; };
    backBtn.onclick=()=>showHome();
    // Tear everything down when the tab is hidden (phone backgrounds Safari) or
    // unloaded — no docker logs/stats keeps running server-side for a lost tab.
    document.addEventListener('visibilitychange',()=>{ if(document.hidden){ closeStreams(); stopLanding(); } else { if(current) openContainerStreams(); else if(isHome) startLanding(); } });
    window.addEventListener('pagehide',()=>{ closeStreams(); stopLanding(); });

    let isHome=true;
    async function showHome(){
      closeStreams(); current=null; detail=null; isHome=true;
      titleEl.textContent='Containers'; backBtn.hidden=true; tabbar.hidden=true;
      let list; try{ list=await jget('/api/containers'); }catch(e){ view.innerHTML='<p class="msg err">Could not load containers.</p>'; return; }
      if(!list.length){ view.innerHTML='<p class="msg">No containers you can access.</p>'; return; }
      const byStack={}; const loose=[];
      list.forEach(c=>{ if(c.stack){ (byStack[c.stack]=byStack[c.stack]||[]).push(c);} else loose.push(c); });
      let html='';
      Object.keys(byStack).sort().forEach(s=>{ html+='<h2>'+esc(s)+'</h2>'+cards(byStack[s]); });
      if(loose.length) html+='<h2>Unmanaged</h2>'+cards(loose);
      view.innerHTML=html;
      startLanding();
    }
    function cards(cs){ return '<div class="clist">'+cs.map(c=>{
      const cls=!c.running?'down':(c.health==='unhealthy'||c.health==='starting'?'warn':'up');
      const addr=c.state==='running'?(c.image):(c.status);
      return '<button class="citem" onclick="enter(\''+encodeURIComponent(c.name)+'\')">'
        +'<span class="dot '+cls+'"></span><span class="meta"><div class="nm">'+esc(c.name)+'</div>'
        +'<div class="st">'+esc(addr)+'</div></span><span class="use" data-c="'+esc(c.name)+'">'+(c.running?'…':'—')+'</span></button>';
    }).join('')+'</div>'; }
    function startLanding(){ stopLanding(); pollStats(); landingTimer=setInterval(pollStats,5000); }
    async function pollStats(){
      let stats; try{ stats=await jget('/api/stats'); }catch(e){ return; }
      const map={}; stats.forEach(s=>map[s.name]=s);
      document.querySelectorAll('.use[data-c]').forEach(el=>{ const s=map[el.dataset.c]; el.textContent=s?(s.cpuPercent.toFixed(1)+'%  '+bytes(s.memUsedBytes)):'—'; });
    }

    window.enter=async function(enc){
      stopLanding(); const name=decodeURIComponent(enc);
      try{ detail=await jget('/api/containers/'+encodeURIComponent(name)); }catch(e){ view.innerHTML='<p class="msg err">Unavailable.</p>'; return; }
      current=name; isHome=false; titleEl.textContent=name; backBtn.hidden=false;
      const p=detail.permissions; const tabs=[];
      tabs.push(['console','Console','⌘', p.console]);
      tabs.push(['overview','Overview','ⓘ', true]);
      tabs.push(['logs','Logs','≣', true]);
      if(p.files && detail.filesAvailable) tabs.push(['files','Files','▤', true]);
      if(p.schedules) tabs.push(['schedules','Schedules','⏱', true]);
      tabbar.hidden=false;
      tabbar.innerHTML=tabs.filter(t=>t[3]).map(t=>'<button data-t="'+t[0]+'" onclick="setTab(\''+t[0]+'\')"><span class="ic">'+t[2]+'</span>'+t[1]+'</button>').join('');
      tab = p.console?'console':'overview';
      openContainerStreams();
      render();
    };
    // The stat stream stays open for the whole container view — so on the Logs
    // tab it runs alongside the log stream (two streams), and both are closed
    // together by closeStreams() on leave/hide.
    function openContainerStreams(){
      if(!current) return;
      if(statSrc) statSrc.close();
      statSrc=new EventSource('/api/containers/'+encodeURIComponent(current)+'/stats');
      statSrc.onmessage=e=>{ try{ paintStats(JSON.parse(e.data)); }catch(_){} };
    }
    let lastStats=null;
    function paintStats(s){ lastStats=s.unavailable?null:s; const el=document.getElementById('statstrip'); if(el) el.outerHTML=statStrip(); }
    function statStrip(){
      const s=lastStats;
      const cell=(cls,k,v,sub)=>'<div class="stat '+cls+(v==null?' na':'')+'"><div class="k">'+k+'</div><div class="v">'+(v==null?'—':v)+'</div>'+(sub?'<div class="s">'+sub+'</div>':'')+'</div>';
      return '<div class="stats" id="statstrip">'
        +cell('cpu','CPU', s?s.cpuPercent.toFixed(1)+'%':null)
        +cell('mem','Memory', s?bytes(s.memUsedBytes):null, s?'of '+bytes(s.memLimitBytes):'')
        +cell('net','Network', s?'↓ '+bytes(s.netRxBytes):null, s?'↑ '+bytes(s.netTxBytes):'')
        +cell('up','PIDs', s?(''+s.pids):null)+'</div>';
    }

    window.setTab=function(t){ if(logSrc){logSrc.close(); logSrc=null;} tab=t; render(); };
    function render(){
      document.querySelectorAll('.tabbar button').forEach(b=>b.classList.toggle('sel', b.dataset.t===tab));
      let body=statStrip();
      if(tab==='console') body+=consoleTab();
      else if(tab==='overview') body+=overviewTab();
      else if(tab==='logs') body+=logsTab();
      else if(tab==='files') body+='<div id="files"></div>';
      else if(tab==='schedules') body+='<div id="sched">Loading…</div>';
      view.innerHTML=body; view.scrollTop=0;
      if(tab==='logs') startLogs();
      if(tab==='console') bindConsole();
      if(tab==='files') listDir('');
      if(tab==='schedules') loadSchedule();
    }

    function powerRow(){ const r=detail.running, p=detail.permissions;
      if(!p.power) return '';
      return '<div class="power">'
        +'<button class="start" '+(r?'disabled':'')+' onclick="power(\'start\')">Start</button>'
        +'<button class="restart" '+(r?'':'disabled')+' onclick="power(\'restart\')">Restart</button>'
        +'<button class="stop" '+(r?'':'disabled')+' onclick="power(\'stop\')">Stop</button>'
        +'<button class="kill" '+(r?'':'disabled')+' onclick="killC()">Kill</button></div>';
    }
    window.power=async function(a){ if(!confirm(a+' '+current+'?'))return; await doPower(a); };
    window.killC=async function(){ if(!confirm('Kill '+current+'? SIGKILL is immediate — no clean shutdown. Use Stop for graceful.'))return; await doPower('kill'); };
    async function doPower(a){ const r=await fetch('/api/containers/'+encodeURIComponent(current)+'/power',{method:'POST',headers:Object.assign({'Content-Type':'application/json'},CSRF),body:JSON.stringify({action:a})});
      detail=await jget('/api/containers/'+encodeURIComponent(current)); openContainerStreams(); render(); if(!r.ok) alert('Action failed'); }

    function consoleTab(){ const mc=/mc|minecraft/i.test(current);
      const quick=mc?['list','say hi','time set day']:['ls','ls -la','cat ','tail -n 50 ','|'];
      return powerRow()+'<div class="term" id="cterm"></div>'
        +'<div class="quick">'+quick.map(q=>'<button onclick="qk(\''+q.replace(/'/g,"\\'")+'\')">'+esc(q)+'</button>').join('')+'</div>'
        +'<div class="inputbar"><input id="cin" placeholder="'+(mc?'server command':'shell command')+'" autocapitalize="off" autocorrect="off" spellcheck="false"><button onclick="runCmd()">Send</button></div>';
    }
    let history=[];
    function bindConsole(){ const inp=document.getElementById('cin'); if(inp) inp.addEventListener('keydown',e=>{ if(e.key==='Enter')runCmd(); if(e.key==='ArrowUp'&&history.length)inp.value=history[history.length-1]; }); }
    window.qk=function(t){ const i=document.getElementById('cin'); i.value+=t; i.focus(); };
    window.runCmd=async function(){ const inp=document.getElementById('cin'), term=document.getElementById('cterm'); const cmd=inp.value.trim(); if(!cmd)return; inp.value=''; history.push(cmd);
      term.innerHTML+='<div class="cmdline">$ '+esc(cmd)+'</div>';
      try{ const r=await fetch('/api/containers/'+encodeURIComponent(current)+'/console',{method:'POST',headers:Object.assign({'Content-Type':'application/json'},CSRF),body:JSON.stringify({command:cmd})}); const j=await r.json(); term.innerHTML+='<div'+(j.isError?' class="cerr"':'')+'>'+esc(j.output||'')+'</div>'; }
      catch(e){ term.innerHTML+='<div class="cerr">request failed</div>'; } term.scrollTop=term.scrollHeight; };

    let follow=true;
    function logsTab(){ return '<div class="toolrow"><label><input type="checkbox" id="fol" checked onchange="follow=this.checked"> Follow</label></div><div class="term" id="lterm"></div>'; }
    function startLogs(){ const term=document.getElementById('lterm'); if(logSrc)logSrc.close();
      logSrc=new EventSource('/api/containers/'+encodeURIComponent(current)+'/logs');
      logSrc.onmessage=e=>{ const at=term.scrollTop+term.clientHeight>=term.scrollHeight-30; term.textContent+=e.data+'\n'; if(follow&&at)term.scrollTop=term.scrollHeight; }; }

    function overviewTab(){ const d=detail;
      const kv=(k,v)=>'<div class="kv"><span class="kk">'+k+'</span><span class="vv">'+esc(v)+'</span></div>';
      return kv('Status',d.status)+kv('Image',d.image)+(d.ports?kv('Ports',d.ports):'')+(d.stack?kv('Stack',d.stack):''); }

    /* Files */
    async function listDir(path){ const host=document.getElementById('files'); let entries;
      try{ entries=await jget('/api/containers/'+encodeURIComponent(current)+'/files?path='+encodeURIComponent(path)); }
      catch(e){ host.innerHTML='<p class="msg err">Cannot list folder.</p>'; return; }
      const parts=path?path.split('/'):[]; let crumb='<div class="crumb"><button onclick="cd(\'\')">/</button>'; let acc='';
      parts.forEach((seg,i)=>{ acc=parts.slice(0,i+1).join('/'); crumb+='<span>/</span><button onclick="cd(\''+encodeURIComponent(acc)+'\')">'+esc(seg)+'</button>'; });
      crumb+='</div>';
      host.innerHTML=crumb+'<div class="clist">'+entries.map(en=>'<button class="citem" onclick="'+(en.isDirectory?'cd(\''+encodeURIComponent(en.path)+'\')':'openFile(\''+encodeURIComponent(en.path)+'\')')+'"><span>'+(en.isDirectory?'📁':'📄')+'</span><span class="meta"><div class="nm">'+esc(en.name)+'</div></span><span class="use">'+(en.isDirectory?'':bytes(en.size))+'</span></button>').join('')+'</div>'; }
    window.cd=(e)=>listDir(decodeURIComponent(e));
    window.openFile=async function(enc){ const path=decodeURIComponent(enc); let c;
      try{ c=await jget('/api/containers/'+encodeURIComponent(current)+'/files/content?path='+encodeURIComponent(path)); }
      catch(e){ const j=await e.json().catch(()=>({error:'Cannot open'})); alert(j.error||'Cannot open'); return; }
      editor(path,c.text,c.lineEnding); };
    function editor(path,text,le){ const sh=document.createElement('div'); sh.className='sheet';
      sh.innerHTML='<header><button class="lnk" id="cl">Close</button><span class="fp"><span id="dt"></span>'+esc(path)+'</span><button class="lnk save" id="sv">Save</button></header><textarea id="ed" spellcheck="false" autocapitalize="off" autocorrect="off"></textarea><div class="acc"><button data-k="tab">Tab</button><button data-k="in">⇥+</button><button data-k="out">⇤-</button><button data-k="home">Home</button><button data-k="end">End</button><button data-k="find">Find</button></div>';
      document.body.appendChild(sh); const ed=sh.querySelector('#ed'); ed.value=text; const orig=text; const dt=sh.querySelector('#dt');
      ed.addEventListener('input',()=>dt.textContent=ed.value!==orig?'● ':'');
      sh.querySelector('#cl').onclick=()=>{ if(ed.value!==orig&&!confirm('Discard changes?'))return; sh.remove(); };
      sh.querySelector('#sv').onclick=async()=>{ const r=await fetch('/api/containers/'+encodeURIComponent(current)+'/files/content?path='+encodeURIComponent(path),{method:'PUT',headers:Object.assign({'Content-Type':'application/json'},CSRF),body:JSON.stringify({text:ed.value,lineEnding:le})}); if(r.ok){dt.textContent='';} else { const j=await r.json().catch(()=>({error:'Save failed'})); alert(j.error||'Save failed'); } };
      sh.querySelectorAll('.acc button').forEach(b=>b.onclick=()=>accKey(ed,b.dataset.k)); }
    function accKey(ed,k){ const s=ed.selectionStart,e=ed.selectionEnd,v=ed.value,set=(a,b)=>{ed.focus();ed.setSelectionRange(a,b);};
      if(k==='tab'){ ed.value=v.slice(0,s)+'  '+v.slice(e); set(s+2,s+2); ed.dispatchEvent(new Event('input')); }
      else if(k==='home'){ const ls=v.lastIndexOf('\n',s-1)+1; set(ls,ls); }
      else if(k==='end'){ let le=v.indexOf('\n',s); if(le<0)le=v.length; set(le,le); }
      else if(k==='in'||k==='out'){ const ls=v.lastIndexOf('\n',s-1)+1; let le=v.indexOf('\n',e); if(le<0)le=v.length; const seg=v.slice(ls,le); const out=seg.split('\n').map(l=>k==='in'?'  '+l:l.replace(/^  /,'')).join('\n'); ed.value=v.slice(0,ls)+out+v.slice(le); set(ls,ls+out.length); ed.dispatchEvent(new Event('input')); }
      else if(k==='find'){ const q=prompt('Find'); if(q){ const i=v.indexOf(q,e); if(i>=0)set(i,i+q.length); else alert('Not found'); } } }

    /* Schedules (gated on the schedules permission) */
    const DAYS=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
    let selDays=new Set();
    async function loadSchedule(){ const host=document.getElementById('sched'); let data;
      try{ data=await jget('/api/containers/'+encodeURIComponent(current)+'/schedule'); }catch(e){ host.innerHTML='<p class="msg err">Unavailable.</p>'; return; }
      const s=data.schedule; selDays=new Set(s?s.weekdays:[]);
      let cur=''; if(s){ let last=''; if(s.lastRun){ const cls=s.lastRun.outcome==='ok'?'okrun':(s.lastRun.outcome==='timedOut'?'timeout':'fail'); last='<div class="note '+cls+'">Last run '+esc(s.lastRun.date)+' — '+esc(s.lastRun.outcome)+(s.lastRun.message?': '+esc(s.lastRun.message):'')+'</div>'; }
        cur='<div class="kv"><span class="kk">Current</span><span class="vv">'+esc(s.description)+'</span></div>'+last; }
      const hh=s?s.hour:4, mm=s?s.minute:0;
      host.innerHTML=cur
        +'<h2>'+(s?'Change':'Add')+' schedule</h2>'
        +'<div class="field">At <select id="hh">'+opts(24,hh)+'</select> : <select id="mm">'+opts(60,mm)+'</select></div>'
        +'<div class="days">'+DAYS.map((d,i)=>'<button class="'+(selDays.has(i)?'on':'')+'" onclick="tgl('+i+',this)">'+d+'</button>').join('')+'</div>'
        +'<div class="note">No days selected = every day. Runs via launchd even when the app is closed; restart only.</div>'
        +'<button class="primary" onclick="saveSched()">'+(s?'Save changes':'Add schedule')+'</button>'
        +(s?'<button class="danger" onclick="delSched()">Remove schedule</button>':''); }
    function opts(n,sel){ let o=''; for(let i=0;i<n;i++)o+='<option value="'+i+'"'+(i===sel?' selected':'')+'>'+String(i).padStart(2,'0')+'</option>'; return o; }
    window.tgl=function(i,el){ if(selDays.has(i)){selDays.delete(i); el.classList.remove('on');} else {selDays.add(i); el.classList.add('on');} };
    window.saveSched=async function(){ const hour=+document.getElementById('hh').value, minute=+document.getElementById('mm').value;
      const r=await fetch('/api/containers/'+encodeURIComponent(current)+'/schedule',{method:'POST',headers:Object.assign({'Content-Type':'application/json'},CSRF),body:JSON.stringify({hour,minute,weekdays:[...selDays]})});
      if(r.ok) loadSchedule(); else { const j=await r.json().catch(()=>({error:'Failed'})); alert(j.error||'Failed'); } };
    window.delSched=async function(){ if(!confirm('Remove this schedule?'))return; const r=await fetch('/api/containers/'+encodeURIComponent(current)+'/schedule',{method:'DELETE',headers:CSRF}); if(r.ok) loadSchedule(); else alert('Failed'); };

    showHome();
    """#
}
