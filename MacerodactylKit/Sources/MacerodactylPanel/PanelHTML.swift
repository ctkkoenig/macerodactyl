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

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
