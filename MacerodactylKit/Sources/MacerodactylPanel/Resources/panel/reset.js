// Password reset: consumes a single-use token from the link's query string and
// sets a new password. No untrusted data is rendered as HTML — the token is only
// ever sent in a JSON body, and the sole dynamic text is an error via textContent.
const go = document.getElementById('go'), err = document.getElementById('err'), ok = document.getElementById('ok');
const token = new URLSearchParams(location.search).get('token') || '';

if (!token) { err.textContent = 'This link is missing its reset token.'; go.disabled = true; }

async function submit() {
  err.textContent = '';
  const password = document.getElementById('p').value;
  const confirm = document.getElementById('p2').value;
  if (password.length < 8) { err.textContent = 'Password must be at least 8 characters.'; return; }
  if (password !== confirm) { err.textContent = 'The passwords do not match.'; return; }
  go.disabled = true;
  try {
    const r = await fetch('/reset', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Macerodactyl-CSRF': '1' },
      body: JSON.stringify({ token, password }),
    });
    if (r.ok) {
      ok.hidden = false;
      go.hidden = true;
      document.getElementById('p').disabled = true;
      document.getElementById('p2').disabled = true;
      return;
    }
    const j = await r.json().catch(() => ({}));
    err.textContent = j.error || ('Error ' + r.status);
  } catch (e) { err.textContent = 'Network error'; }
  go.disabled = false;
}
go.addEventListener('click', submit);
for (const id of ['p', 'p2']) {
  document.getElementById(id).addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
}
