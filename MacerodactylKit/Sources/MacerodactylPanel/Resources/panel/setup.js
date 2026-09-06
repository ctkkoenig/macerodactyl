// First-run setup: create the first administrator over the browser instead of
// reading a password file off the server. The endpoint is closed the moment any
// account exists, so this page can only ever mint the very first admin. No
// untrusted data is rendered as HTML — the only dynamic text is an error string
// set through textContent.
const go = document.getElementById('go'), err = document.getElementById('err');

async function submit() {
  err.textContent = '';
  const username = document.getElementById('u').value.trim();
  const password = document.getElementById('p').value;
  const confirm = document.getElementById('p2').value;
  if (!username) { err.textContent = 'Choose a username.'; return; }
  if (password.length < 8) { err.textContent = 'Password must be at least 8 characters.'; return; }
  if (password !== confirm) { err.textContent = 'The passwords do not match.'; return; }
  go.disabled = true;
  try {
    const r = await fetch('/setup', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Macerodactyl-CSRF': '1' },
      body: JSON.stringify({ username, password }),
    });
    if (r.ok) { location.href = '/me'; return; }
    const j = await r.json().catch(() => ({}));
    err.textContent = j.error || ('Error ' + r.status);
  } catch (e) { err.textContent = 'Network error'; }
  go.disabled = false;
}
go.addEventListener('click', submit);
for (const id of ['u', 'p', 'p2']) {
  document.getElementById(id).addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
}
