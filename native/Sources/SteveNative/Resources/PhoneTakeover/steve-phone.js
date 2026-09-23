'use strict';
const $ = id => document.getElementById(id);
let csrf = '', frameID = '', sequence = 0, active = false, busy = false, imageURL = '';
let pollTimer, heartbeatTimer;
const fragment = new URLSearchParams(location.hash.slice(1));
const token = fragment.get('pair');
if (token && /^[a-f0-9]{64}$/.test(token)) $('pair-token').value = token;
history.replaceState(null, '', location.pathname);
function message(text, error = false) {
  $('error').hidden = !error;
  $('error').textContent = error ? text : '';
  if (!error) $('status').textContent = text;
}
async function request(path, body = {}, options = {}) {
  const response = await fetch(path, {method:'POST',credentials:'same-origin',cache:'no-store',
    headers:{'Content-Type':'application/json',...(csrf ? {'X-Steve-CSRF':csrf} : {})},
    body:JSON.stringify(body),signal:AbortSignal.timeout(10000),...options});
  if (!response.ok) {
    const detail = await response.json().catch(() => ({}));
    const error = new Error(detail.error || 'Connection interrupted. Steve stays paused.');
    error.status = response.status;
    throw error;
  }
  return response;
}
function clearScreen() {
  $('screen').removeAttribute('src');
  if (imageURL) URL.revokeObjectURL(imageURL);
  imageURL = ''; frameID = '';
  $('remote-text').value = '';
}
function ended(text) {
  active = false; csrf = ''; busy = false;
  clearTimeout(pollTimer); clearInterval(heartbeatTimer); clearScreen();
  $('control').hidden = true; $('pairing').hidden = false;
  $('connection').textContent = 'Disconnected'; $('connection').classList.remove('live');
  $('connect').disabled = false;
  message(text);
}
async function poll() {
  if (!active || document.hidden) return;
  try {
    if (!busy) {
      busy = true;
      const response = await request('/api/frame');
      const blob = await response.blob();
      const id = response.headers.get('X-Steve-Frame');
      if (!active) return;
      const nextURL = URL.createObjectURL(blob);
      const previousURL = imageURL;
      $('screen').src = nextURL;
      try { await $('screen').decode(); }
      catch (error) { URL.revokeObjectURL(nextURL); throw error; }
      if (!active) { URL.revokeObjectURL(nextURL); return; }
      imageURL = nextURL; frameID = id;
      if (previousURL) URL.revokeObjectURL(previousURL);
      $('screen-wait').hidden = true;
    }
  } catch (error) {
    if (error.status !== 409) { await disconnect(false, 'Connection lost. Steve remains paused. Pair again on your Mac.'); return; }
  } finally { busy = false; }
  if (active) pollTimer = setTimeout(poll, 800);
}
async function input(data) {
  if (!active) return;
  if (busy || !frameID) { message('Wait for the screen to update, then try again.', true); return; }
  busy = true;
  try {
    const response = await request('/api/input', {...data,sequence:sequence + 1,frameID});
    const result = await response.json();
    sequence = Number(result.sequence);
    message('You have control. Steve is paused.');
  } catch (error) {
    if (error.status === 409) message(error.message, true);
    else await disconnect(false, 'Input could not be confirmed. Steve stays paused. Pair again on the Mac.');
  } finally { busy = false; }
}
async function disconnect(resume, fallback) {
  if (!active) return;
  active = false;
  clearTimeout(pollTimer); clearInterval(heartbeatTimer);
  $('finish').disabled = true; $('disconnect').disabled = true;
  clearScreen();
  let text = fallback || 'Disconnected. Steve remains paused.';
  try {
    const response = await request('/api/finish', {resume}, {keepalive:true});
    text = (await response.json()).summary || text;
  } catch { text = 'Control ended. Check Steve on the Mac before resuming; completion was not confirmed.'; }
  ended(text);
}
$('connect').addEventListener('click', async () => {
  const value = $('pair-token').value.trim();
  $('pair-token').value = '';
  if (!/^[a-f0-9]{64}$/.test(value)) { message('Paste the complete one-time code shown on your Mac.', true); return; }
  $('connect').disabled = true; message('Pausing Steve and connecting…');
  try {
    const result = await (await request('/api/pair', {token:value})).json();
    csrf = result.csrf; sequence = 0; active = true;
    if (document.hidden) { await disconnect(false); return; }
    $('screen-wait').hidden = false;
    $('pairing').hidden = true; $('control').hidden = false;
    $('finish').disabled = false; $('disconnect').disabled = false;
    $('connection').textContent = 'You have control'; $('connection').classList.add('live');
    message('You have control. Steve is paused.');
    heartbeatTimer = setInterval(async () => {
      if (!active || document.hidden) return;
      try { await request('/api/heartbeat'); }
      catch { await disconnect(false, 'Connection expired. Steve remains paused.'); }
    }, 4000);
    poll();
  } catch (error) {
    $('connect').disabled = false;
    $('connection').textContent = 'Disconnected';
    message('Not connected. Ask Steve for a fresh link.');
    message(error.message, true);
  }
});
$('screen').addEventListener('click', event => {
  const rect = $('screen').getBoundingClientRect();
  input({kind:'click',x:Math.max(0,Math.min(1,(event.clientX-rect.left)/rect.width)),y:Math.max(0,Math.min(1,(event.clientY-rect.top)/rect.height))});
});
document.querySelectorAll('[data-key]').forEach(button => button.addEventListener('click', () => input({kind:'key',key:button.dataset.key})));
document.querySelectorAll('[data-scroll]').forEach(button => button.addEventListener('click', () => input({kind:'scroll',delta:Number(button.dataset.scroll)})));
$('send-text').addEventListener('click', () => {
  if (!active || busy || !frameID) { message('Wait for the screen to update before sending text.', true); return; }
  const text = $('remote-text').value;
  $('remote-text').value = '';
  if (text) input({kind:'text',text});
});
$('finish').addEventListener('click', () => disconnect(true));
$('disconnect').addEventListener('click', () => disconnect(false));
function backgrounded() { if (active) disconnect(false, 'Control ended when you left Safari. Steve remains paused.'); }
document.addEventListener('visibilitychange', () => { if (document.hidden) backgrounded(); });
window.addEventListener('pagehide', backgrounded);
