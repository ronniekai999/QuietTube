import { PLATFORM } from '../js/quiettube/platform.js';
let current;
let busy = false;
const $ = id => document.getElementById(id);
const controls = ['toggle', 'pause', 'reload', 'reconnect'];
async function send(what, data = {}) {
    const response = await chrome.runtime.sendMessage({ what: `quiettube:${what}`, ...data });
    if (response?.error) throw new Error(response.error);
    if (!response) throw new Error('QuietTube did not respond. Reload the extension in the browser’s Extensions page.');
    return response;
}
function render(s) {
    current = s;
    const paused = s.enabled && s.pausedUntilUtc && Date.parse(s.pausedUntilUtc) > Date.now();
    const attention = s.engineError || (s.effectiveEnabled && !s.filteringReady ? 'YouTube filtering is not ready. Reload QuietTube in the browser’s Extensions page.' : null);
    $('pill').textContent = attention ? 'Needs attention' : s.filteringReady ? 'YouTube protection' : paused ? 'Timed pause' : 'Protection off';
    $('headline').textContent = attention ? 'Filtering needs attention' : s.filteringReady ? 'Protection is on' : paused ? 'Taking a short break' : 'Protection is off';
    $('detail').textContent = attention || (s.filteringReady ? 'The filtering engine is active on YouTube. Reload any video that was already open.' : paused ? `Resumes at ${new Date(s.pausedUntilUtc).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}.` : 'YouTube loads without QuietTube filtering.');
    $('toggle').textContent = s.effectiveEnabled ? 'Turn protection off' : 'Turn protection on';
    $('connection').textContent = s.connected ? s.appRunning ? `${PLATFORM.appName} connected` : `${PLATFORM.companionName} connected` : 'Browser protection only';
    $('connectionDetail').textContent = s.connected ? s.appRunning ? `${PLATFORM.mac ? 'Menu bar' : 'Tray'} controls and this browser are synchronized.` : PLATFORM.mac ? 'Filtering continues. Open QuietTube for menu bar controls.' : 'Filtering continues. Open QuietTube from the Start menu for tray controls.' : PLATFORM.mac ? 'Open QuietTube to connect the Mac app. Browser controls still work here.' : 'Run Windows setup to connect the tray app. Browser controls still work here.';
    $('dot').classList.toggle('online', s.connected);
    $('version').textContent = `v${s.extensionVersion}`;
    controls.forEach(id => { $(id).disabled = false; });
    $('pause').disabled = !s.effectiveEnabled;
}
async function action(task) {
    busy = true;
    controls.forEach(id => { $(id).disabled = true; });
    $('notice').textContent = '';
    try { await task(); } catch (error) { $('notice').textContent = error.message; }
    finally { busy = false; try { render(await send('status')); } catch (error) { $('notice').textContent = error.message; $('reconnect').disabled = false; } }
}
$('toggle').addEventListener('click', () => action(() => send('setProtection', { enabled: !current.effectiveEnabled })));
$('pause').addEventListener('click', () => action(() => send('setProtection', { enabled: true, pauseMinutes: 15 })));
$('reload').addEventListener('click', () => action(async () => { const result = await send('reloadYoutube'); $('notice').textContent = result.reloaded ? `Reloaded ${result.reloaded} YouTube tab${result.reloaded === 1 ? '' : 's'}.` : 'Open a YouTube tab first.'; }));
$('reconnect').addEventListener('click', () => action(() => send('reconnect')));
send('status').then(render).catch(error => { $('notice').textContent = error.message; });
setInterval(() => { if (!busy) send('status').then(render).catch(() => {}); }, 2000);
