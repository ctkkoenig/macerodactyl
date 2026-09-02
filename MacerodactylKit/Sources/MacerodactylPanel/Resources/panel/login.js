// Login page. No untrusted data is ever rendered as HTML — the only dynamic
// text (an error message) goes through textContent.
const go = document.getElementById('go'), err = document.getElementById('err');
async function submit() {
  err.textContent = ''; go.disabled = true;
  try {
    const r = await fetch('/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Macerodactyl-CSRF': '1' },
      body: JSON.stringify({
        username: document.getElementById('u').value,
        password: document.getElementById('p').value
      })
    });
    if (r.ok) { location.href = '/me'; return; }
    const j = await r.json().catch(() => ({}));
    err.textContent = j.error || ('Error ' + r.status);
  } catch (e) { err.textContent = 'Network error'; }
  go.disabled = false;
}
go.addEventListener('click', submit);
document.getElementById('p').addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
