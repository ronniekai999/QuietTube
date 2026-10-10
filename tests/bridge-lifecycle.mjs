import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import path from 'node:path';
const project = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const source = (await fs.readFile(path.join(project, 'extension-overlay/bridge.js'), 'utf8'))
    .replace(/^import .*;\n/gm, '').replace('export function initializeCompanion', 'function initializeCompanion');
const create = new Function('chrome', 'navigator', 'crypto', 'getFilteringMode', 'setFilteringModeDetails',
    'registerContentScripts', 'registerUserScripts', 'ENGINE', 'Date', 'PLATFORM', source + '\nreturn { initializeCompanion, snapshot, setProtection, connect };');
function event() {
    const listeners = [];
    return { addListener: fn => listeners.push(fn), emit: value => listeners.forEach(fn => fn(value)) };
}
function gate() {
    let release;
    const promise = new Promise(resolve => { release = resolve; });
    return { promise, release };
}
const tick = () => new Promise(resolve => setImmediate(resolve));
function harness() {
    let available = false;
    let mode = 0;
    let siteAccess = true;
    let scripts;
    let now = Date.now();
    let readGate;
    let writeGate;
    const saved = {};
    const ports = [];
    const alarms = new Map();
    const action = {};
    const onAlarm = event();
    const chrome = {
        permissions: { contains: async () => siteAccess, onAdded: event(), onRemoved: event() },
        storage: { local: {
            async get(keys) {
                if (keys === 'quiettubePending' && readGate) await readGate.promise;
                return Object.fromEntries((Array.isArray(keys) ? keys : [keys]).filter(k => k in saved).map(k => [k, structuredClone(saved[k])]));
            },
            async set(value) {
                if ('quiettubeState' in value && writeGate) {
                    const wait = writeGate; writeGate = undefined; await wait.promise;
                }
                Object.assign(saved, structuredClone(value));
            },
            async remove(key) { delete saved[key]; }
        } },
        action: { async setTitle(value) { action.title = value.title; }, async setBadgeText(value) { action.badge = value.text; } },
        scripting: { async getRegisteredContentScripts() { return scripts || (mode === 2 ? [{ id: 'youtube', matches: ['*://*.youtube.com/*'] }] : []); } },
        declarativeNetRequest: { async getEnabledRulesets() { return ['default']; } },
        alarms: { async create(name, info) { alarms.set(name, info); }, async clear(name) { alarms.delete(name); }, onAlarm },
        runtime: {
            getManifest: () => ({ version: '0.1.2' }), getURL: p => 'chrome-extension://test/' + p,
            onMessage: event(),
            connectNative() {
                if (!available) throw new Error('Native host unavailable');
                const port = { onMessage: event(), onDisconnect: event(), sent: [],
                    postMessage(message) { this.sent.push(message); }, disconnect() { this.onDisconnect.emit(); } };
                ports.push(port); return port;
            }
        }
    };
    class Clock extends Date { static now() { return now; } }
    const api = create(chrome, { userAgent: 'Edg/156' }, crypto,
        async () => mode, async value => { mode = value.optimal.length ? 2 : 0; }, async () => {}, async () => {}, { version: 'test' }, Clock,
        { browser: 'Edge', companionName: 'Windows companion', connectNative: host => chrome.runtime.connectNative(host) });
    api.initializeCompanion(Promise.resolve());
    return { api, saved, ports, alarms, onAlarm, chrome, action,
        setAvailable(value) { available = value; }, gateRead(value) { readGate = value; }, gateWrite(value) { writeGate = value; },
        setAccess(value) { siteAccess = value; }, setScripts(value) { scripts = value; }, advance(ms) { now += ms; } };
}
const nativeState = (revision, extra = {}) => ({ type: 'state', enabled: true, effectiveEnabled: true,
    pausedUntilUtc: null, revision, appRunning: true, ...extra });
async function attach(h, revision = 1) {
    h.setAvailable(true); h.api.connect();
    const port = h.ports.at(-1);
    port.onMessage.emit(nativeState(revision));
    const state = await h.api.snapshot();
    assert.equal(state.connected, true);
    return port;
}
const results = [];
const errors = [];
async function check(name, task) {
    try { await task(); results.push(name); }
    catch (error) { errors.push(name + ': ' + (error.stack || error)); }
}
await check('Permission loss reports attention; restoring access restores readiness and badge', async () => {
    const h = harness(); assert.equal((await h.api.snapshot()).filteringReady, true);
    h.setAccess(false); h.chrome.permissions.onRemoved.emit({ origins: ['https://*.youtube.com/*'] }); await tick();
    let s = await h.api.snapshot();
    assert.equal(s.filteringReady, false); assert.equal(s.settingsApplied, false);
    assert.match(s.engineError, /Allow QuietTube access/); assert.equal(h.action.badge, '!');
    h.setAccess(true); h.chrome.permissions.onAdded.emit({ origins: ['https://*.youtube.com/*'] }); await tick();
    s = await h.api.snapshot(); assert.equal(s.filteringReady, true); assert.equal(s.engineError, null); assert.equal(h.action.badge, '');
});
await check('Scripts on unrelated sites cannot count as YouTube readiness', async () => {
    const h = harness(); await h.api.snapshot();
    h.setScripts([{ matches: ['https://example.com/*'] }]);
    assert.equal((await h.api.snapshot()).filteringReady, false);
    h.setScripts([{ matches: ['<all_urls>'], excludeMatches: ['*://*.youtube.com/*'] }]);
    assert.equal((await h.api.snapshot()).registeredScripts, 0);
});
await check('Delayed alarm from an old pause cannot end a new pause', async () => {
    const h = harness(); await h.api.snapshot(); await h.api.setProtection(true, 15);
    h.advance(1000); await h.api.setProtection(true, 15);
    const deadline = h.saved.quiettubeState.pausedUntilUtc;
    h.onAlarm.emit({ name: 'quiettube-pause', scheduledTime: Date.now() - 1000 }); await tick();
    const s = await h.api.snapshot(); assert.equal(s.effectiveEnabled, false); assert.equal(s.pausedUntilUtc, deadline);
    assert.equal(h.saved.quiettubePending.pausedUntilUtc, deadline);
});
await check('Offline pause automatically expires; explicit off stays off', async () => {
    const h = harness(); await h.api.snapshot(); await h.api.setProtection(true, 1); h.advance(61000);
    h.onAlarm.emit({ name: 'quiettube-pause' }); await tick();
    let s = await h.api.snapshot(); assert.equal(s.filteringReady, true); assert.equal(s.pausedUntilUtc, null);
    await h.api.setProtection(false); h.onAlarm.emit({ name: 'quiettube-pause' }); await tick();
    s = await h.api.snapshot(); assert.equal(s.effectiveEnabled, false); assert.equal(s.settingsApplied, true);
});
await check('Connected pause expiry consults current native settings before resuming', async () => {
    const h = harness(); await h.api.snapshot(); const port = await attach(h);
    port.onMessage.emit(nativeState(2, { effectiveEnabled: false, pausedUntilUtc: new Date(Date.now() + 60000).toISOString() }));
    await h.api.snapshot(); h.advance(61000); h.onAlarm.emit({ name: 'quiettube-pause' }); await tick();
    const request = port.sent.findLast(x => x.type === 'getState'); assert.ok(request);
    assert.equal(h.saved.quiettubeState.effectiveEnabled, false);
    port.onMessage.emit(nativeState(3, { requestId: request.requestId, effectiveEnabled: false, pausedUntilUtc: new Date(Date.now() + 120000).toISOString() }));
    await tick(); assert.equal((await h.api.snapshot()).effectiveEnabled, false);
});
await check('Disconnect invalidates queued state and permits an offline off command', async () => {
    const h = harness(); await h.api.snapshot(); h.setAvailable(true); h.api.connect(); const port = h.ports[0];
    const wait = gate(); h.gateRead(wait);
    port.onMessage.emit(nativeState(1)); await tick(); port.onMessage.emit(nativeState(2)); port.onDisconnect.emit(); wait.release();
    let s = await h.api.snapshot(); assert.equal(s.connected, false); assert.equal(s.appRunning, false); assert.equal(s.revision, 0);
    s = await h.api.setProtection(false); assert.equal(s.effectiveEnabled, false); assert.equal(h.saved.quiettubePending.enabled, false);
});
await check('Losing the companion at pause expiry still resumes browser protection', async () => {
    const h = harness(); await h.api.snapshot(); const port = await attach(h);
    port.onMessage.emit(nativeState(2, { effectiveEnabled: false, pausedUntilUtc: new Date(Date.now() + 60000).toISOString() }));
    await h.api.snapshot(); h.advance(61000); h.onAlarm.emit({ name: 'quiettube-pause' }); await tick();
    assert.ok(port.sent.findLast(x => x.type === 'getState'));
    port.onDisconnect.emit(); await tick();
    const s = await h.api.snapshot(); assert.equal(s.connected, false); assert.equal(s.filteringReady, true); assert.equal(s.pausedUntilUtc, null);
});
await check('Disconnect during persistence restores the last committed state', async () => {
    const h = harness(); await h.api.snapshot(); const port = await attach(h);
    const wait = gate(); h.gateWrite(wait);
    port.onMessage.emit(nativeState(2, { enabled: false, effectiveEnabled: false })); await tick(); port.onDisconnect.emit(); wait.release();
    const s = await h.api.snapshot(); assert.equal(s.connected, false); assert.equal(s.effectiveEnabled, true); assert.equal(s.revision, 1);
    assert.equal(h.saved.quiettubeState.revision, 1);
});
await check('Acknowledging an old offline change cannot erase a newer offline change', async () => {
    const h = harness(); await h.api.snapshot(); await h.api.setProtection(false); h.setAvailable(true); h.api.connect(); const port = h.ports[0];
    port.onMessage.emit(nativeState(1)); await h.api.snapshot();
    const oldRequest = port.sent.findLast(x => x.type === 'setProtection'); assert.ok(oldRequest);
    await h.api.setProtection(true, 15); const id = h.saved.quiettubePending.id;
    port.onMessage.emit(nativeState(2, { requestId: oldRequest.requestId, enabled: false, effectiveEnabled: false })); await h.api.snapshot();
    assert.equal(h.saved.quiettubePending.id, id); assert.ok(h.saved.quiettubeState.pausedUntilUtc);
    const latest = port.sent.findLast(x => x.type === 'setProtection'); assert.notEqual(latest.requestId, oldRequest.requestId);
    port.onMessage.emit(nativeState(3, { requestId: latest.requestId, effectiveEnabled: false, pausedUntilUtc: h.saved.quiettubePending.pausedUntilUtc }));
    const s = await h.api.snapshot(); assert.equal(s.connected, true); assert.equal(s.effectiveEnabled, false); assert.equal(h.saved.quiettubePending, undefined);
});
await check('Messages from an old port cannot overwrite a new connection', async () => {
    const h = harness(); await h.api.snapshot(); const old = await attach(h); old.onDisconnect.emit();
    const fresh = await attach(h, 3); old.onMessage.emit(nativeState(100, { enabled: false, effectiveEnabled: false })); old.onDisconnect.emit();
    const s = await h.api.snapshot(); assert.equal(s.revision, 3); assert.equal(s.connected, true); assert.equal(s.filteringReady, true);
    assert.ok(fresh.sent.some(x => x.type === 'status'));
});
await check('Older native revisions cannot revert acknowledged settings', async () => {
    const h = harness(); await h.api.snapshot(); const port = await attach(h, 5);
    port.onMessage.emit(nativeState(4, { enabled: false, effectiveEnabled: false }));
    assert.equal((await h.api.snapshot()).revision, 5);
});
await check('A disconnect during a popup command preserves its intent offline', async () => {
    const h = harness(); await h.api.snapshot(); const port = await attach(h);
    const task = h.api.setProtection(false); await tick(); port.onDisconnect.emit();
    const s = await task; assert.equal(s.connected, false); assert.equal(s.effectiveEnabled, false); assert.equal(h.saved.quiettubePending.enabled, false);
});
const report = { testedAtUtc: new Date().toISOString(), version: '0.1.2', results, errors,
    method: 'Production bridge with mocked Chrome/native boundaries and controllable clock; complements real-browser tests.' };
await fs.writeFile(path.join(project, 'bridge-test-results.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
if (errors.length) process.exitCode = 1;
