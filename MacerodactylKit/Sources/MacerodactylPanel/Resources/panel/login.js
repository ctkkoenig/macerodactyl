// Login page. No untrusted data is ever rendered as HTML — the only dynamic
// text (an error message) goes through textContent.
const go = document.getElementById('go'), err = document.getElementById('err');
const totpRow = document.getElementById('totpRow'), totpInput = document.getElementById('t');

async function submit() {
  err.textContent = ''; go.disabled = true;
  const payload = {
    username: document.getElementById('u').value,
    password: document.getElementById('p').value,
  };
  // Include the second factor once the server has asked for it.
  if (!totpRow.hidden && totpInput.value.trim()) payload.totp = totpInput.value.trim();
  try {
    const r = await fetch('/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Macerodactyl-CSRF': '1' },
      body: JSON.stringify(payload),
    });
    const j = await r.json().catch(() => ({}));
    // A 2FA account: reveal the code field and prompt (this is NOT a success —
    // no session was issued). A wrong code comes back the same way with an error.
    if (j.totpRequired) {
      totpRow.hidden = false;
      totpInput.focus();
      if (j.error) err.textContent = j.error;
      go.disabled = false;
      return;
    }
    if (r.ok) { location.href = '/me'; return; }
    err.textContent = j.error || ('Error ' + r.status);
  } catch (e) { err.textContent = 'Network error'; }
  go.disabled = false;
}
go.addEventListener('click', submit);
document.getElementById('p').addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
totpInput.addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
