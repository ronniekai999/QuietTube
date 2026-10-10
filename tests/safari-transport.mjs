import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
const project = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const source = (await fs.readFile(path.join(project, 'extension-overlay/platform.js'), 'utf8'))
    .replace('export function createPlatform', 'function createPlatform').replace(/export const PLATFORM = .*;\n/, '');
const create = new Function(source + '\nreturn createPlatform;')();
const tick = () => new Promise(resolve => setImmediate(resolve));
const event = () => { const listeners = []; return { addListener: value => listeners.push(value), emit: value => listeners.forEach(fn => fn(value)) }; };
function harness() {
    const received = []; const calls = []; let poll; let stopped = false; let state = { type: 'state', enabled: true, effectiveEnabled: true, pausedUntilUtc: null, revision: 1, appRunning: true };
    let fail = false; let pending; let now = 0;
    const wake = { onMessage: event(), disconnect() {} };
    const api = { runtime: {
        getURL: () => 'safari-web-extension://fixture/', connectNative: () => wake,
        async sendNativeMessage(host, message) {
            calls.push({ host, message });
            if (pending) await pending;
            if (fail) throw new Error('Sandbox unavailable');
            if (message.type === 'status') return { type: 'ack' };
            return { ...state, requestId: message.requestId || null };
        }
    } };
    const timers = { setInterval(task) { poll = task; return 1; }, clearInterval() { stopped = true; }, now: () => now };
    const platform = create(api, 'Macintosh Safari', timers); const port = platform.connectNative('com.quiettube.companion');
    port.onMessage.addListener(value => received.push(value));
    port.postMessage({ type: 'hello', clientId: 'client', extensionVersion: '0.2.0', engineVersion: 'test', requestId: 'hello' });
    return { platform, port, received, calls, wake, poll: () => poll(), get stopped() { return stopped; },
        change(value) { state = { ...state, ...value }; }, fail() { fail = true; }, delay(value) { pending = value; }, advance(ms) { now += ms; } };
}
const results = []; const errors = [];
async function check(name, task) { try { await task(); results.push(name); } catch (error) { errors.push(name + ': ' + error.message); } }
await check('Safari sends each command with browser and client metadata through request/reply messaging', async () => {
    const h = harness(); await tick(); h.port.postMessage({ type: 'setProtection', enabled: false, requestId: 'off' }); await tick();
    assert.equal(h.platform.browser, 'Safari'); assert.equal(h.platform.mac, true); assert.equal(h.calls.at(-1).message.browser, 'Safari');
    assert.equal(h.calls.at(-1).message.clientId, 'client'); assert.equal(h.received.at(-1).requestId, 'off');
});
await check('Native app notifications refresh shared settings without forwarding untrusted notification data', async () => {
    const h = harness(); await tick(); h.change({ revision: 2, enabled: false, effectiveEnabled: false });
    h.wake.onMessage.emit({ enabled: true, revision: 999999 }); await tick(); assert.equal(h.received.at(-1).revision, 2);
});
await check('Polling discovers a missed app change and suppresses repeated identical settings', async () => {
    const h = harness(); await tick(); await h.poll(); const count = h.received.length; await h.poll(); assert.equal(h.received.length, count);
    h.change({ revision: 2 }); await h.poll(); assert.equal(h.received.at(-1).revision, 2);
});
await check('Status acknowledgments do not trigger a state/report feedback loop', async () => {
    const h = harness(); await tick(); const count = h.received.length; h.port.postMessage({ type: 'status' }); await tick(); assert.equal(h.received.length, count);
});
await check('An unchanged Safari setting still requests a fresh filtering acknowledgment every twenty seconds', async () => {
    const h = harness(); await tick(); h.advance(21000); await h.poll(); assert.equal(h.received.at(-1).type, 'ping');
    const count = h.received.length; await h.poll(); assert.equal(h.received.length, count);
});
await check('Transport errors invalidate the Safari connection and stop its polling timer', async () => {
    const h = harness(); await tick(); let disconnected = 0; h.port.onDisconnect.addListener(() => disconnected++); h.fail(); await h.poll();
    assert.equal(disconnected, 1); assert.equal(h.stopped, true); assert.throws(() => h.port.postMessage({ type: 'getState' }));
});
await check('A late native reply after disconnect cannot overwrite a newer connection', async () => {
    const h = harness(); await tick(); let release; h.delay(new Promise(resolve => { release = resolve; }));
    const count = h.received.length; const pending = h.poll(); h.port.disconnect(); release(); await pending; assert.equal(h.received.length, count);
});
await check('Chrome keeps the original native messaging transport and browser identity', async () => {
    const sentinel = {}; const api = { runtime: { getURL: () => 'chrome-extension://fixture/', connectNative: () => sentinel } };
    const platform = create(api, 'Macintosh Chrome/154'); assert.equal(platform.browser, 'Chrome'); assert.equal(platform.connectNative('host'), sentinel);
    assert.equal(create(api, 'Windows Edg/154').browser, 'Edge'); assert.equal(create(api, 'Windows Edg/154').mac, false);
});
const report = { testedAtUtc: new Date().toISOString(), results, errors,
    scope: 'Production Safari transport with controlled browser boundary; real Safari integration is separate.' };
const destination = process.env.QUIETTUBE_TEST_REPORT || path.join(project, 'mac/safari-transport-results.json');
await fs.writeFile(destination, JSON.stringify(report, null, 2) + '\n'); console.log(JSON.stringify(report, null, 2)); if (errors.length) process.exitCode = 1;
